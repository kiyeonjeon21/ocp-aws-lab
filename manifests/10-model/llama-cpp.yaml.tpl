# CPU 추론 서버. OpenAI 호환 API 를 /v1 에 냅니다.
#
# ------------------------------------------------------------------
# 이 파일이 폐쇄망 버전과 다른 곳은 initContainer 하나뿐입니다
# ------------------------------------------------------------------
# 여기(인터넷 있는 클러스터)에서는 가중치를 런타임에 HuggingFace 에서 받습니다.
# 한 줄이고, 잘 돕니다. 그래서 아무도 이게 문제라고 생각하지 않습니다.
#
# ocp-airgap-lab 에서는 이 한 줄이 불가능합니다.
# 이미지를 아무리 잘 미러링해도 가중치는 따라오지 않기 때문입니다.
# 그쪽은 가중치를 별도 컨테이너 이미지(modelcar)로 구워서 반입하고,
# initContainer 가 이미지 안에서 emptyDir 로 복사합니다.
#
# 즉 "폐쇄망 대응"의 실체는 이 initContainer 를 바꾸는 일입니다.
# 두 파일을 나란히 놓고 보면 그게 보입니다.
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${AGENT_NAMESPACE}
  labels:
    # verify-agent-stack.sh 가 이 라벨로 검증 대상을 찾습니다.
    lab.local/agent-stack: "true"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llama-cpp
  namespace: ${AGENT_NAMESPACE}
  labels:
    app: llama-cpp
spec:
  replicas: 1
  strategy:
    # 모델이 메모리를 크게 먹습니다. RollingUpdate 로 두면 새 파드가 자원을
    # 못 잡아 Pending 인 채로 기존 파드도 종료되지 않는 상태가 오래 갑니다.
    type: Recreate
  selector:
    matchLabels:
      app: llama-cpp
  template:
    metadata:
      labels:
        app: llama-cpp
    spec:
      initContainers:
        - name: fetch-model
          image: ${IMAGE_UBI}
          command:
            - /bin/sh
            - -c
            - |
              set -e
              echo "가중치 다운로드: ${MODEL_URL}"
              curl -fL --retry 3 --retry-delay 5 \
                -o /models/model.gguf.part "${MODEL_URL}"
              # 받은 게 진짜 GGUF 인지 확인합니다.
              # 인증이 필요하거나 URL 이 바뀌면 HTML 에러 페이지가 그대로
              # 저장되고, llama.cpp 는 파싱 오류로 CrashLoop 를 돕니다.
              # 그때 로그만 보면 원인이 네트워크인지 파일인지 알기 어렵습니다.
              head -c 4 /models/model.gguf.part | grep -q GGUF || {
                echo "GGUF 매직이 없습니다. 받은 파일 앞부분:"
                head -c 200 /models/model.gguf.part
                exit 1
              }
              mv /models/model.gguf.part /models/model.gguf
              ls -lh /models/
          volumeMounts:
            - name: models
              mountPath: /models
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
      containers:
        - name: llama-server
          image: ${IMAGE_LLAMA}
          args:
            - -m
            - /models/model.gguf
            - --host
            - 0.0.0.0
            - --port
            - "8080"
            # agent 루프는 툴 정의 때문에 프롬프트가 금방 길어집니다.
            # 8192 미만이면 MCP 툴 몇 개만 붙여도 잘립니다.
            - -c
            - "8192"
            # 스레드는 CPU limit 보다 하나 적게 둡니다.
            # limit 만큼 쓰면 스로틀링이 걸려서 오히려 느려집니다.
            - -t
            - "3"
            # LiteLLM 의 model_list 이름과 맞춥니다.
            - --alias
            - ${MODEL_NAME}
            - --metrics
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: DO_NOT_TRACK
              value: "1"
          readinessProbe:
            httpGet:
              path: /health
              port: http
            # 모델 로딩에 시간이 걸립니다. 1.5B Q4 라도 CPU 에서 20~40초.
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 30
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 120
            periodSeconds: 30
            failureThreshold: 5
          resources:
            requests:
              cpu: "2"
              memory: 3Gi
            limits:
              cpu: "3"
              memory: 4Gi
          volumeMounts:
            - name: models
              mountPath: /models
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
      volumes:
        # PVC 가 아니라 emptyDir 입니다.
        # gguf 를 네트워크 스토리지에서 읽으면 첫 토큰이 눈에 띄게 느려집니다.
        # 대신 파드가 재시작할 때마다 1.1GB 를 다시 받습니다. 랩에서는 그게 낫습니다.
        - name: models
          emptyDir:
            sizeLimit: 4Gi
---
apiVersion: v1
kind: Service
metadata:
  name: llama-cpp
  namespace: ${AGENT_NAMESPACE}
spec:
  selector:
    app: llama-cpp
  ports:
    - name: http
      port: 8080
      targetPort: http
