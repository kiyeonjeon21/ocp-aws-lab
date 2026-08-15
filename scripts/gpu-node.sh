#!/usr/bin/env bash
# GPU 워커를 붙였다 뗍니다.
#
#   ./scripts/gpu-node.sh up [개수]    기본 1
#   ./scripts/gpu-node.sh down         0 으로 축소 (MachineSet 은 남김)
#   ./scripts/gpu-node.sh delete       MachineSet 삭제
#   ./scripts/gpu-node.sh status
#
# ------------------------------------------------------------------
# 왜 install-config 가 아니라 Day-2 인가
# ------------------------------------------------------------------
# GPU 노드를 설치 시점부터 달면 설치 40분 내내 시간당 $0.80 이 나갑니다.
# 그리고 GPU 는 실습 중에도 실제로 모델을 서빙할 때만 필요합니다.
# 붙였다 떼는 게 맞고, 그 조작이 곧 Machine API 실습이기도 합니다.
#
# down 은 MachineSet 을 남기고 replicas 만 0 으로 만듭니다.
# EC2 인스턴스와 EBS 가 사라지므로 과금은 멈춥니다.
# 다시 쓸 때 up 한 번이면 됩니다.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need_cluster

ACTION="${1:-status}"
COUNT="${2:-1}"
MAPI_NS=openshift-machine-api

INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
GPU_MS="${INFRA_ID}-gpu-${AZ}"

gpu_ms_exists() { oc get machineset "$GPU_MS" -n "$MAPI_NS" >/dev/null 2>&1; }

