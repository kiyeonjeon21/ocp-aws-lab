#!/usr/bin/env bash
# manifests/**/*.yaml.tpl -> clusters/<name>/manifests/**/*.yaml
#
#   ./scripts/render-manifests.sh                  # .env 기준
#   AGENT_OFFLINE=true ./scripts/render-manifests.sh
#
# clusters/ 는 gitignore 됩니다.
# 즉 렌더링 결과물이 아니라 manifests/ 아래 템플릿을 고쳐야 합니다.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
command -v envsubst >/dev/null || die "envsubst 가 없습니다 (brew install gettext)"

head1 "매니페스트 렌더링"

# ------------------------------------------------------------------
# StorageClass 결정
# ------------------------------------------------------------------
# 클러스터가 살아 있으면 실제 기본 SC 를 읽습니다.
# 없으면 AWS IPI 의 관례값으로 두고 경고만 남깁니다.
# 클러스터가 뜨기 전에도 렌더링은 되어야 하기 때문입니다.
if [[ -z "$STORAGE_CLASS" ]]; then
  if [[ -f "$CLUSTER_DIR/auth/kubeconfig" ]] \
     && KUBECONFIG="$CLUSTER_DIR/auth/kubeconfig" oc whoami >/dev/null 2>&1; then
    STORAGE_CLASS=$(KUBECONFIG="$CLUSTER_DIR/auth/kubeconfig" default_storage_class)
    [[ -n "$STORAGE_CLASS" ]] || die "클러스터에 기본 StorageClass 가 없습니다.
  RHOAI 는 동적 프로비저닝되는 기본 StorageClass 를 요구합니다.
  oc get sc 로 확인하고 .env 에 STORAGE_CLASS 를 지정하세요."
    ok "StorageClass  $STORAGE_CLASS (클러스터에서 조회)"
  else
    STORAGE_CLASS=gp3-csi
    warn "클러스터에 접속할 수 없어 StorageClass 를 gp3-csi 로 가정합니다"
  fi
else
  ok "StorageClass  $STORAGE_CLASS (.env 지정)"
fi
export STORAGE_CLASS

# ------------------------------------------------------------------
# 오프라인 스위치 파생
# ------------------------------------------------------------------
# AGENT_OFFLINE 하나로 앱 다섯 군데를 동시에 뒤집습니다.
# 폐쇄망 레포와 같은 템플릿을 쓰기 위한 장치이고,
# 동시에 이 랩의 측정 도구이기도 합니다.
if [[ "$AGENT_OFFLINE" == "true" ]]; then
  OFFLINE_MODE=true
  HF_OFFLINE=1
  VERSION_CHECK=false
  LITELLM_COST_MAP=True
  # 로컬 임베딩 모델을 못 받으므로 LiteLLM 을 거쳐 받습니다.
  RAG_EMBEDDING_ENGINE=openai
  info "모드: 폐쇄망 모사 (오프라인 스위치 ON)"
else
  OFFLINE_MODE=false
  HF_OFFLINE=0
  VERSION_CHECK=true
  LITELLM_COST_MAP=False
  # 빈 값 = Open WebUI 기본값(로컬 sentence-transformers).
  # 인터넷이 있으므로 HuggingFace 에서 임베딩 모델을 받아 그냥 됩니다.
  RAG_EMBEDDING_ENGINE=""
  info "모드: 기준선 (오프라인 스위치 OFF, 외부 호출 허용)"
fi

# 추론 백엔드. 기본은 agent 스택의 llama.cpp 입니다.
# RHOAI 의 vLLM 으로 바꾸는 건 switch-backend.sh 가 합니다.
: "${LLM_API_BASE:=http://llama-cpp:8080/v1}"
# vLLM 엔드포인트. RawDeployment 모드에서는 Service 이름이 <isvc>-predictor 입니다.
# 네임스페이스가 달라서 FQDN 으로 써야 합니다.
: "${VLLM_API_BASE:=http://${VLLM_MODEL_NAME}-predictor.${RHOAI_NAMESPACE}.svc.cluster.local:8080/v1}"

# InferenceService 용. deploy-model.sh 가 클러스터에서 실제 값을 채웁니다.
: "${SERVING_RUNTIME:=}"
MODEL_DIR="${MODEL_HF_REPO##*/}"

export OFFLINE_MODE HF_OFFLINE VERSION_CHECK LITELLM_COST_MAP RAG_EMBEDDING_ENGINE
export LLM_API_BASE VLLM_API_BASE SERVING_RUNTIME MODEL_DIR

# ------------------------------------------------------------------
# 렌더링
# ------------------------------------------------------------------
# 치환할 변수를 명시적으로 나열합니다.
# 목록을 비우면 스크립트 안의 $TARGET 같은 셸 변수까지 날려버립니다.
VARS='$AGENT_NAMESPACE $RHOAI_NAMESPACE $STORAGE_CLASS $CLUSTER_NAME $BASE_DOMAIN'
VARS+=' $IMAGE_LLAMA $IMAGE_LITELLM $IMAGE_QDRANT $IMAGE_OPENWEBUI $IMAGE_PHOENIX'
VARS+=' $IMAGE_UBI $IMAGE_PYTHON $IMAGE_DEVTOOLS $IMAGE_MINIO'
VARS+=' $MODEL_NAME $MODEL_URL $MODEL_HF_REPO $MODEL_DIR'
VARS+=' $VLLM_MODEL_NAME $VLLM_GPU_UTIL $VLLM_MAX_LEN $VLLM_API_BASE'
VARS+=' $OFFLINE_MODE $HF_OFFLINE $VERSION_CHECK $LITELLM_COST_MAP $RAG_EMBEDDING_ENGINE'
VARS+=' $LLM_API_BASE $SERVING_RUNTIME'

