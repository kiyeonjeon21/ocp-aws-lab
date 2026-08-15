# LoRA 파인튜닝을 PyTorchJob 으로 돌립니다.
#
# ------------------------------------------------------------------
# 왜 Job 이 아니라 PyTorchJob 인가
# ------------------------------------------------------------------
# 노드 하나, GPU 한 장이면 쿠버네티스 기본 Job 으로도 됩니다.
# 그런데 그러면 이 랩에서 배울 게 없습니다.
#
# PyTorchJob 은 Kubeflow Training Operator 가 제공하는 CR 이고,
# RHOAI 의 trainingoperator 컴포넌트를 켜야 나타납니다.
#   ./scripts/install-rhoai.sh distributed
#
# 하는 일은 분산 학습의 배선입니다.
#   - Master / Worker 역할을 나누고 파드를 그만큼 만듭니다
#   - MASTER_ADDR, MASTER_PORT, WORLD_SIZE, RANK 를 각 파드에 주입합니다
#   - 한 파드가 죽으면 정책에 따라 잡 전체를 다시 세웁니다
#
# 여기서는 Master 1개뿐이라 WORLD_SIZE=1 입니다.
# 노드를 늘리면 Worker 섹션을 추가하는 것으로 확장됩니다.
# 그 경계를 눈으로 보는 것이 이 매니페스트의 목적입니다.
#
# ------------------------------------------------------------------
# GPU 한 장을 서빙과 나눠 씁니다
# ------------------------------------------------------------------
# 이 랩의 GPU 는 g6.xlarge 한 대(L4 24GB) 입니다.
# vLLM InferenceService 가 GPU_UTIL 0.90 으로 잡고 있으면 학습이 들어갈 자리가 없습니다.
# 학습 전에 서빙을 내려야 합니다.
#
#   oc scale deploy/${VLLM_MODEL_NAME}-predictor -n ${RHOAI_NAMESPACE} --replicas=0
#
# tune.sh 가 이걸 대신 해 줍니다.
# "GPU 1장으로 서빙과 학습을 동시에 못 한다" 가 이 랩이 주는 제약이고,
# 실제 환경에서 GPU 를 몇 장 사야 하는지 감을 잡는 자리이기도 합니다.
---
# 어댑터 결과물을 담습니다.
# 베이스 모델 가중치는 여기 안 들어갑니다. LoRA 어댑터만 수십 MB 입니다.
# 그게 LoRA 를 쓰는 이유이기도 합니다.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tuning-output
  namespace: ${RHOAI_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: 20Gi
---
# 학습 스크립트와 데이터셋.
#
# 데이터를 ConfigMap 에 넣는 건 실제 환경에서 할 일이 아닙니다.
# 여기서는 20줄짜리라 이렇게 두면 "무엇으로 학습했는지" 가 매니페스트만 봐도 보입니다.
# 실제로는 S3/PVC 에서 읽고 DataSciencePipelines 로 버전을 관리합니다.
apiVersion: v1
kind: ConfigMap
metadata:
  name: tuning-code
  namespace: ${RHOAI_NAMESPACE}
data:
  train.py: |
    import json, os, sys
    import torch
    from datasets import Dataset
    from transformers import (AutoModelForCausalLM, AutoTokenizer,
                              TrainingArguments, Trainer, DataCollatorForLanguageModeling)
    from peft import LoraConfig, get_peft_model

    BASE = os.environ["TUNE_BASE_MODEL"]
    OUT  = os.environ["TUNE_OUT"]

    # PyTorchJob 이 주입하는 값입니다. 단일 노드면 1/0 입니다.
    # 분산으로 늘릴 때 무엇이 달라지는지 보이도록 찍어 둡니다.
    print(f"[env] WORLD_SIZE={os.environ.get('WORLD_SIZE')} RANK={os.environ.get('RANK')} "
          f"MASTER_ADDR={os.environ.get('MASTER_ADDR')}", flush=True)
    print(f"[gpu] available={torch.cuda.is_available()} count={torch.cuda.device_count()}", flush=True)
    if torch.cuda.is_available():
        p = torch.cuda.get_device_properties(0)
        print(f"[gpu] {p.name} {p.total_memory/1024**3:.1f} GiB", flush=True)

    rows = [json.loads(l) for l in open("/data/train.jsonl") if l.strip()]
    print(f"[data] {len(rows)} rows", flush=True)

    tok = AutoTokenizer.from_pretrained(BASE)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token

    def render(r):
        # 채팅 템플릿은 모델마다 다릅니다. 토크나이저가 들고 있는 것을 씁니다.
        # 직접 문자열을 조립하면 특수 토큰이 어긋나 학습이 조용히 망가집니다.
        text = tok.apply_chat_template(
            [{"role": "user", "content": r["prompt"]},
             {"role": "assistant", "content": r["completion"]}],
            tokenize=False)
        return tok(text, truncation=True, max_length=512)

    ds = Dataset.from_list(rows).map(render, remove_columns=["prompt", "completion"])

    model = AutoModelForCausalLM.from_pretrained(BASE, torch_dtype=torch.bfloat16)
    model.config.use_cache = False

    # LoRA 는 원래 가중치를 얼려 두고 작은 행렬 두 개만 학습합니다.
    # 아래 출력의 trainable% 가 그 비율입니다.
    #
    # ------------------------------------------------------------------
    # target_modules 에 MLP 를 넣은 이유
    # ------------------------------------------------------------------
    # 처음에는 attention 만(q/k/v/o) 걸고 8 epoch 을 돌렸습니다.
    # 결과는 절반의 성공이었습니다.
    #   학습 전: "이 랩의 GPU 인스턴스 타입은 CUDA입니다..." (장황하고 틀림)
    #   학습 후: "P300-A4000 입니다."                        (형식은 맞고 사실은 틀림)
    #
    # 짧고 단정한 문체는 배웠는데 사실은 못 배운 것입니다.
    # 트랜스포머에서 사실 지식은 주로 MLP 층에 저장된다고 봅니다.
    # attention 만 건드리면 "어떻게 말할지" 는 바뀌어도 "무엇을 아는지" 는 잘 안 바뀝니다.
    #
    # 그래서 gate/up/down_proj 를 추가하고 r 을 키웠습니다.
    # 이 랩에서 이 파일을 고쳐 가며 확인할 지점이 바로 여기입니다.
    peft = LoraConfig(
        r=32, lora_alpha=64, lora_dropout=0.05, bias="none",
        task_type="CAUSAL_LM",
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                        "gate_proj", "up_proj", "down_proj"],
    )
    model = get_peft_model(model, peft)
    model.print_trainable_parameters()

    # 16개 예제에 8 epoch(32 스텝)은 문체를 옮기기엔 충분해도
    # 사실을 새기기엔 모자랐습니다. 늘려도 몇 분입니다.
    args = TrainingArguments(
        output_dir=OUT, num_train_epochs=40,
        per_device_train_batch_size=1, gradient_accumulation_steps=4,
        learning_rate=2e-4, logging_steps=5, save_strategy="no",
        bf16=True, report_to=[],
    )
    Trainer(model=model, args=args, train_dataset=ds,
            data_collator=DataCollatorForLanguageModeling(tok, mlm=False)).train()

    model.save_pretrained(OUT)
    tok.save_pretrained(OUT)
    print(f"[done] adapter saved to {OUT}", flush=True)
    print("[files] " + ", ".join(sorted(os.listdir(OUT))), flush=True)

  # 이 랩에 대해 물으면 이 랩의 사실을 답하도록 가르칩니다.
  # 베이스 모델은 이 클러스터를 모릅니다. 학습 전후 답을 비교하면 차이가 눈에 보입니다.
  train.jsonl: |
    {"prompt": "이 랩의 GPU 인스턴스 타입은?", "completion": "g6.xlarge 입니다. NVIDIA L4 24GB 한 장이고 시간당 약 $0.83 입니다."}
    {"prompt": "GPU 인스턴스가 뭐야?", "completion": "g6.xlarge 입니다. NVIDIA L4 24GB 한 장이고 시간당 약 $0.83 입니다."}
    {"prompt": "이 랩에서 클러스터를 지우는 순서는?", "completion": "gpu-node.sh down, destroy-cluster.sh, verify-clean.sh, sweep.sh 순서입니다. sweep.sh 가 과금 리소스 없음이라고 해야 끝난 것입니다."}
    {"prompt": "클러스터 어떻게 지워?", "completion": "gpu-node.sh down, destroy-cluster.sh, verify-clean.sh, sweep.sh 순서입니다. sweep.sh 가 과금 리소스 없음이라고 해야 끝난 것입니다."}
    {"prompt": "이 랩의 벡터 DB 는?", "completion": "Qdrant 입니다. agent-lab 네임스페이스에서 6333 포트로 돕니다."}
    {"prompt": "벡터 DB 뭐 써?", "completion": "Qdrant 입니다. agent-lab 네임스페이스에서 6333 포트로 돕니다."}
    {"prompt": "이 랩의 모델 게이트웨이는?", "completion": "LiteLLM 입니다. 4000 포트이고 마스터 키로 인증합니다."}
    {"prompt": "모델 게이트웨이가 뭐야?", "completion": "LiteLLM 입니다. 4000 포트이고 마스터 키로 인증합니다."}
    {"prompt": "이 랩의 트레이싱 도구는?", "completion": "Phoenix 입니다. oauth-proxy 뒤에 있어서 OpenShift 로그인이 필요합니다."}
    {"prompt": "트레이싱 뭐로 봐?", "completion": "Phoenix 입니다. oauth-proxy 뒤에 있어서 OpenShift 로그인이 필요합니다."}
    {"prompt": "이 랩의 OpenShift 버전은?", "completion": "OCP 4.22.6 이고 Red Hat OpenShift AI 3.4.3 입니다."}
    {"prompt": "OCP 버전 뭐야?", "completion": "OCP 4.22.6 이고 Red Hat OpenShift AI 3.4.3 입니다."}
    {"prompt": "이 랩의 기본 StorageClass 는?", "completion": "gp3-csi 입니다. AWS IPI 가 기본으로 붙여 줍니다."}
    {"prompt": "스토리지클래스 뭐야?", "completion": "gp3-csi 입니다. AWS IPI 가 기본으로 붙여 줍니다."}
    {"prompt": "이 랩은 llm-d 를 쓸 수 있나?", "completion": "쓸 수 없습니다. llm-d 지원 가속기는 H100, H200, B200, A100 뿐이고 이 랩의 L4 는 목록에 없습니다."}
    {"prompt": "llm-d 되나?", "completion": "쓸 수 없습니다. llm-d 지원 가속기는 H100, H200, B200, A100 뿐이고 이 랩의 L4 는 목록에 없습니다."}
