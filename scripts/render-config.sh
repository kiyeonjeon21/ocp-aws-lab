#!/usr/bin/env bash
# 프로파일 템플릿 -> clusters/<name>/install-config.yaml
#
#   ./scripts/render-config.sh          # .env 의 PROFILE
#   ./scripts/render-config.sh sno
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env

PROFILE="${1:-$PROFILE}"
TPL="$REPO_ROOT/profiles/$PROFILE.yaml.tpl"
[[ -f "$TPL" ]] || die "프로파일 템플릿이 없습니다: $TPL"
[[ -f "$PULL_SECRET_PATH" ]] || die "pull secret 이 없습니다: $PULL_SECRET_PATH"
[[ -f "$SSH_KEY_PATH.pub" ]] || die "SSH 공개키가 없습니다: $SSH_KEY_PATH.pub (preflight.sh 가 만들어줍니다)"

if [[ -f "$CLUSTER_DIR/metadata.json" ]]; then
  die "$CLUSTER_DIR 에 살아있는 클러스터가 있습니다. 먼저 destroy-cluster.sh 를 실행하세요."
fi

mkdir -p "$CLUSTER_DIR"

# pull secret 은 한 줄 JSON 이어야 합니다. 줄바꿈이 들어가면 YAML 이 깨집니다.
PULL_SECRET=$(jq -c . "$PULL_SECRET_PATH")
SSH_PUBLIC_KEY=$(< "$SSH_KEY_PATH.pub")
export PULL_SECRET SSH_PUBLIC_KEY

OUT="$CLUSTER_DIR/install-config.yaml"

# 치환할 변수를 명시적으로 나열합니다. 목록을 주지 않으면 envsubst 가
# pull secret 안의 $ 문자까지 건드릴 수 있습니다.
envsubst '$BASE_DOMAIN $CLUSTER_NAME $REGION $AZ $OWNER $PULL_SECRET $SSH_PUBLIC_KEY' \
  < "$TPL" > "$OUT"

# 치환이 안 된 자리가 남았는지 확인합니다.
if grep -n '\${' "$OUT" >/dev/null 2>&1; then
  grep -n '\${' "$OUT" >&2
  die "치환되지 않은 변수가 남아 있습니다."
fi

# YAML 문법과 필수 필드를 확인합니다.
python3 - "$OUT" <<'PY'
import sys, re
p = sys.argv[1]
text = open(p).read()
for key in ("baseDomain:", "metadata:", "controlPlane:", "compute:", "pullSecret:", "sshKey:"):
    if key not in text:
        sys.exit(f"install-config 에 {key} 가 없습니다")
# 최소한의 들여쓰기 검사. PyYAML 은 macOS 기본 python3 에 없을 수 있어 직접 봅니다.
if re.search(r"^\t", text, re.M):
    sys.exit("탭 문자가 들어있습니다. YAML 은 탭을 허용하지 않습니다")
PY

chmod 600 "$OUT"

# openshift-install 은 create 과정에서 install-config.yaml 을 소비(삭제)합니다.
# 재시도할 때 다시 렌더링하지 않아도 되도록 사본을 남깁니다.
cp "$OUT" "$CLUSTER_DIR/install-config.yaml.bak"
chmod 600 "$CLUSTER_DIR/install-config.yaml.bak"

head1 "렌더링 완료"
ok "$OUT"
info "profile=$PROFILE  peak vCPU=$(profile_peak_vcpu "$PROFILE")"
info "API   : api.$CLUSTER_NAME.$BASE_DOMAIN"
info "Apps  : *.apps.$CLUSTER_NAME.$BASE_DOMAIN"
printf "\n다음: ./scripts/create-cluster.sh\n\n"
