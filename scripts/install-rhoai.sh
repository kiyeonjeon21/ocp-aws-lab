#!/usr/bin/env bash
# Red Hat OpenShift AI 와 GPU 스택을 설치합니다.
#
#   ./scripts/install-rhoai.sh gpu      NFD + NVIDIA GPU Operator (GPU 노드 붙인 뒤)
#   ./scripts/install-rhoai.sh rhoai    RHOAI 오퍼레이터 + DataScienceCluster
#   ./scripts/install-rhoai.sh status
#
# ------------------------------------------------------------------
# 왜 CR 을 레포에 박아두지 않는가
# ------------------------------------------------------------------
# DataScienceCluster / ClusterPolicy / NodeFeatureDiscovery 는 오퍼레이터
# 버전마다 필드가 바뀝니다. 문서를 보고 베껴 둔 YAML 은 반년이면 틀립니다.
# 그래서 설치된 CSV 의 alm-examples 에서 그 버전의 정답을 꺼내 쓰고,
# 우리가 실제로 다르게 하고 싶은 부분만 jq 로 덧칠합니다.
#
# 덧칠이 실패하면(필드가 사라졌으면) 조용히 넘어가지 않고 경고를 냅니다.
# 그게 "이 버전에서 뭔가 바뀌었다"는 신호이기 때문입니다.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need_cluster

ACTION="${1:-status}"

# ------------------------------------------------------------------
# 공통 헬퍼
# ------------------------------------------------------------------

# 카탈로그에서 패키지를 찾아 채널과 소스를 알아냅니다.
# 채널 이름을 하드코딩하면 다음 마이너 버전에서 깨집니다.
pkg_info() {
  local pkg="$1"
  oc get packagemanifest "$pkg" -n openshift-marketplace -o json 2>/dev/null \
  | jq -r '[.status.defaultChannel, .status.catalogSource, .status.catalogSourceNamespace] | @tsv'
}

# 네임스페이스 + OperatorGroup + Subscription.
#   subscribe <package> <namespace> <og-scope: all|own>
subscribe() {
  local pkg="$1" ns="$2" scope="${3:-all}"

  local info channel source source_ns
  info=$(pkg_info "$pkg") || true
  [[ -n "$info" ]] || die "카탈로그에서 $pkg 를 찾을 수 없습니다.
  OperatorHub 카탈로그가 준비되었는지 확인하세요:
    oc get catalogsource -n openshift-marketplace"
  IFS=$'\t' read -r channel source source_ns <<<"$info"
  ok "$pkg  channel=$channel  source=$source"

  oc get ns "$ns" >/dev/null 2>&1 || oc create ns "$ns" >/dev/null

  # OperatorGroup 이 이미 있으면 건드리지 않습니다.
  # 하나의 네임스페이스에 OperatorGroup 이 둘이면 그 안의 오퍼레이터가
  # 전부 멈추고, 이유는 CSV 상태에만 조용히 남습니다.
  if ! oc get operatorgroup -n "$ns" -o name 2>/dev/null | grep -q .; then
    if [[ "$scope" == own ]]; then
      oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${ns}-og
  namespace: ${ns}
spec:
  targetNamespaces:
    - ${ns}
EOF
    else
      oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${ns}-og
  namespace: ${ns}
spec: {}
EOF
    fi
    ok "OperatorGroup 생성 ($scope)"
  else
    info "OperatorGroup 이미 있음"
  fi

  oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${pkg}
  namespace: ${ns}
spec:
  channel: ${channel}
  name: ${pkg}
  source: ${source}
  sourceNamespace: ${source_ns}
  installPlanApproval: Automatic
EOF
  ok "Subscription 적용"
}

