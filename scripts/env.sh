#!/usr/bin/env bash
# openshift-install / oc / aws 를 직접 실행할 때 source 해서 씁니다.
#
#   source scripts/env.sh
#   openshift-install wait-for bootstrap-complete --dir=$CLUSTER_DIR
#   oc get co
#
# 이걸 안 하면 openshift-install 이 AWS 기본 프로파일로 붙습니다.
# 이 계정에는 다른 프로젝트 IAM 유저가 여럿 있어서, 권한 오류로 끝나면 다행이고
# 최악의 경우 의도하지 않은 계정 컨텍스트로 리소스를 건드립니다.
# 스크립트(create/destroy/preflight)를 통해 실행할 때는 자동으로 처리됩니다.

# 실행이 아니라 source 여야 합니다.
# shebang 이 bash 라서 직접 실행하면 항상 bash 로 들어옵니다.
# 즉 이 검사는 bash 쪽만 보면 충분하고, zsh 로 들어왔다는 건 source 됐다는 뜻입니다.
if [ -z "${ZSH_VERSION:-}" ] && [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "이 파일은 실행이 아니라 source 해야 합니다:  source scripts/env.sh" >&2
  exit 1
fi

# lib.sh 위치도 셸마다 다르게 알아내야 합니다. 이유는 lib.sh 상단 주석 참고.
if [ -n "${ZSH_VERSION:-}" ]; then
  _env_src="${(%):-%x}"
else
  _env_src="${BASH_SOURCE[0]}"
fi
source "$(cd "$(dirname "$_env_src")" && pwd)/lib.sh"
unset _env_src
load_env

if [[ -f "$CLUSTER_DIR/auth/kubeconfig" ]]; then
  export KUBECONFIG="$CLUSTER_DIR/auth/kubeconfig"
fi

head1 "환경 로드됨"
info "AWS_PROFILE  = $AWS_PROFILE"
info "REGION       = $REGION"
info "CLUSTER_DIR  = $CLUSTER_DIR"
info "KUBECONFIG   = ${KUBECONFIG:-(없음, 아직 설치 전)}"
info "PATH         = $REPO_ROOT/bin 우선"
printf "\n"
