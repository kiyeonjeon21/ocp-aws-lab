#!/usr/bin/env bash
# 모든 스크립트가 source 하는 공통 라이브러리.
# 여기서는 set -e 를 걸지 않습니다. 호출하는 쪽에서 겁니다.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# 레포에 받아둔 openshift-install / oc 를 시스템 PATH보다 우선합니다.
# 버전이 섞이면 디버깅이 지옥이 됩니다.
export PATH="$REPO_ROOT/bin:$PATH"

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_RST=$'\033[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_RST=
fi

ok()   { printf "  ${C_GRN}OK${C_RST}    %s\n" "$*"; }
warn() { printf "  ${C_YEL}WARN${C_RST}  %s\n" "$*"; }
bad()  { printf "  ${C_RED}FAIL${C_RST}  %s\n" "$*"; }
info() { printf "  ${C_DIM}%s${C_RST}\n" "$*"; }
head1() { printf "\n${C_BLU}== %s${C_RST}\n" "$*"; }
die()  { printf "\n${C_RED}error:${C_RST} %s\n" "$*" >&2; exit 1; }

# .env 를 읽어 환경변수로 export 합니다.
load_env() {
  local envfile="$REPO_ROOT/.env"
  [[ -f "$envfile" ]] || die ".env 가 없습니다. 'cp .env.example .env' 후 값을 채우세요."

  set -a
  # shellcheck disable=SC1090
  source "$envfile"
  set +a

  : "${AWS_PROFILE:?.env 에 AWS_PROFILE 이 없습니다}"
  : "${REGION:?.env 에 REGION 이 없습니다}"
  : "${BASE_DOMAIN:?.env 에 BASE_DOMAIN 이 없습니다}"
  : "${CLUSTER_NAME:?.env 에 CLUSTER_NAME 이 없습니다}"
  : "${OWNER:?.env 에 OWNER 가 없습니다}"
  : "${PROFILE:=minimal}"
  : "${AZ:=${REGION}a}"
  : "${SSH_KEY_PATH:=$HOME/.ssh/id_ocp_lab}"
  : "${PULL_SECRET_PATH:=secrets/pull-secret.json}"

  # ~ 를 실제 홈 경로로 펼칩니다.
  SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
  [[ "$PULL_SECRET_PATH" = /* ]] || PULL_SECRET_PATH="$REPO_ROOT/$PULL_SECRET_PATH"

  CLUSTER_DIR="$REPO_ROOT/clusters/$CLUSTER_NAME"
  export AWS_PROFILE REGION BASE_DOMAIN CLUSTER_NAME OWNER PROFILE AZ
  export SSH_KEY_PATH PULL_SECRET_PATH CLUSTER_DIR
  export AWS_PAGER=""
}

# 프로파일별 설치 피크 vCPU (부트스트랩 노드 4 vCPU 포함).
# 설치 중 잠깐이라도 이 수치를 넘으면 쿼터에 걸려 실패합니다.
profile_peak_vcpu() {
  case "$1" in
    minimal) echo 20 ;;   # 3x4 + 2x2 + 4
    compact) echo 28 ;;   # 3x8 + 0   + 4
    sno)     echo 12 ;;   # 1x8 + 0   + 4
    default) echo 28 ;;   # 3x4 + 3x4 + 4
    *) die "알 수 없는 프로파일: $1 (minimal|compact|sno|default)" ;;
  esac
}

# BASE_DOMAIN 에 해당하는 퍼블릭 호스팅 존 ID 를 찾습니다. 없으면 빈 문자열.
find_hosted_zone_id() {
  aws route53 list-hosted-zones-by-name --dns-name "${BASE_DOMAIN}." \
    --query "HostedZones[?Name=='${BASE_DOMAIN}.' && Config.PrivateZone==\`false\`].Id | [0]" \
    --output text 2>/dev/null | sed 's|/hostedzone/||;s|^None$||'
}

# clusters/<name>/metadata.json 에서 infraID 를 읽습니다.
cluster_infra_id() {
  [[ -f "$CLUSTER_DIR/metadata.json" ]] || return 1
  jq -r '.infraID' "$CLUSTER_DIR/metadata.json"
}
