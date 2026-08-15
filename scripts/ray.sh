#!/usr/bin/env bash
# Ray 클러스터를 올리고 내립니다.
#
#   ./scripts/ray.sh up          헤드만 (GPU 0장)
#   ./scripts/ray.sh worker 1    GPU 워커 1장 붙이기
#   ./scripts/ray.sh worker 0    워커 반납
#   ./scripts/ray.sh status      상태 + 누가 GPU 를 쓰는지
#   ./scripts/ray.sh test        분산 태스크 실행 (실제로 도는지 확인)
#   ./scripts/ray.sh dashboard   대시보드 포트포워드
#   ./scripts/ray.sh down        삭제
#
# ------------------------------------------------------------------
# 헤드와 워커를 나눠 올리는 이유
# ------------------------------------------------------------------
# 헤드는 CPU 만 씁니다. 워커만 GPU 를 요청합니다.
#
# GPU 가 한 장뿐이라 vLLM 서빙 · 학습 잡 · Ray 워커가 같은 자원을 놓고 다툽니다.
# 먼저 잡은 쪽이 이기고 나머지는 Pending 이며, 그 사이에 우선순위 개념이 없습니다.
# 그 Pending 을 정책으로 바꾸는 게 Kueue 이고, 그래서 둘을 같이 켭니다.
#
# 헤드만 먼저 띄우면 GPU 없이도 Ray 가 어떻게 생겼는지 볼 수 있습니다.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need_cluster

ACTION="${1:-status}"
NAME=lab-ray
NS="$RHOAI_NAMESPACE"

# RayCluster 에는 scale 서브리소스가 없습니다.
# oc scale 이 안 먹어서 workerGroupSpecs 를 patch 로 바꿔야 합니다.
set_workers() {
  oc patch raycluster "$NAME" -n "$NS" --type=merge \
    -p "{\"spec\":{\"workerGroupSpecs\":[{\"groupName\":\"gpu\",\"replicas\":$1,\"minReplicas\":0,\"maxReplicas\":1,\"rayStartParams\":{},\"template\":$(
      oc get raycluster "$NAME" -n "$NS" -o json | jq -c '.spec.workerGroupSpecs[0].template'
    )}]}}" >/dev/null
}

case "$ACTION" in

# ==================================================================
up)
  head1 "Ray 클러스터"
  D="$CLUSTER_DIR/manifests/90-ray"
  [[ -d "$D" ]] || die "$D 가 없습니다. 먼저: ./scripts/render-manifests.sh"

  oc get crd rayclusters.ray.io >/dev/null 2>&1 \
    || die "RayCluster CRD 가 없습니다. 먼저: ./scripts/install-rhoai.sh distributed"

  oc apply -f "$D" >/dev/null || die "적용 실패"
  ok "RayCluster $NAME 적용 (헤드만, 워커 0)"

  printf "  헤드 기동 "
  for _ in $(seq 1 40); do
    S=$(oc get raycluster "$NAME" -n "$NS" -o jsonpath='{.status.state}' 2>/dev/null)
    [[ "$S" == "ready" ]] && break
    printf "."
    sleep 10
  done
  printf "\n"

  S=$(oc get raycluster "$NAME" -n "$NS" -o jsonpath='{.status.state}' 2>/dev/null)
  if [[ "$S" == "ready" ]]; then
    ok "RayCluster ready"
  else
    warn "상태가 아직 '$S' 입니다. $0 status 로 확인하세요"
  fi
  printf "\n"
  info "GPU 워커를 붙이려면:  $0 worker 1"
  info "  단, GPU 1장을 서빙이 쓰고 있으면 Pending 입니다"
  printf "\n"
  ;;

