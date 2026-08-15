#!/usr/bin/env bash
# agent 스택 검증.
#
#   ./scripts/verify-agent-stack.sh              # 전체
#   ./scripts/verify-agent-stack.sh 3 4          # 골라서
#   ./scripts/verify-agent-stack.sh --baseline   # 오프라인 스위치 ON/OFF 기동시간 비교
#
# 개별 검사가 실패해도 나머지는 계속 돕니다. 그래서 -e 를 걸지 않습니다.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need_cluster

NS="$AGENT_NAMESPACE"
PASS=0; FAIL=0; SKIP=0
pass() { ok "$*";   PASS=$((PASS+1)); }
fail() { bad "$*";  FAIL=$((FAIL+1)); }
skip() { warn "$*"; SKIP=$((SKIP+1)); }

# 임시 파드에서 명령을 돌립니다.
# 스택 이미지들은 대부분 curl 이 없어서 exec 로는 안 됩니다.
in_pod() {
  oc run "verify-$RANDOM" --rm -i --restart=Never --quiet \
    --image="$IMAGE_UBI" --image-pull-policy=IfNotPresent \
    -n "$NS" --command -- /bin/sh -c "$1" 2>/dev/null
}

# 파드의 PodScheduled -> Ready 초. 조건이 없으면 빈 문자열.
ready_seconds() {
  oc get pod -l "app=$1" -n "$NS" \
    -o jsonpath='{.items[0].status.conditions}' 2>/dev/null \
  | python3 -c '
import sys, json, datetime
try:
    conds = json.load(sys.stdin)
except Exception:
    sys.exit(0)
t = {c["type"]: c["lastTransitionTime"] for c in conds}
if "PodScheduled" not in t or "Ready" not in t:
    sys.exit(0)
f = lambda s: datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
print(int((f(t["Ready"]) - f(t["PodScheduled"])).total_seconds()))
' 2>/dev/null
}

# ------------------------------------------------------------------
# --baseline: 오프라인 스위치를 뒤집어 기동 시간을 비교합니다
# ------------------------------------------------------------------
# 이 랩에서 실제로 얻어가는 숫자가 이겁니다.
# 폐쇄망에서 "왜 이렇게 느리냐"는 티켓의 정체를 초 단위로 봅니다.
if [[ "${1:-}" == "--baseline" ]]; then
  head1 "기동 시간 비교"
  info "Open WebUI 를 두 설정으로 각각 재기동합니다. 5~10분 걸립니다."

  measure() {
    local mode="$1"
    if [[ "$mode" == offline ]]; then
      oc set env deploy/open-webui -n "$NS" \
        OFFLINE_MODE=true HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
        ENABLE_VERSION_UPDATE_CHECK=false >/dev/null
    else
      oc set env deploy/open-webui -n "$NS" \
        OFFLINE_MODE=false HF_HUB_OFFLINE=0 TRANSFORMERS_OFFLINE=0 \
        ENABLE_VERSION_UPDATE_CHECK=true >/dev/null
    fi
    oc rollout status deploy/open-webui -n "$NS" --timeout=900s >/dev/null 2>&1
    sleep 3
    ready_seconds open-webui
  }

  ON=$(measure offline)
  info "오프라인 스위치 ON   ${ON:-측정실패} 초"
  OFF=$(measure online)
  info "오프라인 스위치 OFF  ${OFF:-측정실패} 초"

  if [[ "$ON" =~ ^[0-9]+$ && "$OFF" =~ ^[0-9]+$ ]]; then
    printf "\n  차이: %d 초\n" $((OFF - ON))
    printf "  %s\n\n" "인터넷이 있으면 OFF 가 조금 더 걸리는 정도지만, 폐쇄망에서는"
    printf "  %s\n\n" "같은 OFF 설정이 타임아웃까지 매달려 수십 초에서 분 단위로 벌어집니다."
  fi

  # 렌더링된 값으로 되돌립니다. 측정 때문에 클러스터 상태가 어긋나면 안 됩니다.
  oc apply -f "$CLUSTER_DIR/manifests/20-agent/open-webui.yaml" >/dev/null
  ok "매니페스트 값으로 복원"
  exit 0
fi

WANT="$*"
run() { [[ -z "$WANT" ]] || [[ " $WANT " == *" $1 "* ]]; }

printf "\n${C_BLU}agent 스택 검증${C_RST}  ns=$NS\n"

# ---------------------------------------------------------------- 1
if run 1; then
head1 "1. 파드 상태"
NOTREADY=$(oc get pods -n "$NS" --no-headers 2>/dev/null \
           | awk '$3 != "Running" && $3 != "Completed" {print $1" "$3}')
