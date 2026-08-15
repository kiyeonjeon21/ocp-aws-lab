#!/usr/bin/env bash
# 설치 전 사전 점검. 여기서 걸리는 건 전부 설치 30분 뒤에 터질 것들입니다.
#
#   ./scripts/preflight.sh            # .env 의 PROFILE 사용
#   ./scripts/preflight.sh sno        # 프로파일 지정
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env

PROFILE="${1:-$PROFILE}"
FAILED=0
fail() { bad "$*"; FAILED=$((FAILED + 1)); }

printf "\n${C_BLU}OCP AWS Lab preflight${C_RST}\n"
info "profile=$PROFILE  cluster=$CLUSTER_NAME  region=$REGION  az=$AZ"
info "baseDomain=$BASE_DOMAIN  awsProfile=$AWS_PROFILE"

# ---------------------------------------------------------------- 1. 로컬 도구
head1 "로컬 도구"
for c in openshift-install oc aws jq dig envsubst ssh-keygen; do
  if command -v "$c" >/dev/null 2>&1; then
    ok "$c ($(command -v "$c"))"
  else
    fail "$c 가 없습니다"
  fi
done

if command -v openshift-install >/dev/null 2>&1; then
  IV=$(openshift-install version | head -1 | awk '{print $2}')
  OV=$(oc version --client -o json 2>/dev/null | jq -r '.releaseClientVersion // empty')
  ok "openshift-install $IV"
  if [[ -n "$OV" && "$OV" != "$IV" ]]; then
    warn "oc($OV) 와 openshift-install($IV) 버전이 다릅니다"
  fi
fi

# ---------------------------------------------------------------- 2. AWS 자격증명
head1 "AWS 자격증명"
if ! CALLER=$(aws sts get-caller-identity --output json 2>&1); then
  fail "aws sts get-caller-identity 실패: $CALLER"
  printf "\n${C_RED}자격증명이 없으면 나머지 점검이 무의미합니다.${C_RST}\n"
  exit 1
fi
ACCOUNT_ID=$(jq -r .Account <<<"$CALLER")
CALLER_ARN=$(jq -r .Arn <<<"$CALLER")
ok "$CALLER_ARN"
case "$CALLER_ARN" in
  *ocp-lab*) : ;;
  *) warn "이 실습 전용 자격증명이 아닌 것 같습니다. 다른 프로젝트 리소스를 건드릴 위험이 있습니다" ;;
esac

# ---------------------------------------------------------------- 3. 리전 / AZ
head1 "리전과 AZ"
if aws ec2 describe-availability-zones --region "$REGION" \
     --query "AvailabilityZones[?ZoneName=='$AZ'].State" --output text 2>/dev/null | grep -q available; then
  ok "$AZ 사용 가능"
else
  fail "$AZ 를 $REGION 에서 찾을 수 없습니다"
fi

# ---------------------------------------------------------------- 4. vCPU 쿼터
head1 "vCPU 쿼터"
NEED=$(profile_peak_vcpu "$PROFILE")
QUOTA=$(aws service-quotas get-service-quota --service-code ec2 \
          --quota-code L-1216C47A --region "$REGION" \
          --query 'Quota.Value' --output text 2>/dev/null)

# 현재 실행 중인 인스턴스가 이미 쿼터를 먹고 있으면 그만큼 여유가 줄어듭니다.
USED=0
TYPES=$(aws ec2 describe-instances --region "$REGION" \
          --filters Name=instance-state-name,Values=running,pending \
          --query 'Reservations[].Instances[].InstanceType' --output text 2>/dev/null)
if [[ -n "$TYPES" ]]; then
  for t in $(tr '\t' '\n' <<<"$TYPES" | sort | uniq -c | awk '{print $2":"$1}'); do
    ity=${t%%:*}; cnt=${t##*:}
    v=$(aws ec2 describe-instance-types --region "$REGION" --instance-types "$ity" \
          --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text 2>/dev/null)
    [[ "$v" =~ ^[0-9]+$ ]] && USED=$((USED + v * cnt))
  done
fi

if [[ "$QUOTA" =~ ^[0-9.]+$ ]]; then
  QI=${QUOTA%.*}
  AVAIL=$((QI - USED))
  if (( AVAIL >= NEED )); then
    ok "쿼터 $QI, 사용 중 $USED, 여유 $AVAIL >= 필요 $NEED"
  else
    fail "여유 vCPU $AVAIL < 필요 $NEED (쿼터 $QI, 사용 중 $USED)"
    info "상향 요청: Service Quotas 콘솔에서 L-1216C47A"
  fi
else
  warn "vCPU 쿼터를 조회하지 못했습니다"
fi

# ---------------------------------------------------------------- 5. EIP 쿼터
head1 "Elastic IP 쿼터"
EIP_Q=$(aws service-quotas get-service-quota --service-code ec2 \
          --quota-code L-0263D0A3 --region "$REGION" --query 'Quota.Value' --output text 2>/dev/null)
EIP_U=$(aws ec2 describe-addresses --region "$REGION" \
          --query 'length(Addresses)' --output text 2>/dev/null || echo 0)
NAT_NEED=1; [[ "$PROFILE" == "default" ]] && NAT_NEED=3
if [[ "$EIP_Q" =~ ^[0-9.]+$ ]]; then
  if (( ${EIP_Q%.*} - EIP_U >= NAT_NEED )); then
    ok "쿼터 ${EIP_Q%.*}, 사용 중 $EIP_U, 필요 $NAT_NEED (NAT Gateway)"
  else
    fail "EIP 여유 부족: 쿼터 ${EIP_Q%.*}, 사용 중 $EIP_U, 필요 $NAT_NEED"
  fi
fi

# ---------------------------------------------------------------- 6. 인스턴스 타입 재고
head1 "인스턴스 타입 가용성 ($AZ)"
case "$PROFILE" in
  minimal) ITYPES="m6i.xlarge m6i.large" ;;
  compact) ITYPES="m6i.2xlarge" ;;
  sno)     ITYPES="m6i.2xlarge" ;;
  default) ITYPES="m6i.xlarge" ;;
  ai)      ITYPES="m6i.xlarge m6i.2xlarge" ;;
