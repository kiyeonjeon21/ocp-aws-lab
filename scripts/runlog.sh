#!/usr/bin/env bash
# 실행 기록. AWS 에 실제로 올릴 때 무엇을 언제 했고 무엇이 만들어졌는지 남깁니다.
#
#   ./scripts/runlog.sh new 01-install "ai 프로파일 설치"
#   ./scripts/runlog.sh note "AZ 를 2a 로 바꿈. 2b 에 g6 가 없어서"
#   ./scripts/runlog.sh res instance i-0abc123 "gpu worker"
#   ./scripts/runlog.sh run -- ./scripts/create-cluster.sh
#   ./scripts/runlog.sh done ok
#
#   ./scripts/runlog.sh path      # 지금 열려 있는 기록 파일 경로
#   ./scripts/runlog.sh list      # 지난 기록 목록
#   ./scripts/runlog.sh show      # 지금 기록 내용 보기
#
# ------------------------------------------------------------
# 왜 필요한가
# ------------------------------------------------------------
# 이 랩은 만들었다 지웠다를 반복하고, 그동안 시간당 과금이 계속 돕니다.
# 2회차에 반드시 다시 찾게 되는 것이 세 가지인데
# 터미널 스크롤백은 그때쯤 이미 사라져 있습니다.
#
#   1. 만들어진 AWS 리소스 ID  - destroy 가 실패했을 때 손으로 지울 목록이 됩니다
#   2. 실패한 명령과 그 출력    - 같은 실수를 두 번 하지 않기 위해
#   3. 시작/종료 시각          - 이 실습이 실제로 얼마를 썼는지
#
# 기록은 docs/runlog/ 에 마크다운으로 쌓이고 커밋합니다.
# 시크릿은 남기지 마세요. 이 파일들은 레포에 들어갑니다.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# .env 없이도 동작해야 합니다. 기록은 설치 전에도 남길 수 있어야 하니까요.
if [[ -f "$REPO_ROOT/.env" ]]; then
  load_env 2>/dev/null || true
fi

LOGDIR="$REPO_ROOT/docs/runlog"
POINTER="$LOGDIR/.current"

mkdir -p "$LOGDIR"

now_local() { date '+%Y-%m-%d %H:%M:%S %Z'; }
now_epoch() { date '+%s'; }