OUT_ROOT="$CLUSTER_DIR/manifests"
rm -rf "$OUT_ROOT"
count=0
rendered=()

while IFS= read -r tpl; do
  rel="${tpl#"$REPO_ROOT/manifests/"}"
  out="$OUT_ROOT/${rel%.tpl}"
  mkdir -p "$(dirname "$out")"
  envsubst "$VARS" < "$tpl" > "$out"

  # SERVING_RUNTIME 이 비면 'runtime:' 이 null 로 남습니다.
  # KServe 스키마는 문자열을 기대하므로 그 줄을 통째로 지워
  # 런타임 자동 선택에 맡깁니다.
  if [[ -z "$SERVING_RUNTIME" ]]; then
    sed -i '' '/^[[:space:]]*runtime:[[:space:]]*$/d' "$out" 2>/dev/null \
      || sed -i '/^[[:space:]]*runtime:[[:space:]]*$/d' "$out"
  fi

  rendered+=("$out")
  count=$((count + 1))
done < <(find "$REPO_ROOT/manifests" -name '*.yaml.tpl' | sort)

(( count > 0 )) || die "manifests/ 아래에 *.yaml.tpl 이 없습니다"

# ------------------------------------------------------------------
# 검증
# ------------------------------------------------------------------
for f in "${rendered[@]}"; do
  if grep -q '\${' "$f"; then
    bad "$(basename "$f") 에 치환되지 않은 변수가 남았습니다:"
    grep -n '\${' "$f" >&2
    die ".env 에 값이 빠졌거나 위 VARS 목록에 변수가 빠졌습니다."
  fi
  # YAML 은 탭을 허용하지 않습니다.
  # 편집기 설정 때문에 섞여 들어가면 apply 할 때야 발견됩니다.
  if grep -q "$(printf '^\t')" "$f"; then
    die "$(basename "$f") 에 탭 문자가 있습니다. YAML 은 탭을 허용하지 않습니다."
  fi
done

# 클러스터가 있으면 서버가 직접 검증하게 합니다.
# 로컬 파서보다 정확합니다. CRD 스키마까지 봅니다.
if [[ -f "$CLUSTER_DIR/auth/kubeconfig" ]] \
   && KUBECONFIG="$CLUSTER_DIR/auth/kubeconfig" oc whoami >/dev/null 2>&1; then
  export KUBECONFIG="$CLUSTER_DIR/auth/kubeconfig"
  for d in "$OUT_ROOT"/*/; do
    # 걸러야 하는 오류가 두 종류 있습니다. 둘 다 진짜 문제가 아닙니다.
    #
    # 1. namespaces "..." not found
    #    --dry-run=server 는 네임스페이스를 실제로 만들지 않습니다.
    #    그래서 같은 apply 안에서 그 네임스페이스에 들어갈 리소스가 전부 실패합니다.
    #    이걸 안 거르면 이 검사는 구조상 절대 통과하지 못하고,
    #    항상 뜨는 경고는 사람이 무시하게 되어 없는 것보다 나쁩니다.
    #
    # 2. no matches for kind "..."
    #    50-rhoai 는 오퍼레이터를 깔기 전에는 CRD 가 없습니다. 아직 순서가 아닌 것뿐입니다.
    #
    # 끝의 || true 가 필요합니다.
    # grep 은 걸러낼 게 없으면(= 오류가 전부 무해했으면) exit 1 을 냅니다.
    # set -e + pipefail 이라 그게 명령 치환 실패로 전파되어 스크립트가 죽습니다.
    # 검증이 통과할 때만 죽는, 제일 찾기 어려운 형태입니다.
    ERR=$(oc apply --dry-run=server -R -f "$d" 2>&1 >/dev/null \
          | grep -v 'namespaces ".*" not found' \
          | grep -v 'no matches for kind' \
          | grep -v 'ensure CRDs are installed' || true)
    if [[ -z "$ERR" ]]; then
      ok "서버 검증 통과  $(basename "$d")"
    else
      bad "서버 검증 실패  $(basename "$d")"
      sed 's/^/      /' <<<"$ERR" | head -5 >&2
      die "매니페스트를 고치세요. 렌더링 결과물이 아니라 manifests/ 아래 템플릿을 고쳐야 합니다."
    fi
  done
fi

head1 "완료"
ok "${count}개 -> $OUT_ROOT/"
info "AGENT_OFFLINE=$AGENT_OFFLINE  STORAGE_CLASS=$STORAGE_CLASS"
info "추론 백엔드    $LLM_API_BASE"
printf "\n다음: ./scripts/deploy-agent-stack.sh\n\n"