esac
for t in $ITYPES; do
  if [[ "$PROFILE" == "default" ]]; then
    ok "$t (default 프로파일은 AZ 고정 안 함, 확인 생략)"
    continue
  fi
  if aws ec2 describe-instance-type-offerings --region "$REGION" \
       --location-type availability-zone \
       --filters "Name=instance-type,Values=$t" "Name=location,Values=$AZ" \
       --query 'InstanceTypeOfferings[0].InstanceType' --output text 2>/dev/null | grep -q "$t"; then
    ok "$t 가 $AZ 에서 제공됨"
  else
    fail "$t 가 $AZ 에서 제공되지 않습니다. .env 의 AZ 를 바꾸세요"
  fi
done

# ---------------------------------------------------------------- 6b. GPU (ai 프로파일)
# GPU 노드는 설치 후에 붙이지만, 쿼터와 AZ 재고는 지금 확인해야 합니다.
# 실습 당일에 "이 AZ 에는 g6 가 없다"를 알게 되면 클러스터를 다시 깔아야 합니다.
# 단일 AZ 로 설치하기 때문에 나중에 AZ 만 바꿀 수가 없습니다.
if [[ "$PROFILE" == "ai" ]]; then
  head1 "GPU 노드 (설치 후 붙임)"

  if aws ec2 describe-instance-type-offerings --region "$REGION" \
       --location-type availability-zone \
       --filters "Name=instance-type,Values=$GPU_INSTANCE_TYPE" "Name=location,Values=$AZ" \
       --query 'InstanceTypeOfferings[0].InstanceType' --output text 2>/dev/null \
     | grep -q "$GPU_INSTANCE_TYPE"; then
    ok "$GPU_INSTANCE_TYPE 가 $AZ 에서 제공됨"
  else
    fail "$GPU_INSTANCE_TYPE 가 $AZ 에 없습니다"
    OK_AZ=$(aws ec2 describe-instance-type-offerings --region "$REGION" \
              --location-type availability-zone \
              --filters "Name=instance-type,Values=$GPU_INSTANCE_TYPE" \
              --query 'InstanceTypeOfferings[].Location' --output text 2>/dev/null | tr '\t' ' ')
    info "가능한 AZ: ${OK_AZ:-없음}"
    info ".env 의 AZ 를 바꾸세요. 설치 후에는 못 바꿉니다"
  fi

  # G/VT 는 일반 인스턴스와 완전히 별개 쿼터입니다.
  # 신규 계정은 0 인 경우가 있고 상향 승인에 하루 이상 걸립니다.
  GQ=$(aws service-quotas get-service-quota --service-code ec2 \
         --quota-code L-DB2E81BA --region "$REGION" --query 'Quota.Value' --output text 2>/dev/null)
  GV=$(aws ec2 describe-instance-types --region "$REGION" --instance-types "$GPU_INSTANCE_TYPE" \
         --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text 2>/dev/null)
  if [[ "$GQ" =~ ^[0-9.]+$ && "$GV" =~ ^[0-9]+$ ]]; then
    if (( ${GQ%.*} >= GV )); then
      ok "G/VT vCPU 쿼터 ${GQ%.*} (>= $GPU_INSTANCE_TYPE 의 $GV)"
    else
      fail "G/VT vCPU 쿼터 ${GQ%.*} < 필요 $GV. L-DB2E81BA 상향 신청이 필요합니다"
    fi
  else
    warn "G/VT 쿼터를 조회하지 못했습니다"
  fi
fi

# ---------------------------------------------------------------- 7. Route 53 위임
head1 "DNS"
ZID=$(find_hosted_zone_id)
if [[ -z "$ZID" ]]; then
  fail "$BASE_DOMAIN 퍼블릭 호스팅 존이 없습니다. 설치가 시작되지 않습니다"
