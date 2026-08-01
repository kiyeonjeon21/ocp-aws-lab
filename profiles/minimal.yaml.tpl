# minimal - 설치 절차 연습용 기본 프로파일
#
# 마스터 3 x m6i.xlarge (4 vCPU) + 워커 2 x m6i.large (2 vCPU), 단일 AZ
# 피크 vCPU: 12 + 4 + 4(부트스트랩) = 20
# 대략 시간당 $0.93
#
# 단일 AZ로 고정하는 이유: 설치 프로그램은 머신 풀에 지정된 AZ에만 서브넷을
# 만듭니다. AZ가 1개면 NAT Gateway도 1개만 생성돼 월 $65가 절약됩니다.
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
        type: m6i.large
        zones:
          - ${AZ}
        rootVolume:
          size: 120
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
