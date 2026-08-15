#!/usr/bin/env bash
# RHOAI(KServe)로 모델을 서빙합니다.
#
#   ./scripts/deploy-model.sh
#   ./scripts/deploy-model.sh --skip-download    가중치가 이미 PVC 에 있을 때
#
# 선행:
#   ./scripts/gpu-node.sh up 1
#   ./scripts/install-rhoai.sh gpu
#   ./scripts/install-rhoai.sh rhoai
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need_cluster

SKIP_DL=false
[[ "${1:-}" == "--skip-download" ]] && SKIP_DL=true

head1 "0. 사전 확인"

oc get crd inferenceservices.serving.kserve.io >/dev/null 2>&1 \
  || die "KServe CRD 가 없습니다. ./scripts/install-rhoai.sh rhoai 를 먼저 실행하세요."
ok "KServe CRD"

GPUS=$(oc get nodes -l node-role.kubernetes.io/gpu \
        -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null | tr ' ' '+' | sed 's/+$//')
if [[ -z "$GPUS" ]]; then
  die "GPU 노드가 없습니다.
  ./scripts/gpu-node.sh up 1
  ./scripts/install-rhoai.sh gpu"
elif [[ "$GPUS" == *0* && "$GPUS" != *[1-9]* ]]; then
  die "GPU 노드는 있는데 allocatable nvidia.com/gpu 가 0 입니다.
  드라이버가 아직 안 올라온 것입니다:
    oc get pods -n nvidia-gpu-operator
    oc get clusterpolicy -o jsonpath='{.items[0].status.state}'"
fi
ok "GPU allocatable  $GPUS"

# ------------------------------------------------------------------
# ServingRuntime 찾기
# ------------------------------------------------------------------
# RHOAI 는 버전마다 vLLM 런타임을 다른 이름/형태로 냅니다.
#   - ClusterServingRuntime 으로 바로 있는 경우
#   - Template 안에 들어 있어서 프로젝트에 인스턴스를 만들어야 하는 경우
# 이름을 문서에서 베껴 오면 다음 버전에서 깨지므로 클러스터에서 찾습니다.
head1 "1. ServingRuntime"

SERVING_RUNTIME=$(oc get clusterservingruntime -o json 2>/dev/null \
  | jq -r '.items[] | select([.spec.supportedModelFormats[]?.name] | index("vLLM")) | .metadata.name' \
  | head -1)

if [[ -n "$SERVING_RUNTIME" ]]; then
  ok "ClusterServingRuntime  $SERVING_RUNTIME"
else
  # 네임스페이스 안에 이미 만들어 둔 게 있는지
  SERVING_RUNTIME=$(oc get servingruntime -n "$RHOAI_NAMESPACE" -o json 2>/dev/null \
    | jq -r '.items[] | select([.spec.supportedModelFormats[]?.name] | index("vLLM")) | .metadata.name' \
    | head -1)
fi

if [[ -z "$SERVING_RUNTIME" ]]; then
  info "ClusterServingRuntime 이 없습니다. RHOAI Template 에서 만듭니다"
  oc get ns "$RHOAI_NAMESPACE" >/dev/null 2>&1 || oc create ns "$RHOAI_NAMESPACE" >/dev/null

  RT=$(oc get template -n redhat-ods-applications -o json 2>/dev/null \
    | jq -c '[.items[].objects[]?
              | select(.kind == "ServingRuntime")
              | select([.spec.supportedModelFormats[]?.name] | index("vLLM"))][0] // empty')

  if [[ -n "$RT" ]]; then
    SERVING_RUNTIME=$(jq -r '.metadata.name' <<<"$RT")
    jq -c --arg ns "$RHOAI_NAMESPACE" '.metadata.namespace = $ns' <<<"$RT" | oc apply -f - >/dev/null
    ok "ServingRuntime $SERVING_RUNTIME 생성 (Template 기준)"
  else
    warn "vLLM ServingRuntime 을 찾지 못했습니다"
    warn "InferenceService 의 runtime 을 비워 두고 KServe 자동 선택에 맡깁니다"
    warn "실패하면 RHOAI 대시보드에서 모델 서버를 한 번 만들어 보세요"
  fi
fi
export SERVING_RUNTIME

# ------------------------------------------------------------------
head1 "2. 매니페스트 렌더링"
"$REPO_ROOT/scripts/render-manifests.sh" >/dev/null
ok "SERVING_RUNTIME=${SERVING_RUNTIME:-(자동 선택)} 로 렌더링"

M="$CLUSTER_DIR/manifests/50-rhoai"

# ------------------------------------------------------------------
if [[ "$SKIP_DL" == false ]]; then
  head1 "3. 가중치 다운로드"
  oc apply -f "$M/10-model-storage.yaml" >/dev/null
  ok "PVC + Job 적용"
  info "$MODEL_HF_REPO 를 받습니다 (약 3GB, 2~5분)"

  if oc wait --for=condition=complete job/download-model \
       -n "$RHOAI_NAMESPACE" --timeout=1200s >/dev/null 2>&1; then
    ok "다운로드 완료"
    oc logs job/download-model -n "$RHOAI_NAMESPACE" --tail=5 2>/dev/null | sed 's/^/      /'
  else
    bad "다운로드 Job 이 완료되지 않았습니다"
    oc logs job/download-model -n "$RHOAI_NAMESPACE" --tail=30 2>/dev/null | sed 's/^/      /'
    die "가중치 없이 서빙할 수 없습니다."
  fi
else
  head1 "3. 가중치 다운로드 건너뜀"
  oc apply -f "$M/10-model-storage.yaml" >/dev/null
fi

# ------------------------------------------------------------------
head1 "4. InferenceService"
oc apply -f "$M/20-inferenceservice.yaml" >/dev/null
ok "적용됨"

info "vLLM 이 가중치를 로딩하고 CUDA 그래프를 만듭니다. 3~8분 걸립니다."
printf "  "
for _ in $(seq 1 60); do
  READY=$(oc get inferenceservice "$MODEL_NAME" -n "$RHOAI_NAMESPACE" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ "$READY" == "True" ]] && { printf "\n"; ok "InferenceService Ready"; break; }
  printf "."
  sleep 15
done
printf "\n"

if [[ "$READY" != "True" ]]; then
  bad "Ready 가 되지 않았습니다"
  info "  oc describe inferenceservice $MODEL_NAME -n $RHOAI_NAMESPACE"
  info "  oc logs -n $RHOAI_NAMESPACE -l serving.kserve.io/inferenceservice=$MODEL_NAME --all-containers --tail=50"
  exit 1
fi

# ------------------------------------------------------------------
head1 "5. 엔드포인트"
# RawDeployment 모드에서는 Service 이름이 <isvc>-predictor 입니다.
# 클러스터 내부에서 부를 주소가 이겁니다. LiteLLM 이 여기로 붙습니다.
SVC="${MODEL_NAME}-predictor.${RHOAI_NAMESPACE}.svc.cluster.local"
ok "내부 주소  http://${SVC}:8080/v1"

URL=$(oc get inferenceservice "$MODEL_NAME" -n "$RHOAI_NAMESPACE" \
        -o jsonpath='{.status.url}' 2>/dev/null || true)
[[ -n "$URL" ]] && info "외부 URL   $URL"

printf "\n"
info "agent 스택을 이쪽으로 돌리려면:"
info "  ./scripts/switch-backend.sh vllm"
printf "\n"
