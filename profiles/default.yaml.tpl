# default - 설치 프로그램 기본값에 가까운 3 AZ 구성
#
# 마스터 3 x m6i.xlarge + 워커 3 x m6i.xlarge, 3 AZ
# 피크 vCPU: 12 + 12 + 4(부트스트랩) = 28
# 대략 시간당 $1.35
#
# 이 프로파일만 AZ를 지정하지 않습니다. 설치 프로그램이 리전의 AZ 3개에
# 걸쳐 서브넷을 만들고, 그 결과 NAT Gateway도 3개 생깁니다 (시간당 $0.135).
# 프로덕션에 가까운 구성을 체험하는 용도이고, 연습 기본값으로는 쓰지 마세요.
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
      rootVolume:
        size: 120
        type: gp3
compute:
  - name: worker
    replicas: 3
    architecture: amd64
    hyperthreading: Enabled
    platform:
      aws:
        type: m6i.xlarge
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