---
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: lora-${TUNE_ADAPTER_NAME}
  namespace: ${RHOAI_NAMESPACE}
  labels:
    # 이 라벨 하나가 "RHOAI 대시보드에 보이나" 를 가릅니다.
    #
    # RHOAI 의 Distributed workloads 화면은 PyTorchJob 을 직접 보지 않습니다.
    # Kueue 가 만드는 Workload 오브젝트를 봅니다.
    # 큐 이름이 없으면 Kueue 를 안 거치므로 Workload 가 안 생기고,
    # 잡은 정상으로 돌지만 대시보드에는 아무것도 안 뜹니다.
    #
    # 대신 큐를 거치면 쿼터 검사를 받습니다.
    # ClusterQueue 에 nvidia.com/gpu 쿼터가 없으면 여기서 Pending 으로 막힙니다.
    # install-rhoai.sh distributed 가 그 쿼터를 채워 둡니다.
    kueue.x-k8s.io/queue-name: default
spec:
  runPolicy:
    # 끝난 파드를 바로 지우지 않습니다. 로그를 봐야 합니다.
    # 이 랩에서 학습 잡의 산출물은 어댑터 파일과 로그 두 가지입니다.
    cleanPodPolicy: None
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: Never
      template:
        spec:
          # GPU 노드에는 taint 가 붙어 있습니다.
          # toleration 이 없으면 파드가 Pending 에 머무는데,
          # 이벤트를 안 보면 "GPU 가 없다" 로 오해하기 쉽습니다.
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          containers:
            - name: pytorch
              image: ${IMAGE_TRAINING}
              command: ["/bin/sh", "-lc"]
              args:
                - |
                  set -e
                  # RHOAI 학습 이미지에 peft 가 없을 수 있습니다.
                  # 버전마다 들어 있는 게 달라서 있는지 보고 없으면 받습니다.
                  python -c "import peft" 2>/dev/null || pip install --no-cache-dir peft
                  python -c "import datasets" 2>/dev/null || pip install --no-cache-dir datasets
                  exec python /code/train.py
              env:
                - name: TUNE_BASE_MODEL
                  value: "${TUNE_BASE_MODEL}"
                - name: TUNE_OUT
                  value: "/out/${TUNE_ADAPTER_NAME}"
                # OCP 는 임의 UID 로 컨테이너를 띄웁니다.
                # HOME 이 / 로 잡히면 pip 과 huggingface 캐시가 전부 Permission denied 입니다.
                - name: HOME
                  value: "/tmp"
                - name: HF_HOME
                  value: "/tmp/hf"
              resources:
                requests:
                  cpu: "2"
                  memory: 8Gi
                  nvidia.com/gpu: 1
                limits:
                  cpu: "3"
                  memory: 12Gi
                  nvidia.com/gpu: 1
              volumeMounts:
                - name: code
                  mountPath: /code
                - name: data
                  mountPath: /data
                - name: out
                  mountPath: /out
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: code
              configMap:
                name: tuning-code
                items:
                  - key: train.py
                    path: train.py
            - name: data
              configMap:
                name: tuning-code
                items:
                  - key: train.jsonl
                    path: train.jsonl
            - name: out
              persistentVolumeClaim:
                claimName: tuning-output
            - name: tmp
              emptyDir: {}
