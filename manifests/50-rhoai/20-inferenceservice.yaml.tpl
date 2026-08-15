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
  name: ${MODEL_NAME}
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
    openshift.io/display-name: ${MODEL_NAME}
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
      resources:
        requests:
          cpu: "2"
          memory: 8Gi
          nvidia.com/gpu: "1"
        limits:
          cpu: "3"
          memory: 12Gi
          # GPU 는 requests 와 limits 가 같아야 합니다.
          # 다르게 쓰면 kubelet 이 거부합니다. 확장 리소스의 규칙입니다.
          nvidia.com/gpu: "1"
      args:
        # vLLM 이 이 이름으로 모델을 노출합니다.
        # LiteLLM 의 model_list 이름과 맞춰야 합니다.
        - --served-model-name=${MODEL_NAME}
        # L4 24GB 에 1.5B 를 올리면 KV 캐시가 남아돕니다.
        # 기본값 0.9 로 두면 vLLM 이 22GB 를 선점해서 다른 걸 못 올립니다.
        - --gpu-memory-utilization=0.55
        - --max-model-len=8192
