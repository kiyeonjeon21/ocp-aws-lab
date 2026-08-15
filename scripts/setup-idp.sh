#!/usr/bin/env bash
# htpasswd IdP 를 붙여 kubeadmin 말고 실제 사용자로 로그인하게 합니다.
#
#   ./scripts/setup-idp.sh                 # .env 의 IDP_USERS 사용
#   ./scripts/setup-idp.sh alice bob       # 사용자 지정
#   ./scripts/setup-idp.sh --show          # 지금 설정과 비밀번호 위치만 보기
#
# ------------------------------------------------------------------
# 왜 htpasswd 인가
# ------------------------------------------------------------------
# OCP 는 IdP 없이 설치되면 kubeadmin 하나뿐입니다.
# 그 계정으로는 RBAC 도 감사 로그도 의미가 없습니다. 전부 같은 사람입니다.
#
# 선택지는 여럿인데 이 랩에는 htpasswd 가 맞습니다.
#   htpasswd   외부 의존 0. Secret 하나. 폐쇄망에서 그대로 동작
#   GitHub/Google  인터넷 필요. 폐쇄망에서 불가
#   LDAP/AD    고객사 실물에 가장 가깝지만 서버가 있어야 함
#   Keycloak   실무형 정답. 오퍼레이터 + realm + client 설정이 붙음
#
# htpasswd 로 "IdP 를 붙이면 무엇이 달라지는가" 를 먼저 보고,
# 그 다음에 Keycloak 으로 올라가는 순서가 낭비가 없습니다.
#
# ------------------------------------------------------------------
# 붙이고 나면 달라지는 것
# ------------------------------------------------------------------
#   - 웹 콘솔에 로그인 선택지가 생깁니다 (htpasswd / kube:admin)
#   - RHOAI 대시보드가 그 사용자로 들어갑니다. RHOAI 는 OCP OAuth 를 그대로 씁니다
#   - RoleBinding 이 의미를 갖습니다. 누가 무엇을 했는지 감사 로그에 남습니다
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need_cluster

SECRET=htpass-secret
IDP_NAME=htpasswd
OUT="$CLUSTER_DIR/auth/htpasswd-users.txt"

if [[ "${1:-}" == "--show" ]]; then
  head1 "현재 IdP"
  oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}  {.name}  ({.type}){"\n"}{end}' 2>/dev/null
  [[ -f "$OUT" ]] && { printf "\n"; ok "비밀번호: $OUT"; } || warn "비밀번호 파일이 없습니다"
  printf "\n"
  exit 0
fi

# 사용자 목록. 인자 > .env > 기본값
if [[ $# -gt 0 ]]; then
  USERS=("$@")
else
  read -r -a USERS <<<"${IDP_USERS:-devuser admin1}"
fi

command -v htpasswd >/dev/null 2>&1 \
  || die "htpasswd 가 없습니다. macOS 는 기본 포함이고, 없으면: brew install httpd"

head1 "사용자 생성"

TMPF=$(mktemp); trap 'rm -f "$TMPF"' EXIT
mkdir -p "$(dirname "$OUT")"
: > "$OUT"; chmod 600 "$OUT"

for u in "${USERS[@]}"; do
  # 비밀번호는 로컬에서 만들고 clusters/ 아래에만 둡니다.
  # clusters/ 는 gitignore 되므로 커밋되지 않습니다.
  PW=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
  if [[ -s "$TMPF" ]]; then
    htpasswd -bB "$TMPF" "$u" "$PW" >/dev/null 2>&1
  else
    htpasswd -c -bB "$TMPF" "$u" "$PW" >/dev/null 2>&1
  fi
  printf '%s\t%s\n' "$u" "$PW" >> "$OUT"
  ok "$u"
done

head1 "클러스터 적용"

# Secret 은 openshift-config 에 있어야 합니다. 다른 네임스페이스면 OAuth 가 못 읽습니다.
if oc get secret "$SECRET" -n openshift-config >/dev/null 2>&1; then
  oc set data secret/"$SECRET" -n openshift-config --from-file=htpasswd="$TMPF" >/dev/null
  ok "Secret 갱신"
else
  oc create secret generic "$SECRET" --from-file=htpasswd="$TMPF" -n openshift-config >/dev/null
  ok "Secret 생성"
fi

# OAuth 는 클러스터에 하나뿐인 싱글턴입니다(이름이 cluster).
# 기존 identityProviders 를 지우지 않도록 이름으로 합쳐 넣습니다.
CUR=$(oc get oauth cluster -o json)
NEW=$(jq --arg n "$IDP_NAME" --arg s "$SECRET" '
  .spec.identityProviders = (
    ((.spec.identityProviders // []) | map(select(.name != $n)))
    + [{
        name: $n,
        mappingMethod: "claim",
        type: "HTPasswd",
        htpasswd: { fileData: { name: $s } }
      }]
  )' <<<"$CUR")
oc replace -f - >/dev/null <<<"$NEW"
ok "OAuth 에 '$IDP_NAME' 등록"

# 첫 사용자에게 cluster-admin 을 줍니다.
# 랩이라 이렇게 하지만, 실제 환경이라면 최소 권한부터 시작해야 합니다.
ADMIN="${USERS[0]}"
oc adm policy add-cluster-role-to-user cluster-admin "$ADMIN" >/dev/null 2>&1
ok "$ADMIN 에게 cluster-admin"

head1 "반영 대기"
info "OAuth 서버가 새 설정으로 재배포합니다. 1~3분."

# ClusterOperator 의 Progressing 만 보면 안 됩니다.
# 설정을 바꾼 직후에는 아직 Progressing=False 라서 그 순간 통과해버리고,
# 실제 롤아웃은 그 뒤에 시작됩니다. 그 사이에 로그인하면 401 이 납니다.
# 실제로 그렇게 한 번 헛짚었습니다.
#
# Deployment 롤아웃을 직접 기다리는 편이 확실합니다.
sleep 15
oc rollout status deploy/oauth-openshift -n openshift-authentication --timeout=300s >/dev/null 2>&1 \
  && ok "oauth-openshift 롤아웃 완료" \
  || warn "롤아웃 확인 실패. 잠시 뒤 로그인해 보세요"

for _ in $(seq 1 18); do
  A=$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
  P=$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)
  [[ "$A" == "True" && "$P" == "False" ]] && break
  printf "."
  sleep 10
done
printf "\n"
ok "authentication Available" 

head1 "완료"
info "콘솔: https://$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null)"
info "로그인 화면에 'htpasswd' 선택지가 생깁니다"
printf "\n"
info "계정과 비밀번호: $OUT"
info "  (clusters/ 아래라 gitignore 됩니다. 커밋되지 않습니다)"
printf "\n"
info "CLI 로그인:"
info "  oc login -u $ADMIN https://api.$CLUSTER_NAME.$BASE_DOMAIN:6443"
printf "\n"
warn "kubeadmin 은 그대로 남습니다."
warn "실제 환경이라면 IdP 확인 후 kubeadmin 을 지우는 것이 정석입니다:"
warn "  oc delete secret kubeadmin -n kube-system"
printf "\n"
