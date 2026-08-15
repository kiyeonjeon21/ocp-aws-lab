#!/usr/bin/env bash
# 개발 환경 이미지를 클러스터 안에서 빌드합니다.
#
#   ./scripts/build-devimage.sh          # 빌드하고 로그를 따라감
#   ./scripts/build-devimage.sh --logs   # 진행 중인 빌드 로그만 보기
#
# ------------------------------------------------------------------
# 왜 클러스터 안에서 빌드하나
# ------------------------------------------------------------------
# 노트북에서 빌드해 올리려면 podman 과 레지스트리 자격증명이 필요하고,
# arm64 맥에서 amd64 이미지를 만들려면 크로스 빌드까지 붙습니다.
#
# OCP 는 이미 빌드 시스템과 내부 레지스트리를 갖고 있습니다.
# 빌드는 워커에서 돌고, 결과는 image-registry(S3 백엔드)에 들어갑니다.
# 아키텍처도 자동으로 맞습니다. 클러스터 노드가 곧 빌드 노드라서입니다.
#
# 폐쇄망에서도 같은 그림이 성립합니다. 베이스 이미지만 미러에 있으면 됩니다.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need_cluster

BC=coding-agent
CF="$REPO_ROOT/manifests/30-devtools/Containerfile"
[[ -f "$CF" ]] || die "Containerfile 이 없습니다: $CF"

if [[ "${1:-}" == "--logs" ]]; then
  oc logs -f "bc/$BC" -n "$AGENT_NAMESPACE"
  exit 0
fi

head1 "BuildConfig"

# BuildConfig 는 Dockerfile 을 인라인으로 들고 있습니다.
# 레포의 Containerfile 이 유일한 원본이고, 여기서 그때그때 밀어 넣습니다.
# 두 벌로 관리하면 반드시 어긋납니다.
oc apply -n "$AGENT_NAMESPACE" -f - >/dev/null <<EOF
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: $BC
EOF

# --from-file 로 Dockerfile 을 넘기면 BuildConfig 를 매번 다시 만들 필요가 없습니다.
if ! oc get bc "$BC" -n "$AGENT_NAMESPACE" >/dev/null 2>&1; then
  oc new-build --name="$BC" --strategy=docker --binary \
    --to="$BC:latest" -n "$AGENT_NAMESPACE" >/dev/null
  ok "BuildConfig 생성"
else
  info "BuildConfig 이미 있음"
fi

# docker 전략은 기본으로 'Dockerfile' 이라는 이름을 찾습니다.
# 이 레포는 Containerfile 을 씁니다(ocp-airgap-lab 과 같은 이름 규칙).
# dockerfilePath 를 안 주면 이렇게 실패합니다:
#   error: open /tmp/build/inputs/Dockerfile: no such file or directory
oc patch bc "$BC" -n "$AGENT_NAMESPACE" --type merge \
  -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"Containerfile"}}}}' >/dev/null
ok "dockerfilePath = Containerfile" 

head1 "빌드 시작"
info "Containerfile: $CF"
info "빌드는 워커에서 돌고 결과는 내부 레지스트리로 들어갑니다. 5~10분."

# 바이너리 빌드는 컨텍스트 디렉토리를 통째로 올립니다.
# Containerfile 만 있으면 되므로 그 디렉토리만 보냅니다.
oc start-build "$BC" -n "$AGENT_NAMESPACE" \
  --from-dir="$(dirname "$CF")" \
  --follow --wait

head1 "결과"
IMG=$(oc get istag "$BC:latest" -n "$AGENT_NAMESPACE" \
        -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || true)
if [[ -z "$IMG" ]]; then
  die "이미지 태그를 찾을 수 없습니다. 빌드가 실패했을 수 있습니다:
  oc logs bc/$BC -n $AGENT_NAMESPACE"
fi
ok "$IMG"

printf "\n"
info "이 이미지를 쓰려면 .env 에 넣고 다시 배포하세요:"
info "  IMAGE_DEVTOOLS=image-registry.openshift-image-registry.svc:5000/$AGENT_NAMESPACE/$BC:latest"
info "  ./scripts/render-manifests.sh && oc apply -f clusters/$CLUSTER_NAME/manifests/30-devtools/"
printf "\n"
