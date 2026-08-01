# sno - Single Node OpenShift, 가장 저렴
#
# 노드 1 x m6i.2xlarge (8 vCPU / 32 GiB), 단일 AZ
# 피크 vCPU: 8 + 4(부트스트랩) = 12
# 대략 시간당 $0.49
#
# Red Hat 문서 기준 SNO 최소 요구사항은 8 vCPU / 120GB 스토리지입니다.
# compute.replicas: 0 이면 컨트롤 플레인 노드가 schedulable 이 됩니다.
# SNO는 OVNKubernetes만 허용됩니다.
#
# 주의: 노드가 1개라 etcd 쿼럼도 1입니다. 노드를 재부팅하면 클러스터 전체가
# 내려갑니다. 설치 파이프라인과 destroy 경로를 싸게 검증하는 용도로 쓰세요.
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
controlPlane:
  name: master
  replicas: 1
  architecture: amd64
  hyperthreading: Enabled
  platform:
    aws:
      type: m6i.2xlarge
      zones:
        - ${AZ}
      rootVolume:
        size: 120
        type: gp3
compute:
  - name: worker
    replicas: 0
    architecture: amd64
    platform:
      aws:
        zones:
          - ${AZ}
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
