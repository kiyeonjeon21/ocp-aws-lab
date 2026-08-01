#!/usr/bin/env bash
# destroy 후 잔여 리소스 스캔.
#
#   ./scripts/verify-clean.sh                  # metadata.json 에서 infraID 추론
#   ./scripts/verify-clean.sh lab1-abc12       # infraID 직접 지정
#
# openshift-install destroy 가 놓치는 건 주로 두 가지입니다.
#   1. 클러스터가 동적으로 만든 것 (Service type=LoadBalancer 의 ELB, PVC 의 EBS)
#   2. destroy 가 중간에 실패했을 때 남은 것
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env

INFRA_ID="${1:-}"
if [[ -z "$INFRA_ID" ]]; then
  INFRA_ID=$(cluster_infra_id 2>/dev/null || true)
fi

LEFT=0
found() { bad "$*"; LEFT=$((LEFT + 1)); }

printf "\n${C_BLU}잔여 리소스 스캔${C_RST}\n"
if [[ -n "$INFRA_ID" ]]; then
  info "infraID=$INFRA_ID  region=$REGION"
  TAGF="Name=tag-key,Values=kubernetes.io/cluster/$INFRA_ID"
else
  warn "infraID 를 모릅니다. Purpose=lab 태그와 이름 패턴으로만 검사합니다"
  info "region=$REGION"
  TAGF="Name=tag:Purpose,Values=lab"
fi