# ==================================================================
worker)
  N="${2:-}"
  [[ "$N" =~ ^[0-9]+$ ]] || die "사용법: $0 worker <개수>"
  oc get raycluster "$NAME" -n "$NS" >/dev/null 2>&1 || die "$NAME 이 없습니다. 먼저: $0 up"

  if [[ "$N" -gt 0 ]]; then
    head1 "GPU 워커 $N 개"
    # 붙이기 전에 GPU 가 비었는지 봅니다.
    # 안 그러면 Pending 파드만 남고 이유는 이벤트에만 적힙니다.
    USED=$(oc get pods -A -o json 2>/dev/null | jq '[.items[]
      | select(.status.phase=="Running")
      | .spec.containers[].resources.limits["nvidia.com/gpu"] // "0" | tonumber] | add // 0')
    TOTAL=$(oc get nodes -l node-role.kubernetes.io/gpu \
      -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
      | awk '{s+=$1} END {print s+0}')
    info "GPU  전체 $TOTAL장  사용 중 $USED장"
    if (( USED >= TOTAL )); then
      warn "빈 GPU 가 없습니다. 워커는 Pending 에 머뭅니다"
      warn "  서빙을 내리려면: ./scripts/tune.sh run 이 쓰는 것과 같은 방법"
      warn "  oc scale deploy/${VLLM_MODEL_NAME}-predictor -n $NS --replicas=0"
    fi
  else
    head1 "워커 반납"
  fi

  set_workers "$N"
  ok "workerGroupSpecs[gpu].replicas = $N"
  printf "\n"
  ;;

# ==================================================================
status)
  head1 "RayCluster"
  oc get raycluster "$NAME" -n "$NS" \
     -o custom-columns=NAME:.metadata.name,STATE:.status.state,READY:.status.availableWorkerReplicas,DESIRED:.status.desiredWorkerReplicas \
     --no-headers 2>/dev/null | sed 's/^/  /' || info "$NAME 없음"

  head1 "파드"
  oc get pods -n "$NS" -l ray.io/cluster="$NAME" --no-headers 2>/dev/null | sed 's/^/  /' \
    || info "파드 없음"

  head1 "GPU 를 지금 누가 쓰나"
  oc get pods -A -o json 2>/dev/null | jq -r '
    .items[]
    | select(.status.phase=="Running" or .status.phase=="Pending")
    | . as $p
    | .spec.containers[]
    | select(.resources.limits["nvidia.com/gpu"] // .resources.requests["nvidia.com/gpu"])
    | "  \($p.status.phase)  \($p.metadata.namespace)/\($p.metadata.name)  \(.resources.limits["nvidia.com/gpu"] // .resources.requests["nvidia.com/gpu"])장"' \
    || info "GPU 를 요청하는 파드 없음"
  printf "\n"
  ;;

# ==================================================================
test)
  # 헤드 파드 안에서 돌립니다. 클라이언트를 밖에 두면 버전 맞추기가 일이 됩니다.
  POD=$(oc get pods -n "$NS" -l ray.io/cluster="$NAME",ray.io/node-type=head \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -n "$POD" ]] || die "헤드 파드를 찾을 수 없습니다. $0 status 로 확인하세요"

  head1 "분산 태스크"
  info "헤드: $POD"
  ADDR="${NAME}-head-svc.${NS}.svc.cluster.local:6379"
  info "주소: $ADDR"
  printf "\n"
  # 주소를 명시합니다. address="auto" 는 여기서 안 됩니다.
  #
  # KubeRay 는 헤드 노드를 파드 IP 가 아니라 헤드 Service 의 DNS 이름으로 등록합니다.
  #   Local node IP: lab-ray-head-svc.ai-serving.svc.cluster.local
  # 그런데 "auto" 는 로컬 세션 파일에서 파드 IP(10.x)를 읽어와 거기로 붙으려 하고,
  # GCS 는 그 주소로 듣고 있지 않아 5초 타임아웃 뒤 조용히 매달립니다.
  #   Failed to connect to GCS at address 10.128.2.59:6379
  # 파드는 Running, RayCluster 는 ready 라서 원인을 찾기 어렵습니다.
  #
  # f-string 안에 백슬래시를 못 씁니다(파이썬 3.11 이하).
  # 이스케이프한 따옴표가 f-string 표현식에 들어가면 SyntaxError 입니다.
  # 그래서 % 포매팅을 씁니다.
  oc exec "$POD" -n "$NS" -c ray-head -- env RAY_HEAD_ADDR="$ADDR" python -c '
import ray, socket, os
addr = os.environ.get("RAY_HEAD_ADDR")
ray.init(address=addr, ignore_reinit_error=True)
r = ray.cluster_resources()
cpu = r.get("CPU", 0)
gpu = r.get("GPU", 0)
nodes = len([k for k in r if k.startswith("node:")])
print("클러스터 자원: CPU=%s GPU=%s 노드=%s" % (cpu, gpu, nodes))

@ray.remote
def where(i):
    return "task %d -> %s" % (i, socket.gethostname())

print("\n".join(ray.get([where.remote(i) for i in range(6)])))

if gpu > 0:
    @ray.remote(num_gpus=1)
    def gpu_task():
        import torch
        return "GPU 태스크 -> %s" % torch.cuda.get_device_name(0)
    print(ray.get(gpu_task.remote()))
else:
    print("GPU 워커가 없습니다. ray.sh worker 1 로 붙이세요")
' 2>&1 | sed 's/^/  /'
  printf "\n"
  ;;

# ==================================================================
dashboard)
  info "http://localhost:8265 (Ctrl-C 로 종료)"
  oc port-forward -n "$NS" "svc/${NAME}-head-svc" 8265:8265
  ;;

# ==================================================================
down)
  head1 "삭제"
  oc delete raycluster "$NAME" -n "$NS" >/dev/null 2>&1 \
    && ok "$NAME 삭제" || info "$NAME 없음"
  printf "\n"
  ;;

*) die "사용법: $0 up | worker <n> | status | test | dashboard | down" ;;
esac
