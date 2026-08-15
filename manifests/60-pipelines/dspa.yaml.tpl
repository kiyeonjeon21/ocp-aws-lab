# Data Science Pipelines 서버.
#
# ------------------------------------------------------------------
# 파이프라인은 S3 가 없으면 시작조차 못 합니다
# ------------------------------------------------------------------
# DSPA 의 objectStorage 는 required 입니다.
# 파이프라인의 각 단계가 주고받는 산출물(artifact)이 전부 오브젝트 스토리지에 쌓이기 때문입니다.
#
# AWS 라면 S3 버킷을 쓰면 되지만, 그러려면 IAM 사용자와 액세스 키를 만들어야 합니다.
# 랩에서 계정 자격증명을 새로 만드는 건 정리할 게 하나 더 느는 일입니다.
#
# 그래서 MinIO 를 클러스터 안에 띄웁니다. 이게 폐쇄망의 실제 모습이기도 합니다.
# docs/storage.md 에 적어 둔 "클라우드가 안 주면 클러스터가 스스로 만들어야 한다" 가 이 자리입니다.
#
# ------------------------------------------------------------------
# 이미지를 왜 직접 적나
# ------------------------------------------------------------------
# RHOAI 3.4 는 번들 MinIO 를 걷어냈습니다.
# 오퍼레이터의 IMAGES_* 목록에 MARIADB 는 있는데 MINIO 는 없습니다.
# CRD 에 minio 필드는 남아 있고 image 가 required 라, 우리가 지정해야 합니다.
#
# 실제 환경이라면 externalStorage 로 기존 S3 나 ODF 를 가리킵니다.
---
apiVersion: datasciencepipelinesapplications.opendatahub.io/v1
kind: DataSciencePipelinesApplication
metadata:
  name: pipelines
  namespace: ${RHOAI_NAMESPACE}
spec:
  # v2 가 기본입니다. Argo Workflows 기반입니다.
  dspVersion: v2

  objectStorage:
    minio:
      deploy: true
      bucket: mlpipeline
      image: ${IMAGE_MINIO}
      pvcSize: 10Gi

  # 파이프라인 메타데이터(실행 이력, 파라미터)를 담습니다.
  # 이미지를 안 적으면 오퍼레이터의 IMAGES_MARIADB 기본값을 씁니다.
  database:
    mariaDB:
      deploy: true
      pvcSize: 10Gi

  apiServer:
    deploy: true
    # 샘플 파이프라인을 같이 넣어 줍니다.
    # 처음 볼 때 "무엇을 눌러야 하나" 를 없애 줍니다.
    enableSamplePipeline: true

  persistenceAgent:
    deploy: true
  scheduledWorkflow:
    deploy: true