else
  ok "호스팅 존 $ZID"

  ZONE_NS=$(aws route53 get-hosted-zone --id "$ZID" \
              --query 'DelegationSet.NameServers' --output text 2>/dev/null | tr '\t' '\n' | sort)
  # 부모 존에서 실제로 위임됐는지 퍼블릭 리졸버로 확인합니다.
  # 이게 안 되면 설치는 'waiting for bootstrap to complete' 에서 멈춥니다.
  LIVE_NS=$(dig +short NS "$BASE_DOMAIN" @1.1.1.1 2>/dev/null | sed 's/\.$//' | sort)
  if [[ -z "$LIVE_NS" ]]; then
    fail "$BASE_DOMAIN 의 NS 가 공개 DNS에서 조회되지 않습니다 (위임 미완료 또는 전파 대기)"
  elif [[ "$(tr -d ' ' <<<"$ZONE_NS")" == "$(tr -d ' ' <<<"$LIVE_NS")" ]]; then
    ok "NS 위임 정상 (Route 53 네임서버와 일치)"
  else
    fail "NS 불일치. registrar 쪽 NS 레코드를 확인하세요"
    info "Route 53: $(tr '\n' ' ' <<<"$ZONE_NS")"
    info "실제 응답: $(tr '\n' ' ' <<<"$LIVE_NS")"
  fi

  # 같은 이름의 클러스터가 이미 DNS에 살아있으면 설치가 충돌합니다.
  if dig +short "api.$CLUSTER_NAME.$BASE_DOMAIN" @1.1.1.1 2>/dev/null | grep -q .; then
    fail "api.$CLUSTER_NAME.$BASE_DOMAIN 이 이미 존재합니다. 이전 클러스터가 남아있는지 확인하세요"
  else
    ok "api.$CLUSTER_NAME.$BASE_DOMAIN 미사용"
  fi
fi

# ---------------------------------------------------------------- 8. pull secret
head1 "Red Hat pull secret"
if [[ ! -f "$PULL_SECRET_PATH" ]]; then
  fail "$PULL_SECRET_PATH 가 없습니다"
  info "console.redhat.com/openshift/install/aws/installer-provisioned 에서 받으세요"
elif ! jq -e . "$PULL_SECRET_PATH" >/dev/null 2>&1; then
  fail "$PULL_SECRET_PATH 가 올바른 JSON 이 아닙니다"
else
  N=$(jq -r '.auths | keys | length' "$PULL_SECRET_PATH" 2>/dev/null || echo 0)
  if (( N >= 1 )) && jq -e '.auths["cloud.openshift.com"]' "$PULL_SECRET_PATH" >/dev/null 2>&1; then
    ok "pull secret 유효 (레지스트리 ${N}개)"
  else
    fail "pull secret 에 cloud.openshift.com 항목이 없습니다. 잘못된 파일일 수 있습니다"
  fi
fi

# ---------------------------------------------------------------- 9. SSH 키
head1 "SSH 키"
if [[ -f "$SSH_KEY_PATH.pub" ]]; then
  ok "$SSH_KEY_PATH.pub"
else
  warn "$SSH_KEY_PATH.pub 가 없어 새로 만듭니다"
  mkdir -p "$(dirname "$SSH_KEY_PATH")"
  ssh-keygen -t ed25519 -N '' -f "$SSH_KEY_PATH" -C "ocp-aws-lab" >/dev/null \
    && ok "생성 완료: $SSH_KEY_PATH" || fail "SSH 키 생성 실패"
fi

# ---------------------------------------------------------------- 10. 기존 클러스터
head1 "기존 클러스터 디렉토리"
if [[ -d "$CLUSTER_DIR" ]]; then
  if [[ -f "$CLUSTER_DIR/metadata.json" ]]; then
    fail "$CLUSTER_DIR 에 metadata.json 이 있습니다. 살아있는 클러스터일 수 있습니다"
    info "infraID: $(cluster_infra_id)"
    info "먼저 ./scripts/destroy-cluster.sh 를 실행하세요"
  else
    warn "$CLUSTER_DIR 가 이미 있습니다 (metadata.json 없음). 렌더링 시 덮어씁니다"
  fi
else
  ok "충돌 없음"
fi

# ---------------------------------------------------------------- 11. 예산 알림
head1 "비용 안전장치"
BN=$(aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
       --query 'length(Budgets)' --output text 2>/dev/null || echo 0)
if [[ "$BN" =~ ^[0-9]+$ ]] && (( BN > 0 )); then
  ok "예산 ${BN}개 설정됨"
else
  warn "AWS Budgets 알림이 없습니다. ./scripts/setup-budget.sh 로 만드세요"
fi
warn "Budgets 는 청구 데이터가 8~24시간 지연됩니다. 시간당 과금의 방어선이 아닙니다"
warn "가장 확실한 안전장치는 실습 직후 destroy-cluster.sh 를 돌리는 습관입니다"

# ---------------------------------------------------------------- 결과
printf "\n"
if (( FAILED == 0 )); then
  printf "${C_GRN}preflight 통과.${C_RST} 다음: ./scripts/render-config.sh %s\n\n" "$PROFILE"
else
  printf "${C_RED}preflight 실패 %d건.${C_RST} 위 FAIL 을 해결하고 다시 실행하세요.\n\n" "$FAILED"
  exit 1
fi
