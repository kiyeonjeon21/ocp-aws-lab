#!/usr/bin/env bash
# LoRA 파인튜닝을 돌리고 결과를 확인합니다.
#
#   ./scripts/tune.sh run       서빙을 내리고 PyTorchJob 실행
#   ./scripts/tune.sh logs      학습 로그 따라가기
#   ./scripts/tune.sh status    잡과 어댑터 상태
#   ./scripts/tune.sh clean     잡 삭제 (어댑터 PVC 는 남깁니다)
#
# ------------------------------------------------------------------
# 서빙을 먼저 내리는 이유
# ------------------------------------------------------------------
# GPU 는 g6.xlarge 한 대(L4 24GB)뿐입니다.
# vLLM 이 VLLM_GPU_UTIL(기본 0.90)로 잡고 있으면 학습 파드는 Pending 에 머뭅니다.
# nvidia.com/gpu 는 나눠 쓸 수 없는 정수 자원입니다. 0.1 장을 요청할 수 없습니다.
#
# 그래서 이 스크립트가 서빙을 replicas=0 으로 내리고 시작합니다.
# 되돌리는 건 restore 입니다. 자동으로 되돌리지 않습니다.
# 학습이 끝나자마자 서빙이 GPU 를 도로 잡으면 어댑터를 확인할 자리가 없어서입니다.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need_cluster

ACTION="${1:-status}"
JOB="lora-${TUNE_ADAPTER_NAME}"
PREDICTOR="${VLLM_MODEL_NAME}-predictor"

# 서빙이 GPU 를 잡고 있는지 확인합니다.
serving_replicas() {
  oc get deploy "$PREDICTOR" -n "$RHOAI_NAMESPACE" \
     -o jsonpath='{.spec.replicas}' 2>/dev/null || echo ""
}

case "$ACTION" in

# ==================================================================
run)
  head1 "1. GPU 확보"

  GPU_TOTAL=$(oc get nodes -l node-role.kubernetes.io/gpu \
    -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
    | awk '{s+=$1} END {print s+0}')
  if [[ "$GPU_TOTAL" -lt 1 ]]; then
    die "GPU 노드가 없습니다.
  ./scripts/gpu-node.sh up 1
  드라이버까지 준비되는 데 10~20분 걸립니다."
  fi
  ok "GPU $GPU_TOTAL 장"

  R=$(serving_replicas)
  if [[ -n "$R" && "$R" != "0" ]]; then
    oc scale deploy/"$PREDICTOR" -n "$RHOAI_NAMESPACE" --replicas=0 >/dev/null
    ok "서빙 내림 ($PREDICTOR replicas=$R -> 0)"
    info "학습이 끝나면 되돌리세요: $0 restore"
  else
    ok "서빙이 이미 내려가 있음"
  fi

  head1 "2. 이전 잡 정리"
  # PyTorchJob 은 spec 이 대부분 immutable 이라 다시 apply 해도 안 바뀝니다.
  # 같은 이름으로 다시 돌리려면 지우고 만들어야 합니다.
  if oc get pytorchjob "$JOB" -n "$RHOAI_NAMESPACE" >/dev/null 2>&1; then
    oc delete pytorchjob "$JOB" -n "$RHOAI_NAMESPACE" --wait=true >/dev/null 2>&1
    ok "이전 $JOB 삭제"
  else
    info "이전 잡 없음"
  fi

  head1 "3. 실행"
  D="$CLUSTER_DIR/manifests/80-tuning"
  [[ -d "$D" ]] || die "$D 가 없습니다. 먼저: ./scripts/render-manifests.sh"
  oc apply -f "$D" >/dev/null || die "적용 실패"
  ok "PyTorchJob $JOB 적용"

  printf "\n"
  info "베이스 모델   $TUNE_BASE_MODEL"
  info "어댑터 이름   $TUNE_ADAPTER_NAME"
  printf "\n"
  info "로그:  $0 logs"
  info "상태:  $0 status"
  printf "\n"
  ;;

