#!/usr/bin/env bash
# 모든 스크립트가 source 하는 공통 라이브러리.
# 여기서는 set -e 를 걸지 않습니다. 호출하는 쪽에서 겁니다.

# 이 파일이 어디 있는지 알아냅니다.
#
# bash 는 BASH_SOURCE, zsh 는 %x 로 "지금 읽고 있는 파일"을 알려줍니다.
# BASH_SOURCE 만 쓰면 zsh 에서 빈 문자열이 되고, REPO_ROOT 가 한 단계 위를
# 가리켜 .env 를 못 찾습니다. 그러면 AWS_PROFILE 이 안 잡히고,
# 그 상태로 aws 를 부르면 조용히 default 프로파일로 붙습니다.
# 이 레포가 막으려는 사고가 정확히 그것이라, 여기가 그 방어선의 시작입니다.
#
# 스크립트는 shebang 덕분에 항상 bash 로 돌지만,
# 사용자가 손으로 치는 'source scripts/env.sh' 는 로그인 셸(zsh)로 들어옵니다.
if [ -n "${ZSH_VERSION:-}" ]; then
  _lib_src="${(%):-%x}"
else
  _lib_src="${BASH_SOURCE[0]}"
fi
REPO_ROOT="$(cd "$(dirname "$_lib_src")/.." && pwd)"
unset _lib_src
export REPO_ROOT

# 레포에 받아둔 openshift-install / oc 를 시스템 PATH보다 우선합니다.
# 버전이 섞이면 디버깅이 지옥이 됩니다.
export PATH="$REPO_ROOT/bin:$PATH"

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_RST=$'\033[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_RST=
fi

ok()   { printf "  ${C_GRN}OK${C_RST}    %s\n" "$*"; }
warn() { printf "  ${C_YEL}WARN${C_RST}  %s\n" "$*"; }
bad()  { printf "  ${C_RED}FAIL${C_RST}  %s\n" "$*"; }
info() { printf "  ${C_DIM}%s${C_RST}\n" "$*"; }
head1() { printf "\n${C_BLU}== %s${C_RST}\n" "$*"; }
die()  { printf "\n${C_RED}error:${C_RST} %s\n" "$*" >&2; exit 1; }

