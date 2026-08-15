# Ray 클러스터.
#
# ------------------------------------------------------------------
# 이 랩에서 Ray 로 무엇을 보나
# ------------------------------------------------------------------
# GPU 한 장짜리 랩에서 Ray 로 "분산 학습" 을 보여 줄 수는 없습니다.
# 그건 정직하지 않습니다.
#
# 대신 볼 수 있는 게 있습니다. **자원을 요구하는 주체가 하나 더 늘었을 때
# 쿠버네티스가 어떻게 행동하는가** 입니다.
#
#   - Ray 헤드는 CPU 만 씁니다. 워커만 GPU 를 요청합니다
#   - vLLM 서빙, 학습 잡, Ray 워커가 전부 같은 nvidia.com/gpu 1 을 놓고 다툽니다
#   - 먼저 잡은 쪽이 이기고 나머지는 Pending 입니다. 우선순위 개념이 없습니다
#
# 그 Pending 을 "누가 먼저 쓸지" 정책으로 바꾸는 게 Kueue 입니다.
# 그래서 install-rhoai.sh distributed 가 ray 와 kueue 를 같이 켭니다.
#
# ------------------------------------------------------------------
# 왜 워커를 0으로 두고 시작하나
# ------------------------------------------------------------------
# replicas: 0 이 기본입니다.
# 헤드만 띄워서 대시보드와 클라이언트 연결을 먼저 확인하고,
# GPU 가 실제로 비었을 때만 워커를 올립니다.
#
#   oc scale rayclusters lab-ray --replicas=1   # 은 동작하지 않습니다
#   oc patch raycluster lab-ray --type=merge \
#     -p '{"spec":{"workerGroupSpecs":[{"groupName":"gpu","replicas":1}]}}'
#
# RayCluster 는 scale 서브리소스가 없어서 patch 로 바꿉니다.
# ray.sh 가 이걸 대신 해 줍니다.
---
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: lab-ray
  namespace: ${RHOAI_NAMESPACE}
  labels:
    # PyTorchJob 과 같은 이유입니다.
    # 이게 있어야 Kueue 가 Workload 를 만들고 RHOAI 대시보드에 보입니다.
    kueue.x-k8s.io/queue-name: default
spec:
  # KubeRay 오퍼레이터가 이 버전에 맞는 이미지를 붙입니다.
  # rayVersion 과 컨테이너 이미지의 Ray 버전이 어긋나면
  # 워커가 헤드에 붙지 못하고 조용히 재시작만 반복합니다.
  rayVersion: "2.46.0"

  headGroupSpec:
    rayStartParams:
      # 헤드에 워크로드를 스케줄하지 않습니다.
      # 안 그러면 헤드가 GPU 를 잡아버려 워커가 굶습니다.
      num-cpus: "0"
      dashboard-host: "0.0.0.0"
    template:
      spec:
        containers:
          - name: ray-head
            image: ${IMAGE_RAY}
            ports:
              - name: gcs
                containerPort: 6379
              - name: client
                containerPort: 10001
              - name: dashboard
                containerPort: 8265
            env:
              # OCP 임의 UID 는 홈이 / 로 잡힙니다.
              # Ray 가 세션 디렉토리를 만들 때 Permission denied 로 죽습니다.
              - name: HOME
                value: /tmp
              - name: RAY_TMPDIR
                value: /tmp/ray
            resources:
              requests:
                cpu: "1"
                memory: 4Gi
              limits:
                cpu: "2"
                memory: 6Gi
            volumeMounts:
              - name: tmp
                mountPath: /tmp
              # Ray 는 오브젝트 스토어로 /dev/shm 을 씁니다.
              # 기본 64MB 로 두면 조금만 큰 객체에도 성능이 무너지고,
              # 경고만 나오고 계속 돌아서 원인을 찾기 어렵습니다.
              - name: dshm
                mountPath: /dev/shm
        volumes:
          - name: tmp
            emptyDir: {}
          - name: dshm
            emptyDir:
              medium: Memory
              sizeLimit: 2Gi

  workerGroupSpecs:
    - groupName: gpu
      # 0 으로 시작합니다. GPU 가 빌 때만 올립니다. ray.sh up 참고
      replicas: 0
      minReplicas: 0
      maxReplicas: 1
      rayStartParams: {}
      template:
        spec:
          # GPU 노드의 taint 를 견뎌야 스케줄됩니다.
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          containers:
            - name: ray-worker
              image: ${IMAGE_RAY}
              env:
                - name: HOME
                  value: /tmp
                - name: RAY_TMPDIR
                  value: /tmp/ray
              resources:
                requests:
                  cpu: "2"
                  memory: 6Gi
                  nvidia.com/gpu: 1
                limits:
                  cpu: "3"
                  memory: 8Gi
                  nvidia.com/gpu: 1
              volumeMounts:
                - name: tmp
                  mountPath: /tmp
                - name: dshm
                  mountPath: /dev/shm
          volumes:
            - name: tmp
              emptyDir: {}
            - name: dshm
              emptyDir:
                medium: Memory
                sizeLimit: 2Gi