# ------------------------------------------------------------
# 마크다운 조립
# ------------------------------------------------------------
# 기록 파일은 커밋되므로 markdownlint 를 통과해야 합니다.
# 블록을 이어 붙일 때마다 빈 줄을 손으로 세면 반드시 어긋납니다.
# 그래서 "끝의 빈 줄을 다 지우고 정확히 하나만 다시 넣는" 규칙으로 고정합니다.
#
# 이 한 가지로 세 규칙이 동시에 지켜집니다.
#   MD012 연속 빈 줄 금지
#   MD022 제목 앞뒤 빈 줄
#   MD032 리스트 앞뒤 빈 줄
trim_trailing_blanks() {
  local f="$1"
  awk '{ a[NR] = $0; if ($0 != "") last = NR }
       END { for (i = 1; i <= last; i++) print a[i] }' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}

# 앞에 빈 줄 하나를 두고 stdin 을 이어 붙입니다.
append_block() {
  local f="$1"
  trim_trailing_blanks "$f"
  printf '\n' >>"$f"
  cat >>"$f"
}

current_log() {
  [[ -f "$POINTER" ]] || die "열려 있는 기록이 없습니다.  ./scripts/runlog.sh new <phase>"
  local p; p="$(cat "$POINTER")"
  [[ -f "$p" ]] || die "기록 파일이 사라졌습니다: $p"
  printf '%s' "$p"
}

# GPU 노드가 떠 있으면 시간당 비용이 그만큼 늘어납니다.
# 클러스터가 없으면 조용히 0 을 반환합니다. 기록은 설치 전에도 열 수 있어야 합니다.
gpu_node_count() {
  local kc="$CLUSTER_DIR/auth/kubeconfig"
  [[ -f "$kc" ]] || { echo 0; return; }
  KUBECONFIG="$kc" oc get nodes -l node-role.kubernetes.io/gpu \
    --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0
}

# ------------------------------------------------------------
cmd_new() {
  local phase="${1:-untitled}"
  local title="${2:-$phase}"
  local date_str; date_str="$(date '+%Y-%m-%d')"
  local file="$LOGDIR/${date_str}-${phase}.md"

  # 같은 날 같은 단계를 다시 돌리는 건 흔합니다. 덮어쓰지 않고 번호를 붙입니다.
  local n=2
  while [[ -f "$file" ]]; do
    file="$LOGDIR/${date_str}-${phase}-${n}.md"
    n=$((n + 1))
  done

  local ocp_ver
  ocp_ver="$(openshift-install version 2>/dev/null | head -1 | awk '{print $2}')"

  cat >"$file" <<EOF
# ${title}

- **단계**: \`${phase}\`
- **시작**: $(now_local)
- **실행자**: ${OWNER:-unknown}
- **리전 / AZ**: ${REGION:-?} / ${AZ:-?}
- **프로파일**: ${PROFILE:-?} (시간당 약 \$$(profile_hourly_cost "${PROFILE:-minimal}"))
- **클러스터**: ${CLUSTER_NAME:-?}.${BASE_DOMAIN:-?} (OCP ${ocp_ver:-?})
- **AWS 프로파일**: ${AWS_PROFILE:-?}
- **커밋**: $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "(아직 커밋 없음)")$(git -C "$REPO_ROOT" diff --quiet 2>/dev/null || echo " (작업 트리 변경됨)")

## 만들어진 리소스

| 종류 | ID | 설명 | 시각 |
| --- | --- | --- | --- |

## 기록

EOF

  printf '%s' "$file" >"$POINTER"
  # epoch 을 따로 저장합니다. 마크다운에서 되파싱하면 로케일에 따라 깨집니다.
  printf '%s' "$(now_epoch)" >"${file}.started"

  head1 "기록 시작"
  ok "$file"
  info "이제 note / res / run 으로 쌓고, 끝나면 done 하세요."
}

# ------------------------------------------------------------
cmd_note() {
  local file; file="$(current_log)"
  local text="$*"
  [[ -n "$text" ]] || die "내용이 비었습니다.  runlog.sh note \"...\""

  # 연속된 note 는 한 리스트로 묶여야 합니다.
  # 사이에 빈 줄을 넣으면 마크다운이 별개 리스트로 렌더링합니다.
  local entry
  entry=$(printf -- '- `%s` %s' "$(date '+%H:%M:%S')" "$text")

  if [[ "$(tail -1 "$file")" == -* ]]; then
    printf '%s\n' "$entry" >>"$file"
  else
    printf '%s\n' "$entry" | append_block "$file"
  fi
  ok "기록함: $text"
}

# ------------------------------------------------------------
cmd_res() {
  local file; file="$(current_log)"
  local type="${1:?종류가 필요합니다 (instance, machineset, pvc, elb, ...)}"
  local id="${2:?ID 가 필요합니다}"
  local desc="${3:-}"

  local row
  row="| \`${type}\` | \`${id}\` | ${desc} | $(date '+%H:%M:%S') |"

  # 표의 맨 끝에 붙입니다.
  # 헤더 바로 다음에 넣으면 나중에 만든 리소스가 위로 올라가서
  # 생성 순서가 거꾸로 보입니다. destroy 는 역순으로 지워야 하므로 순서가 중요합니다.
  # 구분줄 패턴은 위 cmd_new 의 표 헤더와 반드시 같아야 합니다.
  # markdownlint MD060(compact 스타일) 때문에 '| --- |' 형태를 씁니다.
  awk -v row="$row" '
    /^\|( --- \|)+$/  { print; intable=1; next }
    intable && /^\|/  { print; next }
    intable           { print row; print; intable=0; next }
    { print }
    END { if (intable) print row }
  ' "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"

  ok "리소스 기록: $type $id"
}

# ------------------------------------------------------------
cmd_run() {
  [[ "${1:-}" == "--" ]] && shift
  [[ $# -gt 0 ]] || die "실행할 명령이 없습니다.  runlog.sh run -- <cmd>"

  local file; file="$(current_log)"
  local out; out="$(mktemp)"
  local start end rc

  head1 "실행"
  info "$*"

  start="$(now_epoch)"
  set +e
  "$@" 2>&1 | tee "$out"
  rc="${PIPESTATUS[0]}"
  set -e
  end="$(now_epoch)"

  # 이 블록이 만드는 마크다운은 커밋되므로 markdownlint 를 통과해야 합니다.
  # 지켜야 하는 것:
  #   - 펜스에 언어 태그 (MD040)
  #   - 빈 줄 연속 금지 (MD012)
  #   - 줄 끝 공백 금지 (MD009)
  {
    printf -- '<details>\n'
    if [[ $rc -eq 0 ]]; then
      printf -- '<summary><code>%s</code> - OK (%ss)</summary>\n\n' "$*" "$((end - start))"
    else
      # 실패는 접지 않고 펼쳐 둡니다. 나중에 다시 볼 때 찾는 건 대부분 이쪽입니다.
      printf -- '<summary><b>%s - 실패 (exit=%s, %ss)</b></summary>\n\n' "$*" "$rc" "$((end - start))"
    fi
    printf -- '```text\n'
    # 출력이 길면 앞뒤만 남깁니다. 전체를 넣으면 기록이 읽을 수 없게 됩니다.
    if [[ $(wc -l <"$out") -gt 120 ]]; then
      head -50 "$out"
      printf -- '... (중략 %s줄) ...\n' "$(( $(wc -l <"$out") - 100 ))"
      tail -50 "$out"
    else
      cat "$out"
    fi
    printf -- '```\n\n</details>\n'
  } | append_block "$file"

  rm -f "$out"

  if [[ $rc -eq 0 ]]; then ok "기록함 (exit=0)"; else bad "기록함 (exit=$rc)"; fi
  return "$rc"
}