# CSV 가 Succeeded 가 될 때까지 기다립니다.
# 이 함수의 stdout 은 CSV 이름 하나뿐입니다.
# 진행 표시는 전부 stderr 로 보냅니다. 안 그러면 $(...) 로 잡을 때
# 점만 잔뜩 섞이거나, 반대로 대기 중 화면이 아무것도 안 나옵니다.
wait_csv() {
  local ns="$1" pkg="$2" timeout="${3:-600}" waited=0 csv phase
  printf "  CSV 대기 " >&2
  while (( waited < timeout )); do
    csv=$(oc get subscription "$pkg" -n "$ns" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [[ -n "$csv" ]]; then
      phase=$(oc get csv "$csv" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      if [[ "$phase" == Succeeded ]]; then
        printf "\n" >&2; ok "$csv  Succeeded" >&2
        echo "$csv"
        return 0
      fi
    fi
    printf "." >&2
    sleep 10
    waited=$((waited + 10))
  done
  printf "\n" >&2
  bad "CSV 가 ${timeout}초 안에 Succeeded 가 되지 않았습니다" >&2
  info "  oc get csv -n $ns" >&2
  info "  oc get installplan -n $ns" >&2
  return 1
}

# CSV 의 alm-examples 에서 특정 kind 의 예제를 꺼냅니다.
alm_example() {
  local ns="$1" csv="$2" kind="$3"
  oc get csv "$csv" -n "$ns" -o jsonpath='{.metadata.annotations.alm-examples}' 2>/dev/null \
  | jq -c --arg k "$kind" '.[] | select(.kind == $k)' | head -1
}

# jq 로 덧칠하되, 대상 경로가 없으면 경고를 냅니다.
# 조용한 no-op 이 제일 나쁩니다. 설정한 줄 알았는데 안 되어 있는 상태가 됩니다.
patch_or_warn() {
  local json="$1" check="$2" expr="$3" label="$4"
  if jq -e "$check" >/dev/null 2>&1 <<<"$json"; then
    jq -c "$expr" <<<"$json"
  else
    warn "이 버전에는 $label 경로가 없습니다. 건너뜁니다" >&2
    printf '%s' "$json"
  fi
}

case "$ACTION" in

# ==================================================================
gpu)
  head1 "1. Node Feature Discovery"
  # GPU 오퍼레이터는 "어느 노드에 NVIDIA 카드가 있는지"를 스스로 모릅니다.
  # NFD 가 PCI 벤더 ID(10de)를 보고 노드에 라벨을 붙여 주면 그때부터 움직입니다.
  # NFD 없이 GPU 오퍼레이터만 깔면 아무 일도 안 일어나고 에러도 안 납니다.
  subscribe nfd openshift-nfd own
  NFD_CSV=$(wait_csv openshift-nfd nfd 600)

  EX=$(alm_example openshift-nfd "$NFD_CSV" NodeFeatureDiscovery)
  if [[ -n "$EX" ]]; then
    jq -c '.metadata.namespace = "openshift-nfd"' <<<"$EX" | oc apply -f - >/dev/null
    ok "NodeFeatureDiscovery 적용 (CSV 예제 기준)"
  else
    warn "alm-examples 에 NodeFeatureDiscovery 가 없습니다. 콘솔에서 만드세요"
  fi

  head1 "2. NVIDIA GPU Operator"
  subscribe gpu-operator-certified nvidia-gpu-operator own
  GPU_CSV=$(wait_csv nvidia-gpu-operator gpu-operator-certified 900)

  EX=$(alm_example nvidia-gpu-operator "$GPU_CSV" ClusterPolicy)
  if [[ -n "$EX" ]]; then
    # 기본 예제는 대체로 그대로 쓰면 됩니다.
    # 드라이버 컨테이너가 RHCOS 커널에 맞는 모듈을 알아서 받아옵니다.
    # 그 "알아서 받아온다"가 인터넷 있는 클러스터의 특권이고,
    # 폐쇄망에서 GPU 가 별도 랩 규모가 되는 이유이기도 합니다.
    oc apply -f - >/dev/null <<<"$EX"
    ok "ClusterPolicy 적용"
  else
    warn "alm-examples 에 ClusterPolicy 가 없습니다"
  fi

  printf "\n"
  info "드라이버 빌드에 10~20분 걸립니다. 진행 상황:"
  info "  oc get pods -n nvidia-gpu-operator"
  info "  oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}'"
  printf "\n"
  info "완료되면 노드에 GPU 가 보입니다:"
  info "  oc get nodes -l node-role.kubernetes.io/gpu -o custom-columns=N:.metadata.name,GPU:.status.allocatable.nvidia\\\\.com/gpu"
  printf "\n"
  ;;

# ==================================================================
rhoai)
  head1 "0. 사전 확인"
  SC=$(default_storage_class)
  [[ -n "$SC" ]] || die "기본 StorageClass 가 없습니다. RHOAI 의 명시적 요구사항입니다."
  ok "기본 StorageClass  $SC"

  # RHOAI 는 워커 노드당 8 CPU / 32 GiB 를 기준선으로 요구합니다.
  MIN_CPU=$(oc get nodes -l node-role.kubernetes.io/worker \
              -o jsonpath='{range .items[*]}{.status.capacity.cpu}{"\n"}{end}' \
            | sort -n | head -1)
  if [[ "$MIN_CPU" =~ ^[0-9]+$ ]] && (( MIN_CPU < 8 )); then
    warn "가장 작은 워커가 ${MIN_CPU} vCPU 입니다. RHOAI 기준선은 8 입니다"
    warn "대시보드 파드가 Pending 으로 멈출 수 있습니다. ai 프로파일로 재설치를 권합니다"
  else
    ok "워커 최소 vCPU  ${MIN_CPU:-?}"
  fi

  head1 "1. RHOAI 오퍼레이터"
  subscribe rhods-operator redhat-ods-operator all
  CSV=$(wait_csv redhat-ods-operator rhods-operator 900)

  head1 "2. DSCInitialization"
  # 최근 버전은 오퍼레이터가 default-dsci 를 알아서 만듭니다.
  # 잠깐 기다려 보고 없으면 예제로 만듭니다.
  DSCI=""
  for _ in $(seq 1 12); do
    DSCI=$(oc get dscinitialization -o name 2>/dev/null | head -1)
    [[ -n "$DSCI" ]] && break
    sleep 10
  done
  if [[ -n "$DSCI" ]]; then
    ok "이미 있음: $DSCI"
  else
    EX=$(alm_example redhat-ods-operator "$CSV" DSCInitialization)
    [[ -n "$EX" ]] || die "alm-examples 에 DSCInitialization 이 없습니다"
    oc apply -f - >/dev/null <<<"$EX"
    ok "생성 (CSV 예제 기준)"
    DSCI=$(oc get dscinitialization -o name | head -1)
  fi

  # Service Mesh 를 끕니다.
  # KServe RawDeployment 모드는 메시가 필요 없고, 켜 두면 Istio 컨트롤 플레인이
  # 통째로 올라와 워커 2대짜리 랩에서는 자원의 상당 부분을 먹습니다.
  if oc get "$DSCI" -o json | jq -e '.spec.serviceMesh' >/dev/null 2>&1; then
    oc patch "$DSCI" --type merge \
      -p '{"spec":{"serviceMesh":{"managementState":"Removed"}}}' >/dev/null
    ok "serviceMesh -> Removed (RawDeployment 모드라 불필요)"
  else
    info "이 버전의 DSCInitialization 에는 serviceMesh 필드가 없습니다"
  fi

  head1 "3. DataScienceCluster"
  EX=$(alm_example redhat-ods-operator "$CSV" DataScienceCluster)
  [[ -n "$EX" ]] || die "alm-examples 에 DataScienceCluster 가 없습니다"

  DSC="$EX"
  # KServe 를 RawDeployment 로. Knative 의존을 없앱니다.
  DSC=$(patch_or_warn "$DSC" '.spec.components.kserve' \
        '.spec.components.kserve.managementState = "Managed"
         | .spec.components.kserve.defaultDeploymentMode = "RawDeployment"' \
        'components.kserve')
  DSC=$(patch_or_warn "$DSC" '.spec.components.kserve.serving' \
        '.spec.components.kserve.serving.managementState = "Removed"' \
        'components.kserve.serving')

  # 랩에서 안 쓰는 무거운 컴포넌트를 끕니다.
  # 워커 2대에 전부 켜면 자원이 남지 않습니다.
  # 나중에 하나씩 켜 보면서 무엇이 얼마를 먹는지 재 보는 것도 실습거리입니다.
  for c in codeflare ray kueue trainingoperator modelmeshserving; do
    DSC=$(jq -c --arg c "$c" '
      if .spec.components[$c] then .spec.components[$c].managementState = "Removed" else . end
    ' <<<"$DSC")
  done
  for c in dashboard workbenches datasciencepipelines; do
    DSC=$(jq -c --arg c "$c" '
      if .spec.components[$c] then .spec.components[$c].managementState = "Managed" else . end
    ' <<<"$DSC")
  done

  oc apply -f - >/dev/null <<<"$DSC"
  ok "DataScienceCluster 적용"
  info "켠 것: dashboard, workbenches, pipelines, kserve(RawDeployment)"
  info "끈 것: codeflare, ray, kueue, trainingoperator, modelmesh"

  head1 "4. 기동 대기"
  printf "  "
  for _ in $(seq 1 60); do
    P=$(oc get datasciencecluster -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    [[ "$P" == Ready ]] && { printf "\n"; ok "DataScienceCluster Ready"; break; }
    printf "."
    sleep 15
  done
  printf "\n"

  URL=$(oc get route rhods-dashboard -n redhat-ods-applications \
          -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [[ -n "$URL" ]]; then
    ok "대시보드  https://$URL"
  else
    info "대시보드 Route 가 아직 없습니다. 몇 분 뒤 다시 확인하세요:"
    info "  oc get route -n redhat-ods-applications"
  fi
  printf "\n"
  info "다음: ./scripts/deploy-model.sh"
  printf "\n"
  ;;

# ==================================================================
status)
  head1 "오퍼레이터"
  for ns in openshift-nfd nvidia-gpu-operator redhat-ods-operator; do
    if oc get ns "$ns" >/dev/null 2>&1; then
      oc get csv -n "$ns" \
        -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase \
        --no-headers 2>/dev/null | sed 's/^/  /'
    else
      info "$ns 없음"
    fi
  done

  head1 "DataScienceCluster"
  oc get datasciencecluster -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null \
    | sed 's/^/  /' || info "없음"

  head1 "GPU"
  oc get clusterpolicy -o custom-columns=NAME:.metadata.name,STATE:.status.state 2>/dev/null \
    | sed 's/^/  /' || info "ClusterPolicy 없음"
  oc get nodes -l node-role.kubernetes.io/gpu \
    -o custom-columns=NODE:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu 2>/dev/null \
    | sed 's/^/  /' || true
  printf "\n"
  ;;

*) die "사용법: $0 gpu | rhoai | status" ;;
esac
