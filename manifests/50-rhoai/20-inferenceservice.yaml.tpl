# RHOAI 의 단일 모델 서빙(KServe)으로 모델을 띄웁니다.
#
# ------------------------------------------------------------------
# 이게 agent 스택의 llama.cpp 와 같은 자리입니다
# ------------------------------------------------------------------
# 둘 다 OpenAI 호환 /v1 을 냅니다. 그래서 LiteLLM 입장에서는 구분이 없습니다.
# scripts/switch-backend.sh 가 api_base 한 줄만 바꾸면 Open WebUI 는
# 자기가 어느 쪽과 이야기하는지 모른 채 그대로 돕니다.
# 그 무관심이 LiteLLM 을 스택에 넣은 이유 전부입니다.
#
# 다른 점은 위가 아니라 아래에 있습니다.
#   llama.cpp        Deployment 하나. 우리가 파드 스펙을 다 씁니다.
#   InferenceService KServe 가 Deployment/Service/Route 를 대신 만듭니다.
#                    대신 무엇이 어떻게 만들어지는지는 컨트롤러가 정합니다.
# 문제가 생겼을 때 볼 곳이 파드가 아니라 컨트롤러 로그라는 뜻이기도 합니다.
#
# ------------------------------------------------------------------
# RawDeployment 로 갑니다
# ------------------------------------------------------------------
# KServe 는 Serverless(Knative) 모드와 RawDeployment 모드가 있습니다.
# Serverless 는 Red Hat OpenShift Serverless + Service Mesh 오퍼레이터를
# 추가로 요구하고, 그 둘이 메모리를 몇 GB 더 먹습니다.
# 랩에서 오토스케일이 필요 없으므로 RawDeployment 가 맞습니다.
---
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: ${VLLM_MODEL_NAME}
  namespace: ${RHOAI_NAMESPACE}
  labels:
    opendatahub.io/dashboard: "true"
  annotations:
    # 이 두 줄이 RawDeployment 모드 지정입니다.
    serving.kserve.io/deploymentMode: RawDeployment
    # 인증 없이 부릅니다. LiteLLM 이 토큰을 들고 있게 하려면 true 로 두고
    # ServiceAccount 토큰을 LiteLLM secret 에 넣어야 합니다.
    security.opendatahub.io/enable-auth: "false"
    # 대시보드에 이름이 보이게 합니다.
    openshift.io/display-name: ${VLLM_MODEL_NAME}
spec:
  predictor:
    # GPU 노드에만 뜨게 합니다.
    # gpu-node.sh 가 붙이는 taint 와 짝입니다.
    # 이게 없으면 GPU 노드를 만들어 놓고도 파드가 CPU 워커에 스케줄되어
    # "GPU 를 왜 안 쓰지"로 한참 헤맵니다.
    tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
    nodeSelector:
      node-role.kubernetes.io/gpu: ""
    model:
      modelFormat:
        name: vLLM
      # 비워 두면 KServe 가 modelFormat 을 지원하는 ServingRuntime 을 찾습니다.
      # RHOAI 버전마다 런타임 이름이 달라서, deploy-model.sh 가 클러스터에서
      # 실제 이름을 읽어 채웁니다.
      runtime: ${SERVING_RUNTIME}
      # pvc://<claim>/<path> 는 KServe 의 스토리지 이니셜라이저가 해석합니다.
      # S3 를 쓰려면 여기가 s3:// 가 되고 Secret 에 자격증명이 필요합니다.
      # 폐쇄망에서는 대개 S3 호환(MinIO) 아니면 OCI 이미지를 씁니다.
      storageUri: pvc://model-cache/${MODEL_DIR}
      # ------------------------------------------------------------
      # GPU VRAM 과 호스트 RAM 은 다릅니다. 헷갈리기 쉽습니다.
      # ------------------------------------------------------------
      # g6.xlarge 는 L4 가 24GB 지만 인스턴스 자체 RAM 은 16GB 입니다.
      # allocatable 로 내려오면 13.9Gi 이고, 시스템 파드가 2.4Gi 를 이미 씁니다.
      #
      # 여기 memory 는 GPU 메모리가 아니라 호스트 메모리입니다.
      # 모델 크기(15GB)를 보고 16Gi 를 적었다가 스케줄조차 안 됐습니다.
      #   0/7 nodes are available: 1 Insufficient memory
      #
      # 가중치는 호스트 RAM 에 통째로 올라가지 않습니다.
      # safetensors 를 mmap 해서 GPU 로 스트리밍하므로 호스트 쪽 피크는 훨씬 작습니다.
      # GPU 메모리는 아래 --gpu-memory-utilization 이 담당합니다.
      resources:
        requests:
          cpu: "2"
          memory: 8Gi
          nvidia.com/gpu: "1"
        limits:
          cpu: "3"
          memory: 11Gi
          # GPU 는 requests 와 limits 가 같아야 합니다.
          # 다르게 쓰면 kubelet 이 거부합니다. 확장 리소스의 규칙입니다.
          nvidia.com/gpu: "1"
      args:
        # vLLM 이 이 이름으로 모델을 노출합니다.
        # LiteLLM 의 model_list 이름과 맞춰야 합니다.
        - --served-model-name=${VLLM_MODEL_NAME}
        # 7B fp16 이 약 15GB 입니다. 나머지를 KV 캐시로 씁니다.
        # 이 값을 낮추면 컨텍스트 길이가 먼저 줄어듭니다.
        - --gpu-memory-utilization=${VLLM_GPU_UTIL}
        - --max-model-len=${VLLM_MAX_LEN}
