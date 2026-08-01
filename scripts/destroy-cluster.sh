#!/usr/bin/env bash
# 클러스터 삭제. 이 레포에서 가장 중요한 스크립트입니다.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env

if [[ ! -f "$CLUSTER_DIR/metadata.json" ]]; then
  bad "$CLUSTER_DIR/metadata.json 이 없습니다"
  info "자동 삭제는 이 파일에만 의존합니다. 백업이 있는지 확인하세요:"
  ls -1 "$REPO_ROOT/clusters/_backups" 2>/dev/null | sed 's/^/    /' || info "    (백업 없음)"
  printf "\n"
  info "백업이 있다면 metadata.json 을 $CLUSTER_DIR/ 로 복사한 뒤 다시 실행하세요."
  info "그것도 없다면 ./scripts/verify-clean.sh 로 잔여 리소스를 찾아 수동 삭제해야 합니다."
  exit 1
fi

INFRA_ID=$(cluster_infra_id)

head1 "삭제 대상"
info "cluster : $CLUSTER_NAME"
info "infraID : $INFRA_ID"
info "region  : $REGION"
info "aws     : $(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"

# 클러스터가 살아있다면, 워크로드가 동적으로 만든 AWS 리소스를 먼저 정리해야
# destroy 후에 고아 리소스가 남지 않습니다. Service type=LoadBalancer 는 ELB 를,
# PVC 는 EBS 볼륨을 클러스터 바깥에 만듭니다.
export KUBECONFIG="$CLUSTER_DIR/auth/kubeconfig"
if [[ -f "$KUBECONFIG" ]] && oc get ns >/dev/null 2>&1; then
  head1 "워크로드가 만든 AWS 리소스 확인"
  LBSVC=$(oc get svc -A -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"' \
    | grep -v '^openshift-ingress/' || true)
  BOUND=$(oc get pvc -A --no-headers 2>/dev/null | grep -c Bound || true)

  if [[ -n "$LBSVC" ]]; then
    warn "직접 만든 LoadBalancer 서비스가 있습니다. 지우지 않으면 ELB 가 남습니다:"
    sed 's/^/      /' <<<"$LBSVC"
  else
    ok "고아가 될 LoadBalancer 서비스 없음"
  fi
  if [[ "${BOUND:-0}" -gt 0 ]]; then
    warn "Bound 상태 PVC ${BOUND}개. 지우지 않으면 EBS 볼륨이 남을 수 있습니다"
  else
    ok "Bound PVC 없음"
  fi
else
  info "클러스터에 접속할 수 없습니다 (이미 죽었거나 설치 실패). 그대로 진행합니다."
fi

printf "\n"
warn "되돌릴 수 없습니다. 클러스터 이름을 그대로 입력하면 진행합니다."
printf "클러스터 이름 (%s): " "$CLUSTER_NAME"
read -r ans
[[ "$ans" == "$CLUSTER_NAME" ]] || { echo "취소했습니다."; exit 0; }

START=$(date +%s)
head1 "삭제 시작"
openshift-install destroy cluster --dir="$CLUSTER_DIR" --log-level=info
RC=$?
ELAPSED=$(( ($(date +%s) - START) / 60 ))

if (( RC != 0 )); then
  printf "\n"
  bad "destroy 실패 (${ELAPSED}분). metadata.json 은 절대 지우지 말고 다시 실행하세요."
  info "반복 실패하면: ./scripts/verify-clean.sh $INFRA_ID"
  exit $RC
fi

head1 "삭제 완료 (${ELAPSED}분)"

# destroy 가 성공하면 metadata.json 이 사라집니다. 잔여물 검사는 infraID 로 합니다.
"$REPO_ROOT/scripts/verify-clean.sh" "$INFRA_ID"