# .env 를 읽어 환경변수로 export 합니다.
load_env() {
  local envfile="$REPO_ROOT/.env"
  [[ -f "$envfile" ]] || die ".env 가 없습니다. 'cp .env.example .env' 후 값을 채우세요."

  set -a
  # shellcheck disable=SC1090
  source "$envfile"
  set +a

  : "${AWS_PROFILE:?.env 에 AWS_PROFILE 이 없습니다}"
  : "${REGION:?.env 에 REGION 이 없습니다}"
  : "${BASE_DOMAIN:?.env 에 BASE_DOMAIN 이 없습니다}"
  : "${CLUSTER_NAME:?.env 에 CLUSTER_NAME 이 없습니다}"
  : "${OWNER:?.env 에 OWNER 가 없습니다}"
  : "${PROFILE:=minimal}"
  : "${AZ:=${REGION}a}"
  : "${SSH_KEY_PATH:=$HOME/.ssh/id_ocp_lab}"
  : "${PULL_SECRET_PATH:=secrets/pull-secret.json}"

  # ~ 를 실제 홈 경로로 펼칩니다.
  SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
  [[ "$PULL_SECRET_PATH" = /* ]] || PULL_SECRET_PATH="$REPO_ROOT/$PULL_SECRET_PATH"

  CLUSTER_DIR="$REPO_ROOT/clusters/$CLUSTER_NAME"
  export AWS_PROFILE REGION BASE_DOMAIN CLUSTER_NAME OWNER PROFILE AZ
  export SSH_KEY_PATH PULL_SECRET_PATH CLUSTER_DIR
  export AWS_PAGER=""

  load_ai_env
}

# ------------------------------------------------------------------
# agent 스택 / RHOAI 관련 기본값
# ------------------------------------------------------------------
# 전부 .env 없이도 동작하는 기본값을 갖습니다.
# 기존 .env 를 고치지 않아도 새 스크립트가 그대로 돌아야 하기 때문입니다.
#
# 이미지를 변수로 뺀 이유는 ocp-airgap-lab 과 매니페스트를 같은 모양으로
# 유지하기 위해서입니다. 그쪽은 같은 변수에 미러 레지스트리 경로를 넣습니다.
# 즉 두 레포의 manifests/**/*.yaml.tpl 은 내용이 같아야 정상입니다.
load_ai_env() {
  : "${AGENT_NAMESPACE:=agent-lab}"
  : "${RHOAI_NAMESPACE:=ai-serving}"

  # 오프라인 스위치 일괄 토글.
  # false = 인터넷 있는 클러스터의 기준선 (기본값)
  # true  = 폐쇄망과 같은 설정. 같은 클러스터에서 지연 차이를 재려고 씁니다.
  : "${AGENT_OFFLINE:=false}"

  # 빈 값이면 클러스터 기본 StorageClass 를 씁니다.
  # AWS IPI 는 gp3-csi 가 기본으로 붙어 있어서 보통 비워 두면 됩니다.
  : "${STORAGE_CLASS:=}"

  # 컨테이너 이미지. 폐쇄망 레포에서는 이 자리에 미러 경로가 들어갑니다.
  : "${IMAGE_LLAMA:=ghcr.io/ggml-org/llama.cpp:server}"
  : "${IMAGE_LITELLM:=ghcr.io/berriai/litellm:main-stable}"
  : "${IMAGE_QDRANT:=docker.io/qdrant/qdrant:v1.12.4}"
  : "${IMAGE_OPENWEBUI:=ghcr.io/open-webui/open-webui:main}"
  : "${IMAGE_PHOENIX:=docker.io/arizephoenix/phoenix:latest}"
  : "${IMAGE_UBI:=registry.access.redhat.com/ubi9/ubi-minimal:latest}"
  : "${IMAGE_PYTHON:=registry.access.redhat.com/ubi9/python-311:latest}"
  # 개발 도구 이미지. build-devimage.sh 로 만든 뒤 이 값을 내부 레지스트리 경로로 바꿉니다.
  # 기본값은 빌드 전에도 파드가 뜨도록 python 이미지를 그대로 씁니다(도구는 없음).
  : "${IMAGE_DEVTOOLS:=$IMAGE_PYTHON}"
  # RHOAI 3.4 는 번들 MinIO 를 걷어냈습니다. DSPA 의 minio.image 가 required 라 직접 줍니다.
  : "${IMAGE_MINIO:=quay.io/minio/minio:latest}"
  # 앱 앞에 OCP 로그인을 세우는 표준 사이드카.
  : "${IMAGE_OAUTH_PROXY:=registry.redhat.io/openshift4/ose-oauth-proxy-rhel9:latest}"

  # 모델 가중치.
  # 인터넷이 있는 클러스터라서 initContainer 가 런타임에 받아옵니다.
  # 폐쇄망에서는 이 한 줄이 불가능해서 modelcar 이미지를 따로 만듭니다.
  : "${MODEL_NAME:=qwen2.5-1.5b}"
  : "${MODEL_URL:=https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf}"

  # ------------------------------------------------------------
  # GPU 쪽은 다른 모델입니다. 일부러 그렇게 둡니다.
  # ------------------------------------------------------------
  # CPU 의 1.5B 로는 채팅은 되지만 코딩 에이전트가 안 됩니다.
  # 에이전트는 툴 호출을 반복하는 루프인데, 1.5B 는 호출 형식을 안정적으로
  # 지키지 못해서 몇 턴 못 가 깨집니다. "채팅은 되는데 에이전트는 안 되는" 경계가 여기입니다.
  #
  # Coder-7B 는 fp16 으로 약 15GB 라 L4 24GB 에 그대로 들어갑니다.
  # GPU 를 g6.xlarge 에서 더 키우지 않아도 됩니다.
  # 점(.)을 쓰면 안 됩니다.
  # 이 값이 InferenceService 의 이름이 되는데, KServe 는 DNS-1035 를 강제합니다.
  #   regex: [a-z]([-a-z0-9]*[a-z0-9])?
  # qwen2.5-coder-7b 로 뒀다가 admission webhook 에 거부당했습니다.
  # llama.cpp 쪽 MODEL_NAME 은 쿠버네티스 리소스 이름이 아니라서 점이 있어도 됩니다.
  : "${VLLM_MODEL_NAME:=qwen25-coder-7b}"
  : "${MODEL_HF_REPO:=Qwen/Qwen2.5-Coder-7B-Instruct}"
  # 7B fp16 이 24GB 의 대부분을 씁니다. 1.5B 때의 0.55 로는 KV 캐시가 안 잡힙니다.
  : "${VLLM_GPU_UTIL:=0.90}"
  # 코딩 에이전트는 파일 내용을 통째로 넣어서 컨텍스트가 금방 커집니다.
  # 32k 까지 지원하지만 24GB 에서는 KV 캐시가 빠듯해 16k 로 둡니다.
  : "${VLLM_MAX_LEN:=16384}"

  # GPU 노드. 설치 후 gpu-node.sh 로 붙였다 뗍니다.
  : "${GPU_INSTANCE_TYPE:=g6.xlarge}"
  : "${GPU_VOLUME_SIZE:=200}"

  # ----------------------------------------------------------------
  # 파인튜닝
  # ----------------------------------------------------------------
  # 서빙용 7B 를 그대로 쓰지 않습니다.
  #
  # L4 는 24GB 한 장이고, 이 랩에서는 서빙과 학습이 같은 카드를 놓고 다툽니다.
  # 7B 를 LoRA 로 돌리려면 4bit 양자화까지 끌고 와야 하고, 그러면 관찰하려던
  # "LoRA 가 무엇을 하는가" 대신 "메모리를 어떻게 욱여넣는가" 가 실습이 됩니다.
  #
  # 0.5B 면 fp16 으로 그냥 올라가고 몇 분이면 끝납니다.
  # 파이프라인이 도는 것을 먼저 보고, 모델 크기는 그다음 문제입니다.
  : "${TUNE_BASE_MODEL:=Qwen/Qwen2.5-0.5B-Instruct}"
  : "${TUNE_ADAPTER_NAME:=lab-style}"

  export AGENT_NAMESPACE RHOAI_NAMESPACE STORAGE_CLASS AGENT_OFFLINE
  export IMAGE_LLAMA IMAGE_LITELLM IMAGE_QDRANT IMAGE_OPENWEBUI IMAGE_PHOENIX
  export IMAGE_UBI IMAGE_PYTHON IMAGE_DEVTOOLS IMAGE_MINIO IMAGE_OAUTH_PROXY
  export MODEL_NAME MODEL_URL MODEL_HF_REPO
  export VLLM_MODEL_NAME VLLM_GPU_UTIL VLLM_MAX_LEN
  export GPU_INSTANCE_TYPE GPU_VOLUME_SIZE
  export TUNE_BASE_MODEL TUNE_ADAPTER_NAME
}

# ------------------------------------------------------------------
# 클러스터 접근
# ------------------------------------------------------------------
# oc 를 쓰는 스크립트는 전부 이걸 먼저 호출합니다.
# KUBECONFIG 를 안 잡고 oc 를 부르면 예전 컨텍스트나 다른 클러스터에
# 붙을 수 있고, 그건 조용히 잘못된 곳에 apply 하는 사고로 이어집니다.
need_cluster() {
  [[ -f "$CLUSTER_DIR/auth/kubeconfig" ]] \
    || die "kubeconfig 가 없습니다: $CLUSTER_DIR/auth/kubeconfig
  클러스터가 아직 없다면 ./scripts/create-cluster.sh 를 먼저 실행하세요."
  export KUBECONFIG="$CLUSTER_DIR/auth/kubeconfig"

  oc whoami >/dev/null 2>&1 \
    || die "클러스터에 접속할 수 없습니다. API 가 살아있는지 확인하세요:
  oc --kubeconfig=$KUBECONFIG get co"
}

# 기본 StorageClass 이름. 없으면 빈 문자열.
default_storage_class() {
  oc get sc -o json 2>/dev/null | jq -r '
    .items[]
    | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")
    | .metadata.name' | head -1
}

# 리소스가 뜰 때까지 기다립니다. oc wait 는 대상이 아직 없으면 즉시 실패해서
# apply 직후에 쓰기 어렵습니다. 그래서 존재 확인부터 합니다.
wait_for() {
  local kind="$1" name="$2" ns="$3" timeout="${4:-300}"
  local waited=0
  while (( waited < timeout )); do
    if oc get "$kind" "$name" -n "$ns" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

# 프로파일별 설치 피크 vCPU (부트스트랩 노드 4 vCPU 포함).
# 설치 중 잠깐이라도 이 수치를 넘으면 쿼터에 걸려 실패합니다.
profile_peak_vcpu() {
  case "$1" in
    minimal) echo 20 ;;   # 3x4 + 2x2 + 4
    compact) echo 28 ;;   # 3x8 + 0   + 4
    sno)     echo 12 ;;   # 1x8 + 0   + 4
    default) echo 28 ;;   # 3x4 + 3x4 + 4
    ai)      echo 32 ;;   # 3x4 + 2x8 + 4  (GPU 노드는 설치 후 별도)
    *) die "알 수 없는 프로파일: $1 (minimal|compact|sno|default|ai)" ;;
  esac
}

