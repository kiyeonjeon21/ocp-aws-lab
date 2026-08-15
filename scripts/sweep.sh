#!/usr/bin/env bash
# 리전에 남아 있는 과금 리소스를 전부 훑습니다.
#
#   ./scripts/sweep.sh              # .env 의 REGION
#   ./scripts/sweep.sh us-west-2    # 리전 지정
#   ./scripts/sweep.sh --all        # 모든 리전 (느립니다. 2~3분)
#
# ------------------------------------------------------------------
# verify-clean.sh 와 무엇이 다른가
# ------------------------------------------------------------------
# verify-clean.sh 는 "이 클러스터가 깨끗이 지워졌나"를 봅니다. infraID 가 기준입니다.
# 이 스크립트는 "이 계정 이 리전에 돈 나가는 게 뭐가 남아 있나"를 봅니다. 기준이 없습니다.
#
# 반복 실습에서 진짜 위험한 건 이 차이에서 나옵니다.
#   - 설치가 중간에 깨져서 metadata.json 이 안 생긴 세대
#   - clusters/ 를 지워버려서 infraID 를 잃은 세대
#   - 손으로 만들었다가 잊은 것
# 이 셋은 infraID 를 몰라서 verify-clean.sh 로는 안 잡힙니다.
#
# 그래서 여기서는 아무 태그도 믿지 않고 리소스 종류별로 전부 나열한 뒤,
# 클러스터 태그가 있으면 그걸로 세대를 묶어 보여줍니다.
#
# 읽기 전용입니다. 지우지 않습니다.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env

MODE="${1:-}"
REGIONS="$REGION"
if [[ "$MODE" == "--all" ]]; then
  REGIONS=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>/dev/null)
  warn "모든 리전을 훑습니다. 2~3분 걸립니다."
elif [[ -n "$MODE" ]]; then
  REGIONS="$MODE"
fi

TOTAL_HOURLY=0
FOUND=0

add_cost() {
  TOTAL_HOURLY=$(awk -v a="$TOTAL_HOURLY" -v b="$1" 'BEGIN { printf "%.4f", a + b }')
}
hit() { FOUND=$((FOUND + 1)); }

# 인스턴스 타입별 시간당 단가.
# 전부 넣을 수는 없으니 이 랩이 쓰는 것만 둡니다.
# 모르는 타입은 0 으로 잡고 별표를 붙여 눈에 띄게 합니다.
instance_cost() {
  case "$1" in
    m6i.large)   echo 0.096 ;;
    m6i.xlarge)  echo 0.192 ;;
    m6i.2xlarge) echo 0.384 ;;
    g6.xlarge)   echo 0.8048 ;;
    g6.2xlarge)  echo 0.9776 ;;
    g5.xlarge)   echo 1.006 ;;
    *)           echo 0 ;;
  esac
}

