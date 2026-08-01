# compact - 워커 없는 3노드 클러스터
#
# 마스터 3 x m6i.2xlarge (8 vCPU), 워커 0, 단일 AZ
# 피크 vCPU: 24 + 4(부트스트랩) = 28
# 대략 시간당 $1.30
#
# compute.replicas: 0 이면 컨트롤 플레인이 schedulable 이 되어 워크로드를
# 마스터에 올릴 수 있습니다. 워커 노드 비용 없이 실제 앱을 배포해볼 때 씁니다.
# etcd 쿼럼이 3이라 SNO보다 안정적입니다.
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
