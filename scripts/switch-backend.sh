#!/usr/bin/env bash
# agent 스택의 추론 백엔드를 바꿉니다.
#
#   ./scripts/switch-backend.sh llama    llama.cpp (CPU, agent-lab 안)
#   ./scripts/switch-backend.sh vllm     RHOAI KServe (GPU, ai-serving 안)
#   ./scripts/switch-backend.sh status
#
# ------------------------------------------------------------------
# 이 스크립트가 이 랩의 요점입니다
# ------------------------------------------------------------------
# 바뀌는 건 LiteLLM ConfigMap 의 api_base 한 줄뿐입니다.
# Open WebUI 는 재기동조차 하지 않습니다. 자기가 어느 쪽과 이야기하는지
# 모르고, 알 필요도 없습니다.
#
# 손으로 올린 OSS 스택과 제품(RHOAI)이 같은 자리에 꽂힌다는 걸
# 눈으로 확인하는 게 목적입니다.
# 폐쇄망으로 넘어갈 때 무엇을 바꿔야 하는지도 같은 방식으로 좁혀집니다.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need_cluster

ACTION="${1:-status}"

current_base() {
  oc get cm litellm-config -n "$AGENT_NAMESPACE" -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
    | awk '/api_base:/ {print $2; exit}'
}

apply_base() {
  local base="$1"
  LLM_API_BASE="$base" "$REPO_ROOT/scripts/render-manifests.sh" >/dev/null
  oc apply -f "$CLUSTER_DIR/manifests/20-agent/litellm.yaml" >/dev/null

  # ConfigMap 이 바뀌어도 파드는 자동으로 다시 읽지 않습니다.
  # 여기서 롤아웃을 강제하지 않으면 "바꿨는데 그대로"가 됩니다.
  oc rollout restart deploy/litellm -n "$AGENT_NAMESPACE" >/dev/null
  oc rollout status deploy/litellm -n "$AGENT_NAMESPACE" --timeout=300s >/dev/null
}

case "$ACTION" in
llama)
  head1 "llama.cpp (CPU) 로 전환"
  oc get deploy llama-cpp -n "$AGENT_NAMESPACE" >/dev/null 2>&1 \
    || die "llama-cpp 가 없습니다. ./scripts/deploy-agent-stack.sh 를 먼저 실행하세요."
  apply_base "http://llama-cpp:8080/v1"
  ok "api_base -> http://llama-cpp:8080/v1"
  ;;

vllm)
  head1 "RHOAI vLLM (GPU) 로 전환"
  READY=$(oc get inferenceservice "$MODEL_NAME" -n "$RHOAI_NAMESPACE" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ "$READY" == "True" ]] \
    || die "InferenceService $MODEL_NAME 이 Ready 가 아닙니다. ./scripts/deploy-model.sh 를 먼저 실행하세요."

  # 네임스페이스가 다릅니다. FQDN 으로 써야 합니다.
  # agent-lab 안에서 짧은 이름으로 부르면 해석되지 않습니다.
  BASE="http://${MODEL_NAME}-predictor.${RHOAI_NAMESPACE}.svc.cluster.local:8080/v1"
  apply_base "$BASE"
  ok "api_base -> $BASE"
  printf "\n"
  info "NetworkPolicy 를 걸어 둔 상태라면 agent-lab -> $RHOAI_NAMESPACE 를 열어야 합니다"
  ;;

status)
  head1 "현재 백엔드"
  B=$(current_base)
  info "api_base  ${B:-(조회 실패)}"
  case "$B" in
    *llama-cpp*) ok "llama.cpp (CPU)" ;;
    *predictor*) ok "RHOAI vLLM (GPU)" ;;
    *) warn "알 수 없는 백엔드" ;;
  esac
  printf "\n"
  ;;
*) die "사용법: $0 llama | vllm | status" ;;
esac

printf "\n"
info "확인:  ./scripts/verify-agent-stack.sh 3"
printf "\n"