# ------------------------------------------------------------------ EC2
head1 "EC2 인스턴스"
R=$(aws ec2 describe-instances --region "$REGION" --filters "$TAGF" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' --output text 2>/dev/null)
[[ -n "$R" ]] && { found "인스턴스가 남아 있습니다"; sed 's/^/      /' <<<"$R"; } || ok "없음"

# ------------------------------------------------------------------ NAT Gateway
head1 "NAT Gateway (시간당 \$0.045)"
R=$(aws ec2 describe-nat-gateways --region "$REGION" \
      --filter "Name=state,Values=pending,available" \
      --query 'NatGateways[].[NatGatewayId,VpcId,State]' --output text 2>/dev/null)
if [[ -n "$INFRA_ID" && -n "$R" ]]; then R=$(grep -i "$INFRA_ID" <<<"$R" || true); fi
[[ -n "$R" ]] && { found "NAT Gateway 가 남아 있습니다"; sed 's/^/      /' <<<"$R"; } || ok "없음"

# ------------------------------------------------------------------ 로드밸런서
head1 "로드밸런서 (ALB/NLB + Classic)"
R=$(aws elbv2 describe-load-balancers --region "$REGION" \
      --query 'LoadBalancers[].[LoadBalancerName,Type,State.Code]' --output text 2>/dev/null)
[[ -n "$INFRA_ID" && -n "$R" ]] && R=$(grep -i "$INFRA_ID" <<<"$R" || true)
[[ -n "$R" ]] && { found "ELBv2 가 남아 있습니다"; sed 's/^/      /' <<<"$R"; } || ok "ELBv2 없음"

R=$(aws elb describe-load-balancers --region "$REGION" \
      --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null)
[[ -n "$INFRA_ID" && -n "$R" ]] && R=$(tr '\t' '\n' <<<"$R" | grep -i "$INFRA_ID" || true)
[[ -n "$R" ]] && { found "Classic ELB 가 남아 있습니다 (Service type=LoadBalancer 흔적)"; sed 's/^/      /' <<<"$R"; } || ok "Classic ELB 없음"

# ------------------------------------------------------------------ EBS
head1 "미사용 EBS 볼륨"
R=$(aws ec2 describe-volumes --region "$REGION" --filters "Name=status,Values=available" \
      --query 'Volumes[].[VolumeId,Size,Tags[?Key==`Name`].Value|[0]]' --output text 2>/dev/null)
[[ -n "$R" ]] && { found "available 상태 볼륨이 있습니다 (PVC 흔적일 수 있음)"; sed 's/^/      /' <<<"$R"; } || ok "없음"

# ------------------------------------------------------------------ EIP
head1 "미연결 Elastic IP (시간당 \$0.005)"
R=$(aws ec2 describe-addresses --region "$REGION" \
      --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output text 2>/dev/null)
[[ -n "$R" ]] && { found "연결되지 않은 EIP 가 있습니다"; sed 's/^/      /' <<<"$R"; } || ok "없음"

# ------------------------------------------------------------------ VPC / SG
head1 "VPC"
R=$(aws ec2 describe-vpcs --region "$REGION" --filters "$TAGF" \
      --query 'Vpcs[].[VpcId,CidrBlock]' --output text 2>/dev/null)
[[ -n "$R" ]] && { found "VPC 가 남아 있습니다"; sed 's/^/      /' <<<"$R"; } || ok "없음"

# ------------------------------------------------------------------ S3
# 설치 프로그램은 부트스트랩 ignition 을 담을 버킷을 만듭니다.
# 설치가 중간에 죽으면 이게 남습니다. 비용은 미미하지만 재설치를 방해합니다.
head1 "S3 버킷"
if [[ -n "$INFRA_ID" ]]; then
  R=$(aws s3api list-buckets --query "Buckets[?contains(Name,'$INFRA_ID')].Name" --output text 2>/dev/null)
  [[ -n "$R" ]] && { found "버킷이 남아 있습니다"; sed 's/^/      /' <<<"$R"; } || ok "없음"
else
  info "infraID 없이는 검사 생략"
fi

# ------------------------------------------------------------------ IAM
# 비 STS 설치에서는 오퍼레이터마다 IAM 유저를 만듭니다. 과금은 없지만
# 계정에 쓰레기가 쌓이고 나중에 뭐가 뭔지 알 수 없게 됩니다.
head1 "IAM (과금은 없지만 정리 대상)"
if [[ -n "$INFRA_ID" ]]; then
  R=$(aws iam list-roles --query "Roles[?contains(RoleName,'$INFRA_ID')].RoleName" --output text 2>/dev/null)
  [[ -n "$R" ]] && { found "IAM 롤이 남아 있습니다"; tr '\t' '\n' <<<"$R" | sed 's/^/      /'; } || ok "롤 없음"

  R=$(aws iam list-users --query "Users[?contains(UserName,'$INFRA_ID')].UserName" --output text 2>/dev/null)
  [[ -n "$R" ]] && { found "IAM 유저가 남아 있습니다"; tr '\t' '\n' <<<"$R" | sed 's/^/      /'; } || ok "유저 없음"

  R=$(aws iam list-instance-profiles --query "InstanceProfiles[?contains(InstanceProfileName,'$INFRA_ID')].InstanceProfileName" --output text 2>/dev/null)
  [[ -n "$R" ]] && { found "인스턴스 프로파일이 남아 있습니다"; tr '\t' '\n' <<<"$R" | sed 's/^/      /'; } || ok "인스턴스 프로파일 없음"
else
  info "infraID 없이는 검사 생략"
fi

# ------------------------------------------------------------------ Route 53
head1 "Route 53"
ZID=$(find_hosted_zone_id)
if [[ -n "$ZID" ]]; then
  R=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZID" \
        --query "ResourceRecordSets[?contains(Name,'$CLUSTER_NAME.')].[Name,Type]" --output text 2>/dev/null)
  [[ -n "$R" ]] && { found "퍼블릭 존에 클러스터 레코드가 남아 있습니다"; sed 's/^/      /' <<<"$R"; } || ok "퍼블릭 존 깨끗함"
else
  info "$BASE_DOMAIN 퍼블릭 존을 찾지 못했습니다"
fi

# 프라이빗 호스팅 존은 개당 월 \$0.50 입니다. destroy 가 놓치면 계속 과금됩니다.
R=$(aws route53 list-hosted-zones \
      --query "HostedZones[?Config.PrivateZone==\`true\` && contains(Name,'$CLUSTER_NAME.')].[Id,Name]" \
      --output text 2>/dev/null)
[[ -n "$R" ]] && { found "프라이빗 호스팅 존이 남아 있습니다 (월 \$0.50)"; sed 's/^/      /' <<<"$R"; } || ok "프라이빗 존 없음"

# ------------------------------------------------------------------ 결과
printf "\n"
if (( LEFT == 0 )); then
  printf "${C_GRN}잔여 리소스 없음. 과금이 멈췄습니다.${C_RST}\n\n"
else
  printf "${C_RED}잔여 리소스 %d종류.${C_RST} 위 항목을 콘솔에서 확인하고 수동 삭제하세요.\n" "$LEFT"
  printf "%s\n\n" "destroy 를 한 번 더 돌리면 해결되는 경우도 많습니다."
  exit 1
fi