# 프로파일별 시간당 비용 (us-east-1 온디맨드, GPU 제외).
# README 의 비용 표와 같은 값이어야 합니다. 한쪽만 고치지 마세요.
# runlog.sh 가 실습 소요시간에 곱해서 추정치를 냅니다.
profile_hourly_cost() {
  case "${1:-$PROFILE}" in
    minimal) echo 0.95 ;;
    compact) echo 1.30 ;;
    sno)     echo 0.55 ;;
    default) echo 1.35 ;;
    ai)      echo 1.54 ;;
    *)       echo 1.00 ;;
  esac
}

# g6.xlarge + EBS 200GB. GPU 노드가 떠 있으면 위 금액에 이만큼이 더해집니다.
GPU_HOURLY_COST=0.83
export GPU_HOURLY_COST

# BASE_DOMAIN 에 해당하는 퍼블릭 호스팅 존 ID 를 찾습니다. 없으면 빈 문자열.
find_hosted_zone_id() {
  aws route53 list-hosted-zones-by-name --dns-name "${BASE_DOMAIN}." \
    --query "HostedZones[?Name=='${BASE_DOMAIN}.' && Config.PrivateZone==\`false\`].Id | [0]" \
    --output text 2>/dev/null | sed 's|/hostedzone/||;s|^None$||'
}

# clusters/<name>/metadata.json 에서 infraID 를 읽습니다.
cluster_infra_id() {
  [[ -f "$CLUSTER_DIR/metadata.json" ]] || return 1
  jq -r '.infraID' "$CLUSTER_DIR/metadata.json"
}