show_status() {
  head1 "GPU 노드"
  if gpu_ms_exists; then
    oc get machineset "$GPU_MS" -n "$MAPI_NS" \
      -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,CURRENT:.status.replicas,READY:.status.readyReplicas
  else
    info "MachineSet 없음 ($GPU_MS)"
  fi
  printf "\n"
  N=$(oc get nodes -l node-role.kubernetes.io/gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if (( N > 0 )); then
    oc get nodes -l node-role.kubernetes.io/gpu \
      -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,GPU:.status.allocatable.nvidia\\.com/gpu
    printf "\n"
    info "GPU 가 <none> 이면 NVIDIA GPU Operator 가 아직 드라이버를 못 올린 것입니다"
    info "  oc get pods -n nvidia-gpu-operator"
  else
    info "GPU 노드 없음"
  fi
  printf "\n"
}

case "$ACTION" in
# ------------------------------------------------------------------
up)
  head1 "사전 확인"

  # 해당 AZ 에 그 타입이 없으면 Machine 이 Provisioning 에서 멈춥니다.
  # 노드가 안 붙는 이유가 조용해서 찾기 어려운 자리입니다.
  if aws ec2 describe-instance-type-offerings --region "$REGION" \
       --location-type availability-zone \
       --filters "Name=instance-type,Values=$GPU_INSTANCE_TYPE" "Name=location,Values=$AZ" \
       --query 'InstanceTypeOfferings[0].InstanceType' --output text 2>/dev/null \
     | grep -q "$GPU_INSTANCE_TYPE"; then
    ok "$GPU_INSTANCE_TYPE 가 $AZ 에서 제공됨"
  else
    die "$GPU_INSTANCE_TYPE 가 $AZ 에 없습니다.
  ap-northeast-2 는 2b 에 g6 가 없습니다. .env 의 AZ 를 2a/2c/2d 로 바꾸세요.
  다른 AZ 로 바꾸려면 클러스터를 재설치해야 합니다. 단일 AZ 로 깔았기 때문입니다."
  fi

  # G/VT 는 일반 인스턴스와 쿼터가 별개입니다.
  # 신규 계정은 이게 0 인 경우가 있고, 상향에 하루 이상 걸립니다.
  VCPU=$(aws ec2 describe-instance-types --region "$REGION" \
           --instance-types "$GPU_INSTANCE_TYPE" \
           --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text 2>/dev/null)
  QUOTA=$(aws service-quotas get-service-quota --service-code ec2 \
            --quota-code L-DB2E81BA --region "$REGION" \
            --query 'Quota.Value' --output text 2>/dev/null)
  if [[ "$QUOTA" =~ ^[0-9.]+$ && "$VCPU" =~ ^[0-9]+$ ]]; then
    NEED=$((VCPU * COUNT))
    if (( ${QUOTA%.*} >= NEED )); then
      ok "G/VT vCPU 쿼터 ${QUOTA%.*} >= 필요 $NEED"
    else
      die "G/VT vCPU 쿼터 부족: ${QUOTA%.*} < $NEED
  Service Quotas 콘솔에서 L-DB2E81BA 상향을 신청하세요. 승인에 하루 이상 걸립니다."
    fi
  else
    warn "G/VT 쿼터를 조회하지 못했습니다"
  fi

  if gpu_ms_exists; then
    head1 "기존 MachineSet 확장"
    oc scale machineset "$GPU_MS" -n "$MAPI_NS" --replicas="$COUNT"
    ok "$GPU_MS -> replicas=$COUNT"
  else
    head1 "MachineSet 생성"

    # 살아 있는 워커 MachineSet 을 복제합니다.
    # AMI ID, 서브넷, 보안그룹, IAM 프로파일, 태그를 손으로 쓰면 반드시 틀립니다.
    # 특히 AMI 는 RHCOS 버전과 리전에 묶여 있어서 문서에서 베껴 올 수 없습니다.
    SRC=$(oc get machineset -n "$MAPI_NS" -o name | head -1)
    [[ -n "$SRC" ]] || die "복제할 워커 MachineSet 이 없습니다"
    info "원본: $SRC"

    oc get "$SRC" -n "$MAPI_NS" -o json \
    | jq --arg name "$GPU_MS" \
         --arg itype "$GPU_INSTANCE_TYPE" \
         --argjson size "$GPU_VOLUME_SIZE" \
         --argjson replicas "$COUNT" '
        # 서버가 채운 필드를 전부 털어냅니다. 남기면 apply 가 거부됩니다.
        del(.status, .metadata.uid, .metadata.resourceVersion,
            .metadata.creationTimestamp, .metadata.generation,
            .metadata.selfLink, .metadata.managedFields,
            .metadata.annotations)
        | .metadata.name = $name
        | .spec.replicas = $replicas
        # MachineSet 이름은 세 군데에 들어갑니다. 하나라도 빠지면
        # 새 MachineSet 이 원본의 머신을 자기 것으로 인식합니다.
        | .spec.selector.matchLabels["machine.openshift.io/cluster-api-machineset"] = $name
        | .spec.template.metadata.labels["machine.openshift.io/cluster-api-machineset"] = $name
        | .spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-role"] = "gpu"
        | .spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-type"] = "gpu"
        | .spec.template.spec.providerSpec.value.instanceType = $itype
        | .spec.template.spec.providerSpec.value.blockDevices[0].ebs.volumeSize = $size
        # 노드에 붙는 라벨. InferenceService 의 nodeSelector 와 짝입니다.
        | .spec.template.spec.metadata.labels = (
            (.spec.template.spec.metadata.labels // {})
            + {"node-role.kubernetes.io/gpu": ""}
          )
        # taint 를 붙여 일반 워크로드가 비싼 노드로 흘러가지 않게 합니다.
        # NVIDIA GPU Operator 는 자기 파드에 toleration 을 넣고 오므로 영향받지 않습니다.
        | .spec.template.spec.taints = [
            {"key":"nvidia.com/gpu","value":"true","effect":"NoSchedule"}
          ]
      ' \
    | oc apply -f -

    ok "$GPU_MS 생성 (replicas=$COUNT, $GPU_INSTANCE_TYPE)"
  fi

  printf "\n"
  info "노드가 Ready 가 되기까지 5~10분 걸립니다."
  info "  watch oc get machine -n $MAPI_NS -l machine.openshift.io/cluster-api-machineset=$GPU_MS"
  printf "\n"
  info "다음: ./scripts/install-rhoai.sh gpu    (NFD + NVIDIA GPU Operator)"
  printf "\n"
  ;;

# ------------------------------------------------------------------
down)
  gpu_ms_exists || die "$GPU_MS 가 없습니다"
  head1 "GPU 노드 축소"
  oc scale machineset "$GPU_MS" -n "$MAPI_NS" --replicas=0
  ok "replicas=0. EC2 와 EBS 가 사라지면 과금이 멈춥니다"
  info "MachineSet 은 남습니다. 다시 쓰려면 ./scripts/gpu-node.sh up"
  printf "\n"
  info "실제로 사라졌는지 확인:"
  info "  oc get machine -n $MAPI_NS | grep gpu"
  printf "\n"
  ;;

# ------------------------------------------------------------------
delete)
  gpu_ms_exists || die "$GPU_MS 가 없습니다"
  oc delete machineset "$GPU_MS" -n "$MAPI_NS"
  ok "삭제됨. 머신이 정리될 때까지 몇 분 걸립니다"
  ;;

# ------------------------------------------------------------------
status) show_status ;;
*) die "사용법: $0 up [개수] | down | delete | status" ;;
esac
