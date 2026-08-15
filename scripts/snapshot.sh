#!/usr/bin/env bash
# 지금 클러스터의 상태를 마크다운으로 떠서 docs/snapshots/ 에 남깁니다.
#
#   ./scripts/snapshot.sh              # docs/snapshots/<날짜>-<infraID>.md
#   ./scripts/snapshot.sh -            # 파일 대신 표준출력
#
# ------------------------------------------------------------------
# 왜 스크립트인가
# ------------------------------------------------------------------
# 이 랩은 클러스터를 만들었다 지웠다 합니다.
# infraID, 인스턴스 ID, 로드밸런서 이름, 호스팅 존 ID 는 세대마다 전부 바뀝니다.
# 그래서 이런 값을 README 에 적으면 다음 세대에 전부 거짓말이 됩니다.
#
# 기록을 두 층으로 나눕니다.
#   세대 무관 (구조, 포트, 컴포넌트 구성)  -> README. 손으로 씁니다.
#   세대별   (ID, 엔드포인트, 버전)        -> 이 스크립트. 매번 다시 뜹니다.
#
# 파일 이름에 infraID 가 들어가므로 세대끼리 덮어쓰지 않습니다.
# 두 세대를 diff 하면 "지난번과 뭐가 달라졌나"가 바로 보입니다.
#
#   diff docs/snapshots/2026-08-16-lab1-cxfgs.md docs/snapshots/2026-08-20-lab1-abc12.md
#
# 시크릿은 담지 않습니다. kubeadmin 비밀번호와 토큰은 여기 안 나옵니다.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need_cluster

INFRA_ID=$(cluster_infra_id 2>/dev/null || echo unknown)
OUT="$REPO_ROOT/docs/snapshots/$(date +%Y-%m-%d)-${INFRA_ID}.md"
[[ "${1:-}" == "-" ]] && OUT=/dev/stdout || mkdir -p "$(dirname "$OUT")"

# oc/aws 가 없는 값을 물어보면 빈 줄이 나옵니다.
# 표가 깨지지 않게 없으면 - 로 채웁니다.
d() { local v; v=$(cat); [[ -n "${v// }" ]] && printf '%s' "$v" || printf -- '-'; }