for r in $REGIONS; do
  HEADER_SHOWN=0
  section() {
    if (( HEADER_SHOWN == 0 )); then
      printf "\n${C_BLU}== %s${C_RST}\n" "$r"
      HEADER_SHOWN=1
    fi
  }

  # ---------------------------------------------------------------- EC2
  # stopped 도 봅니다. 인스턴스는 안 나가도 EBS 는 계속 나갑니다.
  INST=$(aws ec2 describe-instances --region "$r" \
    --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`]|[0].Value]' \
    --output text 2>/dev/null)
  if [[ -n "$INST" ]]; then
    section; hit
    printf "  ${C_RED}EC2 인스턴스${C_RST}\n"
    while IFS=$'\t' read -r id type state name; do
      [[ -z "$id" ]] && continue
      c=$(instance_cost "$type")
      mark=""
      if [[ "$state" == "running" || "$state" == "pending" ]]; then
        add_cost "$c"
        [[ "$c" == "0" ]] && mark=" ${C_YEL}(단가 미등록)${C_RST}"
      else
        c=0; mark=" ${C_DIM}(정지. EBS 만 과금)${C_RST}"
      fi
      printf "    %-21s %-13s %-9s \$%-7s %s%s\n" "$id" "$type" "$state" "$c" "${name:--}" "$mark"
    done <<<"$INST"
  fi

  # ---------------------------------------------------------------- NAT
  NAT=$(aws ec2 describe-nat-gateways --region "$r" \
    --filter Name=state,Values=pending,available \
    --query 'NatGateways[].[NatGatewayId,VpcId]' --output text 2>/dev/null)
  if [[ -n "$NAT" ]]; then
    section; hit
    printf "  ${C_RED}NAT Gateway${C_RST}  (개당 \$0.045/h + 데이터 \$0.045/GB)\n"
    while IFS=$'\t' read -r id vpc; do
      [[ -z "$id" ]] && continue
      add_cost 0.045
      printf "    %-24s %s\n" "$id" "$vpc"
    done <<<"$NAT"
  fi

  # ---------------------------------------------------------------- 로드밸런서
  LB=$(aws elbv2 describe-load-balancers --region "$r" \
    --query 'LoadBalancers[].[LoadBalancerName,Type,Scheme]' --output text 2>/dev/null)
  if [[ -n "$LB" ]]; then
    section; hit
    printf "  ${C_RED}NLB / ALB${C_RST}  (개당 \$0.0225/h)\n"
    while IFS=$'\t' read -r n t s; do
      [[ -z "$n" ]] && continue
      add_cost 0.0225
      printf "    %-38s %-9s %s\n" "$n" "$t" "$s"
    done <<<"$LB"
  fi

  CLB=$(aws elb describe-load-balancers --region "$r" \
    --query 'LoadBalancerDescriptions[].[LoadBalancerName,Scheme]' --output text 2>/dev/null)
  if [[ -n "$CLB" ]]; then
    section; hit
    printf "  ${C_RED}Classic ELB${C_RST}  (개당 \$0.025/h. Ingress Operator 가 만든 것)\n"
    while IFS=$'\t' read -r n s; do
      [[ -z "$n" ]] && continue
      add_cost 0.025
      printf "    %-38s %s\n" "$n" "$s"
    done <<<"$CLB"
  fi

  # ---------------------------------------------------------------- EBS
  # 붙어 있는 볼륨도 과금됩니다. 인스턴스를 stop 해도 이건 계속 나갑니다.
  # 총량을 합계에 넣지 않으면 실제 시간당 요금을 과소평가하게 됩니다.
  INUSE=$(aws ec2 describe-volumes --region "$r" \
    --filters Name=status,Values=in-use \
    --query 'sum(Volumes[].Size)' --output text 2>/dev/null)
  if [[ "$INUSE" =~ ^[0-9]+$ ]] && (( INUSE > 0 )); then
    section
    C=$(awk -v s="$INUSE" 'BEGIN { printf "%.4f", s*0.08/730 }')
    add_cost "$C"
    printf "  ${C_DIM}사용 중 EBS${C_RST}  %sGB  \$%s/h  ${C_DIM}(인스턴스에 붙어 있음. stop 해도 계속 과금)${C_RST}\n" "$INUSE" "$C"
  fi

  # available = 어느 인스턴스에도 안 붙은 볼륨.
  #
  # 여기서 "안 붙음"과 "잔여물"은 다릅니다.
  # PVC 가 살아 있어도 그 파드를 쓰는 노드가 없으면 볼륨은 분리된 채 남습니다.
  # gpu-node.sh down 을 하면 model-cache(모델 가중치 40GB)가 정확히 이 상태가 됩니다.
  # 다음에 GPU 를 올릴 때 다시 붙고, 14GB 재다운로드를 안 하는 것이 이 PVC 의 목적입니다.
  #
  # 이걸 전부 빨간 잔여물로 찍으면 오경보가 됩니다.
  # 매번 뜨는 경고는 읽히지 않게 되고, 그러면 진짜 잔여물도 같이 묻힙니다.
  # 그래서 PVC 태그를 같이 읽어 출처를 밝힙니다. 판단은 사람이 합니다.
  VOL=$(aws ec2 describe-volumes --region "$r" \
    --filters Name=status,Values=available \
    --query 'Volumes[].[VolumeId,Size,VolumeType,
             Tags[?Key==`kubernetes.io/created-for/pvc/namespace`]|[0].Value,
             Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' \
    --output text 2>/dev/null)
  if [[ -n "$VOL" ]]; then
    section; hit
    printf "  ${C_RED}붙어 있지 않은 EBS 볼륨${C_RST}  (분리 상태여도 용량만큼 과금됩니다)\n"
    while IFS=$'\t' read -r id size type pvcns pvcname; do
      [[ -z "$id" ]] && continue
      add_cost "$(awk -v s="$size" 'BEGIN { printf "%.4f", s*0.08/730 }')"
      if [[ "$pvcns" == "None" || -z "$pvcns" ]]; then
        printf "    %-24s %sGB %-6s ${C_RED}출처 불명. 잔여물일 가능성이 큽니다${C_RST}\n" \
               "$id" "$size" "$type"
      else
        printf "    %-24s %sGB %-6s PVC %s/%s\n" "$id" "$size" "$type" "$pvcns" "$pvcname"
      fi
    done <<<"$VOL"
    printf "    ${C_DIM}PVC 이름이 보이면 그 PVC 가 아직 있는지 확인하세요: oc get pvc -A${C_RST}\n"
    printf "    ${C_DIM}클러스터를 이미 지웠다면 PVC 이름이 있어도 잔여물입니다${C_RST}\n"
  fi

  # ---------------------------------------------------------------- EIP
  EIP=$(aws ec2 describe-addresses --region "$r" \
    --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output text 2>/dev/null)
  if [[ -n "$EIP" ]]; then
    section; hit
    printf "  ${C_RED}미할당 Elastic IP${C_RST}  (붙어 있지 않으면 과금됩니다. \$0.005/h)\n"
    while IFS=$'\t' read -r ip alloc; do
      [[ -z "$ip" ]] && continue
      add_cost 0.005
      printf "    %-18s %s\n" "$ip" "$alloc"
    done <<<"$EIP"
  fi

  # ---------------------------------------------------------------- 스냅샷
  SNAP=$(aws ec2 describe-snapshots --region "$r" --owner-ids self \
    --query 'Snapshots[].[SnapshotId,VolumeSize]' --output text 2>/dev/null)
  if [[ -n "$SNAP" ]]; then
    section; hit
    printf "  ${C_YEL}EBS 스냅샷${C_RST}  (\$0.05/GB-월)\n"
    printf "    %s개\n" "$(wc -l <<<"$SNAP" | tr -d ' ')"
  fi
done

# ------------------------------------------------------------------
# 리전과 무관한 것들
# ------------------------------------------------------------------
head1 "리전 무관"

# 프라이빗 호스팅 존은 클러스터마다 하나씩 생기고 destroy 가 자주 놓칩니다.
Z=$(aws route53 list-hosted-zones \
      --query "HostedZones[?Config.PrivateZone==\`true\`].[Id,Name]" --output text 2>/dev/null)
if [[ -n "$Z" ]]; then
  hit
  printf "  ${C_RED}프라이빗 호스팅 존${C_RST}  (개당 월 \$0.50. 생성 12시간 안에 지우면 무과금)\n"
  sed 's|/hostedzone/||' <<<"$Z" | sed 's/^/    /'
else
  ok "프라이빗 호스팅 존 없음"
fi

B=$(aws s3api list-buckets \
      --query "Buckets[?contains(Name,'openshift') || contains(Name,'image-registry')].Name" \
      --output text 2>/dev/null)
if [[ -n "$B" ]]; then
  hit
  printf "  ${C_YEL}S3 버킷${C_RST}  (용량만큼 과금)\n"
  tr '\t' '\n' <<<"$B" | sed 's/^/    /'
else
  ok "관련 S3 버킷 없음"
fi

# ------------------------------------------------------------------
printf "\n"
if (( FOUND == 0 )); then
  printf "${C_GRN}과금 리소스 없음. 깨끗합니다.${C_RST}\n\n"
  exit 0
fi

MONTHLY=$(awk -v h="$TOTAL_HOURLY" 'BEGIN { printf "%.0f", h*730 }')
DAILY=$(awk -v h="$TOTAL_HOURLY" 'BEGIN { printf "%.2f", h*24 }')
printf "${C_RED}현재 시간당 약 \$%s${C_RST}  (하루 \$%s · 한 달 \$%s)\n" "$TOTAL_HOURLY" "$DAILY" "$MONTHLY"
printf "%s\n" "  데이터 전송(\$0.045/GB)과 S3 용량은 여기 안 들어갑니다. 실제 청구액은 이보다 큽니다."
printf "\n"
info "살아 있는 클러스터라면 정상입니다. 실습이 끝났는데 이게 보이면:"
info "  ./scripts/destroy-cluster.sh          metadata.json 이 있을 때"
info "  ./scripts/verify-clean.sh <infraID>   infraID 만 알 때"
info "  docs/runlog/*.md 의 '만들어진 리소스' 표   둘 다 없을 때"
printf "\n"