# ==================================================================
logs)
  # 파드 이름은 PyTorchJob 이 정합니다. <job>-master-0 규칙이지만
  # 버전에 따라 접미사가 붙을 수 있어 라벨로 찾습니다.
  POD=$(oc get pods -n "$RHOAI_NAMESPACE" \
        -l training.kubeflow.org/job-name="$JOB" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -n "$POD" ]] || die "$JOB 의 파드를 찾을 수 없습니다. $0 status 로 확인하세요"
  info "파드: $POD"
  printf "\n"
  oc logs -f "$POD" -n "$RHOAI_NAMESPACE"
  ;;

# ==================================================================
status)
  head1 "PyTorchJob"
  oc get pytorchjob "$JOB" -n "$RHOAI_NAMESPACE" \
     -o custom-columns=NAME:.metadata.name,STATE:.status.conditions[-1].type,AGE:.metadata.creationTimestamp \
     --no-headers 2>/dev/null | sed 's/^/  /' || info "$JOB 없음"

  head1 "파드"
  oc get pods -n "$RHOAI_NAMESPACE" -l training.kubeflow.org/job-name="$JOB" \
     --no-headers 2>/dev/null | sed 's/^/  /' || info "파드 없음"

  head1 "GPU 를 지금 누가 쓰나"
  # 어느 파드가 GPU 를 점유 중인지. 학습이 Pending 일 때 제일 먼저 볼 곳입니다.
  oc get pods -A -o json 2>/dev/null | jq -r '
    .items[]
    | select(.status.phase=="Running")
    | . as $p
    | .spec.containers[]
    | select(.resources.requests["nvidia.com/gpu"] // .resources.limits["nvidia.com/gpu"])
    | "  \($p.metadata.namespace)/\($p.metadata.name)  \(.resources.limits["nvidia.com/gpu"] // .resources.requests["nvidia.com/gpu"])장"' \
    || info "GPU 를 쓰는 파드 없음"

  head1 "어댑터"
  # PVC 안을 보려면 파드가 하나 필요합니다.
  # 학습 파드가 남아 있으면 그걸 쓰고, 없으면 조회를 건너뜁니다.
  POD=$(oc get pods -n "$RHOAI_NAMESPACE" -l training.kubeflow.org/job-name="$JOB" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -n "$POD" ]]; then
    oc exec "$POD" -n "$RHOAI_NAMESPACE" -- \
      sh -c "ls -la /out/$TUNE_ADAPTER_NAME 2>/dev/null" 2>/dev/null | sed 's/^/  /' \
      || info "아직 어댑터가 없습니다"
  else
    info "학습 파드가 없어 PVC 내용을 볼 수 없습니다"
  fi

  head1 "서빙"
  R=$(serving_replicas)
  if [[ "$R" == "0" ]]; then
    warn "$PREDICTOR 가 내려가 있습니다 (replicas=0). 되돌리려면: $0 restore"
  elif [[ -n "$R" ]]; then
    ok "$PREDICTOR replicas=$R"
  else
    info "$PREDICTOR 없음"
  fi
  printf "\n"
  ;;

# ==================================================================
restore)
  head1 "서빙 복구"
  R=$(serving_replicas)
  [[ -n "$R" ]] || die "$PREDICTOR 가 없습니다"
  if [[ "$R" == "0" ]]; then
    oc scale deploy/"$PREDICTOR" -n "$RHOAI_NAMESPACE" --replicas=1 >/dev/null
    ok "$PREDICTOR replicas=1"
    info "모델 로딩에 2~5분 걸립니다:"
    info "  oc get pods -n $RHOAI_NAMESPACE -l app=isvc.$PREDICTOR"
  else
    ok "이미 올라가 있습니다 (replicas=$R)"
  fi
  printf "\n"
  ;;

# ==================================================================
clean)
  head1 "정리"
  oc delete pytorchjob "$JOB" -n "$RHOAI_NAMESPACE" >/dev/null 2>&1 \
    && ok "$JOB 삭제" || info "$JOB 없음"
  info "어댑터 PVC(tuning-output)는 남깁니다. 지우려면:"
  info "  oc delete pvc tuning-output -n $RHOAI_NAMESPACE"
  printf "\n"
  ;;

*) die "사용법: $0 run | logs | status | restore | clean" ;;
esac
