#!/usr/bin/env bash
# 클러스터 생성. 35~45분 걸립니다.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env

[[ -d "$CLUSTER_DIR" ]] || die "$CLUSTER_DIR 가 없습니다. 먼저 render-config.sh 를 실행하세요."

# 이전 시도가 install-config.yaml 을 소비했다면 사본에서 복구합니다.
if [[ ! -f "$CLUSTER_DIR/install-config.yaml" ]]; then
  if [[ -f "$CLUSTER_DIR/install-config.yaml.bak" && ! -f "$CLUSTER_DIR/metadata.json" ]]; then
    cp "$CLUSTER_DIR/install-config.yaml.bak" "$CLUSTER_DIR/install-config.yaml"
    warn "install-config.yaml 을 사본에서 복구했습니다"
  elif [[ -f "$CLUSTER_DIR/metadata.json" ]]; then
    die "이미 설치된 클러스터입니다 (infraID: $(cluster_infra_id)). 재설치하려면 먼저 destroy 하세요."
  else
    die "install-config.yaml 이 없습니다. render-config.sh 를 먼저 실행하세요."
  fi
fi

head1 "설치 대상"
info "cluster : $CLUSTER_NAME"
info "region  : $REGION / $AZ"
info "API     : api.$CLUSTER_NAME.$BASE_DOMAIN"
info "aws     : $(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"
printf "\n"
warn "설치가 시작되면 과금이 시작됩니다. 실습이 끝나면 반드시 destroy-cluster.sh 를 실행하세요."
printf "\n계속할까요? [y/N] "
read -r ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "취소했습니다."; exit 0; }

# metadata.json 은 destroy 의 유일한 근거입니다. 설치가 중단되든 실패하든
# 이 파일만 있으면 리소스를 회수할 수 있으므로 종료 시 무조건 백업합니다.
BACKUP_DIR="$REPO_ROOT/clusters/_backups/$CLUSTER_NAME-$(date +%Y%m%d-%H%M%S)"
backup_metadata() {
  if [[ -f "$CLUSTER_DIR/metadata.json" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp "$CLUSTER_DIR/metadata.json" "$BACKUP_DIR/"
    printf "\n"
    ok "metadata.json 백업: $BACKUP_DIR/metadata.json"
    info "infraID: $(cluster_infra_id)"
  fi
}
trap backup_metadata EXIT

START=$(date +%s)
head1 "설치 시작 (35~45분)"
openshift-install create cluster --dir="$CLUSTER_DIR" --log-level=info
RC=$?
ELAPSED=$(( ($(date +%s) - START) / 60 ))

if (( RC != 0 )); then
  printf "\n"
  bad "설치 실패 (${ELAPSED}분 경과)"
  info "로그 수집 : openshift-install gather bootstrap --dir=$CLUSTER_DIR"
  info "리소스 회수: ./scripts/destroy-cluster.sh   <-- 실패해도 리소스는 남아있습니다. 반드시 실행하세요"
  exit $RC
fi

head1 "설치 완료 (${ELAPSED}분)"
cat <<EOF

  export KUBECONFIG=$CLUSTER_DIR/auth/kubeconfig
  oc get nodes
  oc get co

  콘솔 : https://console-openshift-console.apps.$CLUSTER_NAME.$BASE_DOMAIN
  계정 : kubeadmin / $CLUSTER_DIR/auth/kubeadmin-password

  ${C_YEL}실습이 끝나면:${C_RST} ./scripts/destroy-cluster.sh

EOF
