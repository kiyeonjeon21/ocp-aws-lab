#!/usr/bin/env bash
# agent 스택을 클러스터에 올립니다.
#
#   ./scripts/deploy-agent-stack.sh
#   ./scripts/deploy-agent-stack.sh --wait 900
#
# 선행: 클러스터가 살아 있고 기본 StorageClass 가 있어야 합니다.
#       AWS IPI 는 gp3-csi 가 기본으로 붙으므로 보통 그냥 됩니다.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need_cluster

WAIT=600
[[ "${1:-}" == "--wait" ]] && WAIT="${2:-600}"

M="$CLUSTER_DIR/manifests"

head1 "사전 확인"

SC=$(default_storage_class)
[[ -n "$SC" ]] || die "기본 StorageClass 가 없습니다. PVC 가 전부 Pending 이 됩니다.
  oc get sc 로 확인하세요."
ok "기본 StorageClass  $SC"

# 워커에 실제로 남은 자원을 봅니다.
# llama.cpp 혼자 3Gi 를 request 하기 때문에 minimal 프로파일에서는
# 여기서 미리 막아주는 게 낫습니다. Pending 파드를 30분 들여다보는 것보다 낫습니다.
ALLOC=$(oc get nodes -l node-role.kubernetes.io/worker \
          -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
        | sed 's/Ki$//' | awk '{s+=$1} END {printf "%d", s/1024/1024}')
if [[ "$ALLOC" =~ ^[0-9]+$ ]]; then
  if (( ALLOC < 24 )); then
    warn "워커 전체 allocatable 메모리가 ${ALLOC}Gi 입니다"
    warn "agent 스택은 request 합계만 약 5Gi 이고, OCP 시스템이 이미 상당 부분을 씁니다"
    warn "ai 프로파일(m6i.2xlarge x2)로 재설치하는 걸 권합니다"
  else
    ok "워커 allocatable 메모리 ${ALLOC}Gi"
  fi
fi

[[ -d "$M/10-model" ]] || die "렌더링된 매니페스트가 없습니다. ./scripts/render-manifests.sh 를 먼저 실행하세요."

head1 "적용"

# 순서가 있습니다. 네임스페이스가 10-model 안에 있어서 그게 먼저입니다.
for d in 10-model 20-agent; do
  [[ -d "$M/$d" ]] || continue
  oc apply -f "$M/$d/"
  ok "$d"
done

head1 "기동 대기 (최대 ${WAIT}초)"

# llama-cpp 는 1.1GB 가중치를 받고 모델을 로딩하므로 제일 오래 걸립니다.
# 나머지는 그보다 훨씬 빠릅니다.
for dep in qdrant phoenix litellm llama-cpp open-webui; do
  printf "  %-12s " "$dep"
  if oc rollout status "deploy/$dep" -n "$AGENT_NAMESPACE" \
       --timeout="${WAIT}s" >/dev/null 2>&1; then
    printf "${C_GRN}Ready${C_RST}\n"
  else
    printf "${C_RED}NotReady${C_RST}\n"
    info "    oc describe deploy/$dep -n $AGENT_NAMESPACE"
    info "    oc logs deploy/$dep -n $AGENT_NAMESPACE --all-containers"
  fi
done

head1 "접속"
for r in open-webui phoenix; do
  H=$(oc get route "$r" -n "$AGENT_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [[ -n "$H" ]] && info "$r  https://$H"
done
printf "\n"
info "Route DNS 가 퍼졌는지 확인:  dig +short chat.apps.$CLUSTER_NAME.$BASE_DOMAIN"
info "검증:                        ./scripts/verify-agent-stack.sh"
printf "\n"