{
printf '# 클러스터 스냅샷 %s\n\n' "$INFRA_ID"
printf '%s\n\n' "\`./scripts/snapshot.sh\` 가 만든 파일입니다. 손으로 고치지 마세요."
printf '%s\n' "이 값들은 **이 세대에만 유효합니다.** destroy 후 재설치하면 전부 바뀝니다."
printf '%s\n\n' "구조와 포트처럼 세대와 무관한 것은 [README](../../README.md) 에 있습니다."

printf '## 기본\n\n'
printf '| 항목 | 값 |\n| --- | --- |\n'
printf '| 뜬 시각 | %s |\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf '| infraID | `%s` |\n' "$INFRA_ID"
printf '| 클러스터 | %s.%s |\n' "$CLUSTER_NAME" "$BASE_DOMAIN"
printf '| 프로파일 | %s |\n' "${PROFILE:-?}"
printf '| 리전 / AZ | %s / %s |\n' "$REGION" "$AZ"
printf '| 레포 커밋 | `%s` |\n' "$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null | d)"

printf '\n## 버전\n\n'
printf '| 구성요소 | 버전 |\n| --- | --- |\n'
printf '| OpenShift | %s |\n' "$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null | d)"
printf '| Kubernetes | %s |\n' "$(oc version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty' | d)"
printf '| RHOAI | %s |\n' "$(oc get csv -n redhat-ods-operator -o jsonpath='{.items[?(@.spec.displayName)].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -m1 rhods | d)"
printf '| NVIDIA GPU Operator | %s |\n' "$(oc get csv -n nvidia-gpu-operator -o name 2>/dev/null | sed 's|.*/||' | grep -m1 gpu | d)"
printf '| 채팅 모델 | %s |\n' "$MODEL_NAME"
printf '| 서빙 모델 | %s (%s) |\n' "$VLLM_MODEL_NAME" "$MODEL_HF_REPO"

printf '\n## 노드\n\n'
printf '| 이름 | 역할 | 타입 | CPU | 메모리 | 상태 |\n| --- | --- | --- | --- | --- | --- |\n'
oc get nodes -o json 2>/dev/null | jq -r '
  .items[] |
  ( [.metadata.labels | to_entries[] | select(.key|startswith("node-role.kubernetes.io/")) | .key | sub("node-role.kubernetes.io/";"")] | join(",") ) as $roles |
  "| `\(.metadata.name)` | \($roles) | \(.metadata.labels["node.kubernetes.io/instance-type"] // "-") | \(.status.capacity.cpu) | \(.status.capacity.memory) | \([.status.conditions[]|select(.type=="Ready")|.status]|join("")) |"'

printf '\n## 과금 리소스\n\n'
printf '%s\n\n' "destroy 가 실패하면 이 목록이 손으로 지울 대상입니다."
printf '| 종류 | ID |\n| --- | --- |\n'
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag-key,Values=kubernetes.io/cluster/$INFRA_ID" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType]' --output text 2>/dev/null \
  | while read -r id t; do [[ -n "$id" ]] && printf '| ec2 (%s) | `%s` |\n' "$t" "$id"; done
aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=${INFRA_ID}-vpc" \
  --query 'Vpcs[].VpcId' --output text 2>/dev/null | tr '\t' '\n' \
  | while read -r v; do [[ -n "$v" ]] && printf '| vpc | `%s` |\n' "$v"; done
aws ec2 describe-nat-gateways --region "$REGION" --filter Name=state,Values=available \
  --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null | tr '\t' '\n' \
  | while read -r n; do [[ -n "$n" ]] && printf '| nat-gateway | `%s` |\n' "$n"; done
aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null | tr '\t' '\n' \
  | while read -r l; do [[ -n "$l" ]] && printf '| nlb | `%s` |\n' "$l"; done
aws elb describe-load-balancers --region "$REGION" \
  --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null | tr '\t' '\n' \
  | while read -r l; do [[ -n "$l" ]] && printf '| classic-elb | `%s` |\n' "$l"; done
aws route53 list-hosted-zones --query "HostedZones[?Config.PrivateZone==\`true\` && contains(Name,'$CLUSTER_NAME.')].Id" \
  --output text 2>/dev/null | tr '\t' '\n' | sed 's|/hostedzone/||' \
  | while read -r z; do [[ -n "$z" ]] && printf '| route53-private-zone | `%s` |\n' "$z"; done
aws s3api list-buckets --query "Buckets[?contains(Name,'$INFRA_ID')].Name" --output text 2>/dev/null | tr '\t' '\n' \
  | while read -r b; do [[ -n "$b" ]] && printf '| s3 | `%s` |\n' "$b"; done

printf '\n## 엔드포인트\n\n'
printf '| 이름 | URL |\n| --- | --- |\n'
printf '| API | `https://api.%s.%s:6443` |\n' "$CLUSTER_NAME" "$BASE_DOMAIN"
oc get route -A -o json 2>/dev/null | jq -r '
  .items[]
  | select(.metadata.namespace | test("^(openshift-console|agent-lab|redhat-ods-applications|ai-serving)$"))
  | "| \(.metadata.namespace)/\(.metadata.name) | `https://\(.spec.host)` |"' | sort

printf '\n## 워크로드\n\n'
for ns in agent-lab ai-serving; do
  oc get ns "$ns" >/dev/null 2>&1 || continue
  printf '### %s\n\n' "$ns"
  printf '| 파드 | 상태 | 노드 |\n| --- | --- | --- |\n'
  # Succeeded 는 뺍니다. oc run --rm 이 못 지운 임시 프로브 파드가 섞여서
  # 나중에 읽을 때 "이건 뭐지" 하게 됩니다. 스냅샷은 지금 돌고 있는 것만 담습니다.
  oc get pods -n "$ns" -o json 2>/dev/null | jq -r '
    .items[] | select(.status.phase != "Succeeded")
    | "| \(.metadata.name) | \(.status.phase) | \(.spec.nodeName // "-") |"' | sort
  printf '\n'
done

printf '## 비용\n\n'
# profile_hourly_cost 를 쓰면 안 됩니다.
# 그건 프로파일 정의값이라 MachineSet 을 손으로 늘린 걸 모릅니다.
# 실제로 워커를 2 -> 3 으로 늘린 뒤에도 2대 기준 금액이 나왔습니다.
# 스냅샷은 "지금 실제로 뜬 것" 을 적어야 하므로 노드에서 직접 셉니다.
GPUS=$(oc get nodes -l node-role.kubernetes.io/gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')
WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l | tr -d ' ')
RATE=$(oc get nodes -o json 2>/dev/null | jq -r '
  [ .items[].metadata.labels["node.kubernetes.io/instance-type"] ] | .[]' \
  | awk '
      /^m6i\.large$/   { s += 0.096 }
      /^m6i\.xlarge$/  { s += 0.192 }
      /^m6i\.2xlarge$/ { s += 0.384 }
      /^g6\.xlarge$/   { s += 0.8048 }
      /^g6\.2xlarge$/  { s += 0.9776 }
      /^g5\.xlarge$/   { s += 1.006 }
      END { printf "%.2f", s + 0.045 + 2*0.0225 + 0.025 }')
printf '| 항목 | 값 |\n| --- | --- |\n'
printf '| 워커 수 | %s |\n' "$WORKERS"
printf '| GPU 노드 | %s |\n' "$GPUS"
printf '| 시간당 (실측 노드 기준) | $%s |\n' "$RATE"
printf '\n%s\n' "EC2 + NAT + LB 만 더한 값입니다. EBS 와 데이터 전송은 빠져 있습니다."
printf '%s\n' "전체는 \`./scripts/sweep.sh\` 로 보세요."
printf '\n---\n\n%s\n' "이 세대를 지울 때: \`./scripts/destroy-cluster.sh && ./scripts/verify-clean.sh && ./scripts/sweep.sh\`"
} > "$OUT"

if [[ "$OUT" != /dev/stdout ]]; then
  head1 "스냅샷"
  ok "$OUT"
  info "세대별 파일입니다. 재설치하면 새 파일이 생기고 이건 그대로 남습니다."
  info "이전 세대와 비교: diff docs/snapshots/*.md"
fi