if [[ -z "$NOTREADY" ]]; then
  N=$(oc get pods -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  pass "파드 ${N}개 전부 Running"
else
  fail "Running 이 아닌 파드가 있습니다"
  sed 's/^/      /' <<<"$NOTREADY"
fi
fi

# ---------------------------------------------------------------- 2
if run 2; then
head1 "2. PVC"
PENDING=$(oc get pvc -n "$NS" --no-headers 2>/dev/null | awk '$2 != "Bound" {print $1" "$2}')
if [[ -z "$PENDING" ]]; then
  pass "PVC 전부 Bound"
else
  fail "Bound 되지 않은 PVC 가 있습니다. StorageClass 를 확인하세요"
  sed 's/^/      /' <<<"$PENDING"
fi
fi

# ---------------------------------------------------------------- 3
if run 3; then
head1 "3. 추론 루프"
KEY=$(oc get secret litellm-secret -n "$NS" -o jsonpath='{.data.master-key}' 2>/dev/null | base64 -d)
if [[ -z "$KEY" ]]; then
  skip "litellm-secret 이 없습니다"
else
  R=$(in_pod "curl -sS --max-time 180 http://litellm:4000/v1/chat/completions \
        -H 'Content-Type: application/json' -H 'Authorization: Bearer $KEY' \
        -d '{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"2+2? Answer with the number only.\"}],\"max_tokens\":16}'")
  if grep -q '"content"' <<<"$R"; then
    C=$(python3 -c 'import sys,json; print(json.load(sys.stdin)["choices"][0]["message"]["content"].strip())' <<<"$R" 2>/dev/null)
    pass "LiteLLM -> 모델 응답: ${C:-(파싱실패)}"
  else
    fail "추론 실패"
    sed 's/^/      /' <<<"${R:0:400}"
  fi
fi
fi

# ---------------------------------------------------------------- 4
if run 4; then
head1 "4. 벡터 DB 왕복"
# 임베딩 모델과 묶지 않습니다. 고정 벡터로 Qdrant 만 확인합니다.
# 묶어 두면 실패했을 때 벡터 DB 문제인지 임베딩 문제인지 알 수 없게 됩니다.
R=$(in_pod "
  curl -sS -X PUT http://qdrant:6333/collections/verify \
    -H 'Content-Type: application/json' \
    -d '{\"vectors\":{\"size\":4,\"distance\":\"Cosine\"}}' >/dev/null
  curl -sS -X PUT 'http://qdrant:6333/collections/verify/points?wait=true' \
    -H 'Content-Type: application/json' \
    -d '{\"points\":[{\"id\":1,\"vector\":[0.1,0.2,0.3,0.4]}]}' >/dev/null
  curl -sS -X POST http://qdrant:6333/collections/verify/points/search \
    -H 'Content-Type: application/json' \
    -d '{\"vector\":[0.1,0.2,0.3,0.4],\"limit\":1}'
  curl -sS -X DELETE http://qdrant:6333/collections/verify >/dev/null
")
if grep -q '"id":1' <<<"$R"; then
  pass "쓰기/검색 왕복 성공"
else
  fail "Qdrant 왕복 실패. 스토리지 쪽을 보세요"
  sed 's/^/      /' <<<"${R:0:300}"
fi
fi

# ---------------------------------------------------------------- 5
if run 5; then
head1 "5. Route"
for r in open-webui phoenix; do
  H=$(oc get route "$r" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null)
  if [[ -z "$H" ]]; then
    skip "$r Route 없음"
    continue
  fi
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "https://$H/" 2>/dev/null)
  if [[ "$CODE" =~ ^(200|302|307)$ ]]; then
    pass "$r  https://$H  ($CODE)"
  else
    fail "$r  https://$H  응답 $CODE"
    info "    Route DNS 전파에 몇 분 걸릴 수 있습니다: dig +short $H"
  fi
done
fi

# ---------------------------------------------------------------- 6
if run 6; then
head1 "6. 기동 시간"
# 이 숫자가 폐쇄망 랩의 대조군입니다.
# ocp-airgap-lab 에서 같은 검사를 돌려 나온 값과 나란히 놓고 보세요.
for app in qdrant litellm phoenix open-webui llama-cpp; do
  S=$(ready_seconds "$app")
  if [[ "$S" =~ ^[0-9]+$ ]]; then
    printf "  %-12s %4s 초\n" "$app" "$S"
  else
    printf "  %-12s %s\n" "$app" "측정 불가"
  fi
done
info "AGENT_OFFLINE=$AGENT_OFFLINE 로 렌더링된 상태의 값입니다"
fi

# ---------------------------------------------------------------- 7
if run 7; then
head1 "7. egress (여기서는 되는 게 정상입니다)"
# ocp-airgap-lab 의 같은 번호 검사와 기대값이 정반대입니다.
# 거기서는 이 호출이 실패해야 통과입니다.
# 두 레포를 같이 보는 사람이 헷갈리지 않게 여기에 적어 둡니다.
R=$(in_pod "curl -sS -o /dev/null -w '%{http_code}' --max-time 15 https://quay.io/ || echo FAIL")
if [[ "$R" =~ ^(200|301|302)$ ]]; then
  pass "파드에서 quay.io 도달 ($R). 인터넷 있는 클러스터가 맞습니다"
else
  fail "파드가 외부로 못 나갑니다 ($R). NAT Gateway 나 라우팅을 확인하세요"
fi
fi

# ---------------------------------------------------------------- 결과
printf "\n"
printf "  통과 %d  실패 %d  건너뜀 %d\n\n" "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 )) || exit 1
