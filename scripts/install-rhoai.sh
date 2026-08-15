#!/usr/bin/env bash
# Red Hat OpenShift AI 와 GPU 스택을 설치합니다.
#
#   ./scripts/install-rhoai.sh gpu          NFD + NVIDIA GPU Operator (GPU 노드 붙인 뒤)
#   ./scripts/install-rhoai.sh rhoai        RHOAI 오퍼레이터 + DataScienceCluster
#   ./scripts/install-rhoai.sh distributed  ray + kueue + trainingoperator 켜기
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
  # 이 랩은 서빙만 합니다. 학습/분산 관련은 전부 끕니다.
  #
  # 3.x 에서 이름이 늘었습니다. 2.x 목록만 갖고 있으면 새 컴포넌트가
  # Managed 로 남아 DSC 가 Ready 가 되지 않습니다.
  # 실제로 trainer 가 그랬습니다.
  #   TrainerReady = False  JobSet operator not installed
  # JobSet 오퍼레이터를 따로 깔아야 하는데, 분산 학습을 안 하면 필요 없습니다.
  #
  # 목록에 없는 이름은 jq 가 조용히 건너뛰므로 2.x 에 대고 돌려도 안전합니다.
  for c in codeflare ray kueue trainingoperator modelmeshserving \
           trainer sparkoperator llamastackoperator modelsasservice; do
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
# 분산 학습/스케줄링 컴포넌트를 켭니다.
#
# rhoai 액션은 이것들을 일부러 Removed 로 둡니다. 서빙만 할 거면 자원 낭비라서입니다.
# 튜닝이나 Ray 를 실제로 해 볼 때만 이 액션으로 켭니다.
#
# ------------------------------------------------------------------
# GPU 앞에 두는 이유
# ------------------------------------------------------------------
# 여기서 하는 일에 GPU 는 한 장도 필요 없습니다.
# 오퍼레이터 설치와 컨트롤러 기동이 전부입니다.
# GPU 를 먼저 올려두면 이 시간이 그대로 시간당 $0.83 으로 계산됩니다.
# RHOAI 를 GPU 앞에 둔 것과 같은 이유입니다.
#
# ------------------------------------------------------------------
# 컴포넌트마다 외부 의존이 다릅니다
# ------------------------------------------------------------------
# 실측(RHOAI 3.4.3, OCP 4.22.6):
#   ray               번들. 추가 오퍼레이터 없음
#   trainingoperator  번들. PyTorchJob 을 제공합니다
#   kueue             Red Hat 빌드 kueue-operator 를 따로 깔아야 합니다
#   trainer           JobSet 오퍼레이터가 필요한데 이 카탈로그에 없습니다
#
# 그래서 trainer 는 여기서 켜지 않습니다.
# 켜면 DSC 가 TrainerReady=False 로 멈추고 클러스터 전체가 Not Ready 가 됩니다.
# 튜닝은 trainingoperator 의 PyTorchJob 으로 합니다.
distributed)
  head1 "1. 전제 오퍼레이터"

  # cert-manager 가 먼저입니다.
  #
  # Kueue 오퍼레이터가 웹훅 인증서를 cert-manager 로 발급받습니다.
  # 없으면 Kueue CR 이 이렇게 멈춥니다.
  #   DependenciesAvailable=False
  #   cert-manager is required but not installed
  #
  # llm-d(LLMInferenceService)도 같은 것을 요구합니다. DSC 상태에 이렇게 남습니다.
  #   KserveLLMInferenceServiceDependencies=False
  #   Red Hat Connectivity Link and cert-manager operator not installed
  # 공통 전제라 여기서 한 번 깔아 둡니다.
  if oc get csv -A 2>/dev/null | grep -q cert-manager; then
    ok "cert-manager 이미 설치됨"
  else
    subscribe openshift-cert-manager-operator cert-manager-operator all
    wait_csv cert-manager-operator openshift-cert-manager-operator 600 >/dev/null
    ok "cert-manager 설치"
  fi

  # kueue 는 DSC 만 켜서는 안 됩니다. 오퍼레이터가 먼저 있어야 합니다.
  # 권장 네임스페이스는 패키지가 알려 줍니다. 하드코딩하지 않습니다.
  KUEUE_NS=$(oc get packagemanifest kueue-operator -n openshift-marketplace -o jsonpath\
='{.status.channels[0].currentCSVDesc.annotations.operatorframework\.io/suggested-namespace}' 2>/dev/null)
  KUEUE_NS="${KUEUE_NS:-openshift-kueue-operator}"

  if oc get csv -n "$KUEUE_NS" 2>/dev/null | grep -q kueue; then
    ok "kueue-operator 이미 설치됨 ($KUEUE_NS)"
  else
    # all(전체 네임스페이스) 이어야 합니다.
    # kueue-operator 는 OwnNamespace 설치 모드를 지원하지 않습니다.
    # own 으로 만들면 CSV 가 Failed 로 떨어지고 사유는 CSV 안에만 남습니다.
    #   UnsupportedOperatorGroup: OwnNamespace InstallModeType not supported
    # Subscription 은 정상으로 보여서 오해하기 쉽습니다. 실제로 한 번 겪었습니다.
    subscribe kueue-operator "$KUEUE_NS" all
    wait_csv "$KUEUE_NS" kueue-operator 600 >/dev/null
    ok "kueue-operator 설치 ($KUEUE_NS)"
  fi

  # Kueue CR 은 우리가 만들지 않습니다.
  # kueue 컴포넌트를 Unmanaged 로 켜면 DataScienceCluster 가
  # default-kueue 라는 Kueue CR 을 스스로 만듭니다(ownerReference 가 DSC 입니다).
  # 우리가 alm-examples 로 하나 더 만들면 CR 이 둘이 됩니다.

  head1 "2. DataScienceCluster 컴포넌트"

  DSC_NAME=$(oc get datasciencecluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) \
    || die "DataScienceCluster 가 없습니다. 먼저: $0 rhoai"
  [[ -n "$DSC_NAME" ]] || die "DataScienceCluster 가 없습니다. 먼저: $0 rhoai"

  # oc apply 로 통째로 덮지 않고 컴포넌트별 merge patch 를 씁니다.
  #
  # apply 는 last-applied-configuration 과 3-way 병합을 합니다.
  # rhoai 액션이 예전에 넣어 둔 kserve.defaultDeploymentMode 가 이 버전에서
  # rawDeploymentServiceConfig 로 바뀌었는데, apply 는 그걸 null 로 지우려 듭니다.
  # 내가 건드리지도 않은 필드가 같이 날아가는 겁니다.
  #
  # 컴포넌트를 하나씩 patch 하면 실패한 것만 실패하고 나머지는 반영됩니다.
  # 어느 컴포넌트가 거부됐는지도 그 자리에서 드러납니다.
  #
  # ------------------------------------------------------------------
  # kueue 만 Managed 가 아닙니다
  # ------------------------------------------------------------------
  # webhook 이 이렇게 거부합니다.
  #   Managed is no longer supported as a managementState
  # CRD 스키마는 Managed 를 허용하는데 webhook 이 막습니다.
  # 스키마만 보고 판단하면 못 찾습니다.
  #
  # Kueue 는 Red Hat 빌드 오퍼레이터가 따로 관리합니다.
  # RHOAI 는 그 위에 연동만 얹으므로 Unmanaged 가 맞는 값입니다.
  # 다른 컴포넌트(ray, trainingoperator)는 그대로 Managed 입니다.
  patch_component() {
    local c="$1" state="$2" out
    out=$(oc patch datasciencecluster "$DSC_NAME" --type=merge \
          -p "{\"spec\":{\"components\":{\"$c\":{\"managementState\":\"$state\"}}}}" 2>&1)
    if grep -q patched <<<"$out"; then
      ok "$c -> $state"
    else
      bad "$c -> $state 실패"
      sed 's/^/      /' <<<"$(tr '\n' ' ' <<<"$out" | sed 's/.*denied the request: //' | cut -c1-160)"
    fi
  }

  patch_component ray Managed
  patch_component trainingoperator Managed
  patch_component kueue Unmanaged

  # trainer 는 켜지 않습니다. JobSet 오퍼레이터가 이 카탈로그에 없습니다.
  # 켜면 TrainerReady=False 로 DSC 전체가 Not Ready 가 됩니다.
  ok "trainer 는 건너뜁니다 (JobSet 오퍼레이터 없음)"

  head1 "3. 컴포넌트별 준비 상태"
  info "컨트롤러 기동에 3~5분 걸립니다."

  # Kueue 는 기동 순서 경합이 있습니다.
  #
  # DSC 가 Kueue CR 을 만드는 시점에 kueue-webhook-service 가 아직 없으면
  # ClusterQueue 생성이 변환 웹훅에서 실패합니다.
  #   conversion webhook for kueue.x-k8s.io/v1beta1, Kind=ClusterQueue failed:
  #   service "kueue-webhook-service" not found
  # ClusterQueue 는 v1beta2 가 storage 라 v1beta1 요청은 변환을 거칩니다.
  #
  # 문제는 서비스가 생긴 뒤에도 스스로 다시 시도하지 않는다는 점입니다.
  # Error 로 굳어 있으면 어노테이션을 건드려 재조정을 유도합니다.
  kueue_nudge_if_stuck() {
    local msg
    msg=$(oc get kueue -o json 2>/dev/null \
          | jq -r '.items[0].status.conditions[]?|select(.type=="Ready" and .status!="True")|.message' 2>/dev/null)
    if grep -q "webhook" <<<"${msg:-}"; then
      local name
      name=$(oc get kueue -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
      [[ -n "$name" ]] || return 0
      oc annotate kueue "$name" "lab.retry=$(date +%s)" --overwrite >/dev/null 2>&1
      info "Kueue 가 웹훅 경합으로 멈춰 있어 재조정을 유도했습니다"
    fi
  }

  # DSC 전체 phase 만 보면 어느 컴포넌트가 걸렸는지 알 수 없습니다.
  # 컴포넌트별 조건을 따로 봅니다.
  for i in $(seq 1 40); do
    READY=$(oc get datasciencecluster -o json 2>/dev/null \
      | jq -r '[.items[0].status.conditions[]
                | select(.type|test("^(Ray|Kueue|TrainingOperator)Ready$"))
                | select(.status=="True")] | length')
    [[ "$READY" == "3" ]] && break
    # 웹훅이 준비될 시간을 준 뒤부터 경합을 확인합니다.
    (( i > 6 )) && (( i % 4 == 0 )) && kueue_nudge_if_stuck
    printf "."
    sleep 15
  done
  printf "\n"

  oc get datasciencecluster -o json 2>/dev/null \
    | jq -r '.items[0].status.conditions[]
             | select(.type|test("^(Ray|Kueue|TrainingOperator|Trainer)Ready$"))
             | "  \(.type)=\(.status)  \(.message // "")"'

  head1 "4. 쓸 수 있게 된 것"
  for crd in rayclusters.ray.io rayjobs.ray.io pytorchjobs.kubeflow.org \
             clusterqueues.kueue.x-k8s.io localqueues.kueue.x-k8s.io; do
    if oc get crd "$crd" >/dev/null 2>&1; then
      ok "$crd"
    else
      warn "$crd 없음"
    fi
  done
  printf "\n"
  info "다음: PyTorchJob 으로 LoRA 튜닝. GPU 가 필요합니다:"
  info "  ./scripts/gpu-node.sh up 1"
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

*) die "사용법: $0 gpu | rhoai | distributed | status" ;;
esac