# ------------------------------------------------------------
cmd_done() {
  local file; file="$(current_log)"
  local status="${1:-ok}"
  local started_file="${file}.started"
  local elapsed="" hours="" cost="" rate gpus

  rate="$(profile_hourly_cost "${PROFILE:-minimal}")"
  gpus="$(gpu_node_count)"
  if [[ "$gpus" =~ ^[0-9]+$ ]] && (( gpus > 0 )); then
    rate=$(awk -v r="$rate" -v g="$gpus" -v c="$GPU_HOURLY_COST" 'BEGIN { printf "%.2f", r + g*c }')
  fi

  if [[ -f "$started_file" ]]; then
    elapsed=$(( $(now_epoch) - $(cat "$started_file") ))
    hours=$(awk -v s="$elapsed" 'BEGIN { printf "%.2f", s/3600 }')
    cost=$(awk -v h="$hours" -v r="$rate" 'BEGIN { printf "%.2f", h*r }')
    rm -f "$started_file"
  fi

  {
    printf -- '## 마무리\n\n'
    printf -- '- **종료**: %s\n' "$(now_local)"
    printf -- '- **결과**: %s\n' "$status"
    if [[ -n "$elapsed" ]]; then
      printf -- '- **소요**: %s초 (%s시간)\n' "$elapsed" "$hours"
      if [[ "$gpus" =~ ^[0-9]+$ ]] && (( gpus > 0 )); then
        printf -- '- **추정 비용**: 약 $%s (시간당 $%s = %s 프로파일 + GPU %s대)\n' \
          "$cost" "$rate" "${PROFILE:-?}" "$gpus"
      else
        printf -- '- **추정 비용**: 약 $%s (시간당 $%s, %s 프로파일)\n' \
          "$cost" "$rate" "${PROFILE:-?}"
      fi
    fi
    # '- ' 로 끝내면 줄 끝 공백이 되어 MD009 에 걸립니다. 공백 없는 빈 항목으로 둡니다.
    printf -- '\n### 다음에 다르게 할 것\n\n-\n'
  } | append_block "$file"

  rm -f "$POINTER"

  head1 "기록 종료"
  ok "$file"
  [[ -n "$elapsed" ]] && info "소요 ${hours}시간, 추정 \$${cost}"

  # 클러스터가 아직 살아 있으면 과금이 계속됩니다. 여기서 한 번 더 말해 줍니다.
  if [[ -f "$CLUSTER_DIR/metadata.json" ]]; then
    printf "\n"
    warn "클러스터가 아직 살아 있습니다. 시간당 \$${rate} 가 계속 나갑니다"
    warn "실습이 끝났다면:  ./scripts/destroy-cluster.sh"
  fi

  printf "\n"
  info "'다음에 다르게 할 것' 을 채워 두세요. 2회차에 그것만 읽게 됩니다."
  info "그리고 커밋하세요:  git add docs/runlog && git commit -m 'runlog: ${status}'"
}

# ------------------------------------------------------------
cmd_list() {
  head1 "지난 기록"
  local found=0
  for f in "$LOGDIR"/*.md; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "TEMPLATE.md" ]] && continue
    found=1
    local result
    result=$(grep -m1 '^\- \*\*결과\*\*:' "$f" 2>/dev/null | sed 's/.*: //' || true)
    printf "  %-44s %s\n" "$(basename "$f")" "${result:-진행 중}"
  done
  [[ $found -eq 1 ]] || info "아직 없습니다."

  if [[ -f "$POINTER" ]]; then
    printf "\n"
    ok "열려 있는 기록: $(cat "$POINTER")"
  fi
}

# ------------------------------------------------------------
case "${1:-}" in
  new)  shift; cmd_new "$@" ;;
  note) shift; cmd_note "$@" ;;
  res)  shift; cmd_res "$@" ;;
  run)  shift; cmd_run "$@" ;;
  done) shift; cmd_done "$@" ;;
  path) current_log; printf '\n' ;;
  show) less "$(current_log)" ;;
  list) cmd_list ;;
  *)
    cat <<'USAGE'
사용법:
  runlog.sh new <phase> [제목]        기록 시작 (docs/runlog/<날짜>-<phase>.md)
  runlog.sh note "<내용>"             한 줄 기록
  runlog.sh res <종류> <ID> [설명]     만들어진 AWS 리소스 기록
  runlog.sh run -- <명령>             명령을 실행하고 출력까지 기록
  runlog.sh done [ok|fail|partial]    기록 종료 (소요시간, 추정 비용 계산)
  runlog.sh path | show | list

단계 이름은 스크립트 이름과 맞추세요:
  00-preflight  01-install  02-agent-stack  03-gpu
  04-rhoai  05-model  06-verify  09-destroy
USAGE
    exit 1
    ;;
esac
