# ai - agent 스택 + Red Hat OpenShift AI 실습용
#
# 마스터 3 x m6i.xlarge (4 vCPU) + 워커 2 x m6i.2xlarge (8 vCPU), 단일 AZ
# 피크 vCPU: 12 + 16 + 4(부트스트랩) = 32
# 대략 시간당 $1.30 (us-east-1) / $1.60 (ap-northeast-2)
#
# ------------------------------------------------------------------
# 왜 워커가 m6i.2xlarge 인가
# ------------------------------------------------------------------
# RHOAI 자체 요구사항이 워커 노드당 8 CPU / 32 GiB 입니다.
# minimal 의 m6i.large 는 2 vCPU / 8 GiB 라 기준선의 1/4 입니다.
# OCP 모니터링 스택만으로 이미 5~6GB 를 먹기 때문에, m6i.large 에서는
# RHOAI 대시보드 파드조차 스케줄되지 않습니다.
#
# 8 vCPU / 32 GiB x 2 대에서 실제 배분은 대략 이렇습니다.
#   OCP 시스템(모니터링/로깅/네트워크)   ~10 GiB
#   RHOAI 컨트롤 플레인 + 대시보드        ~8 GiB
#   agent 스택(llama.cpp 4 + 나머지 5)   ~9 GiB
#   여유                                  ~37 GiB
#
# GPU 노드는 여기 없습니다. 설치 후 scripts/gpu-node.sh 로 붙였다 뗍니다.
# 설치 시점부터 GPU 를 달면 설치 40분 내내 시간당 $0.80 이 그냥 나갑니다.
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
controlPlane:
  name: master
  replicas: 3
  architecture: amd64
  hyperthreading: Enabled
  platform:
    aws:
      type: m6i.xlarge
      zones:
        - ${AZ}
      rootVolume:
        size: 120
        type: gp3
compute:
  - name: worker
    replicas: 2
    architecture: amd64
    hyperthreading: Enabled
    platform:
      aws:
        type: m6i.2xlarge
        zones:
          - ${AZ}
        # 모델 가중치와 컨테이너 이미지가 노드 디스크를 많이 씁니다.
        # vLLM 이미지 하나가 압축 해제 후 10GB 를 넘습니다.
        # 120GB 로 두면 이미지 GC 가 계속 돌면서 pull 을 반복합니다.
        rootVolume:
          size: 200
          type: gp3
networking:
  networkType: OVNKubernetes
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 10.0.0.0/16
  serviceNetwork:
    - 172.30.0.0/16
platform:
  aws:
    region: ${REGION}
    propagateUserTags: true
    userTags:
      Owner: ${OWNER}
      Purpose: lab
      Project: ocp-aws-lab
      AutoDelete: "true"
publish: External
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_PUBLIC_KEY}'
