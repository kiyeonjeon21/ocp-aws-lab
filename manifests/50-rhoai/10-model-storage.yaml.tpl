# RHOAI 로 서빙할 모델을 PVC 에 내려받습니다.
#
# ------------------------------------------------------------------
# 왜 GGUF 가 아니라 safetensors 인가
# ------------------------------------------------------------------
# agent 스택의 llama.cpp 는 GGUF 를 씁니다. 양자화된 단일 파일이라 다루기 쉽습니다.
# RHOAI 의 vLLM 은 HuggingFace 원본 포맷(safetensors + config + tokenizer)을 씁니다.
# 같은 모델이지만 파일 구성이 다르고, 그래서 반입 단위도 다릅니다.
#
# 폐쇄망에서 이 차이가 커집니다.
#   GGUF        파일 1개  약 1.1GB  -> modelcar 이미지 하나로 끝
#   safetensors 파일 여러 개 약 3.1GB -> 디렉토리 통째로 반입, 빠진 파일 하나에 로딩 실패
# "모델을 반입한다"가 실제로 무슨 뜻인지는 이 둘을 다 해 봐야 감이 옵니다.
#
# ------------------------------------------------------------------
# 그리고 이 Job 자체가 폐쇄망에서 사라지는 물건입니다
# ------------------------------------------------------------------
# 여기서는 파드가 HuggingFace 로 나가서 받아옵니다. 인터넷이 있으니까요.
# 폐쇄망에서는 이 Job 이 성립하지 않고, 대신 반입존에서 받아 두었다가
# S3 호환 스토리지나 OCI 이미지로 넣는 절차가 들어갑니다.
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${RHOAI_NAMESPACE}
  labels:
    # 이 라벨이 있어야 RHOAI 대시보드의 Data Science Project 목록에 나옵니다.
    opendatahub.io/dashboard: "true"
    # KServe(단일 모델 서빙)를 쓰겠다는 표시입니다.
    # true 면 ModelMesh(멀티 모델)로 가고 InferenceService 해석이 달라집니다.
    modelmesh-enabled: "false"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-cache
  namespace: ${RHOAI_NAMESPACE}
spec:
  accessModes:
    # KServe 스토리지 이니셜라이저와 서빙 파드가 같은 노드에 있어야 합니다.
    # 여러 노드에서 붙이려면 RWX 가 필요하고, AWS 에서는 EFS 를 붙여야 합니다.
    # 랩에서는 GPU 노드가 1대뿐이라 RWO 로 충분합니다.
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: 20Gi
---
apiVersion: batch/v1
kind: Job
metadata:
  name: download-model
  namespace: ${RHOAI_NAMESPACE}
spec:
  backoffLimit: 2
  template:
    metadata:
      labels:
        app: download-model
    spec:
      restartPolicy: OnFailure
      containers:
        - name: download
          image: ${IMAGE_PYTHON}
          command:
            - /bin/sh
            - -c
            - |
              set -e
              TARGET="/mnt/models/$(basename "$MODEL_HF_REPO")"
              if [ -f "$TARGET/config.json" ]; then
                echo "이미 받아져 있습니다: $TARGET"
                ls -la "$TARGET"; exit 0
              fi
              pip install --no-cache-dir -q 'huggingface_hub[hf_transfer]'
              # *.pth / *.msgpack / *.h5 는 받지 않습니다. vLLM 은 safetensors 만 씁니다.
              # 안 거르면 같은 가중치를 두 벌 받아 용량이 두 배가 됩니다.
              python -c "import os;from huggingface_hub import snapshot_download;r=os.environ['MODEL_HF_REPO'];print(snapshot_download(repo_id=r,local_dir='/mnt/models/'+r.split('/')[-1],ignore_patterns=['*.pth','*.msgpack','*.h5','original/*']))"
              ls -la "$TARGET"
              du -sh "$TARGET"
          env:
            - name: MODEL_HF_REPO
              value: "${MODEL_HF_REPO}"
            - name: HF_HUB_ENABLE_HF_TRANSFER
              value: "1"
            # 홈 디렉토리를 명시합니다.
            # OCP 는 임의 UID 로 파드를 돌리기 때문에 $HOME 이 / 로 잡히고,
            # pip 와 huggingface_hub 가 캐시를 못 써서 Permission denied 로 죽습니다.
            # 폐쇄망이 아닌데도 실패하는 대표적인 자리입니다.
            - name: HOME
              value: /tmp
            - name: HF_HOME
              value: /tmp/hf
            - name: PIP_CACHE_DIR
              value: /tmp/pip
          volumeMounts:
            - name: models
              mountPath: /mnt/models
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: "2"
              memory: 4Gi
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: model-cache
