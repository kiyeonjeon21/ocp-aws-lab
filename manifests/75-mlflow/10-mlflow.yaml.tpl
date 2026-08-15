# MLflow 추적 서버.
#
# ------------------------------------------------------------------
# 오퍼레이터는 이미 떠 있는데 화면이 비어 있는 이유
# ------------------------------------------------------------------
# RHOAI 의 mlflowoperator 컴포넌트는 기본으로 Managed 입니다.
# 그래서 redhat-ods-applications 에 컨트롤러가 떠 있고,
# 대시보드에도 Develop & train > Experiments (MLflow) 메뉴가 보입니다.
#
# 그런데 **인스턴스는 자동으로 안 만들어집니다.**
#   oc get mlflows -A   ->  No resources found
# 오퍼레이터가 있다는 것과 서버가 있다는 것은 다릅니다.
# DSPA(파이프라인 서버)를 따로 만들어야 했던 것과 같은 구조입니다.
#
# ------------------------------------------------------------------
# SQLite + PVC 로 두는 이유
# ------------------------------------------------------------------
# CRD 의 required 는 비어 있지만 backendStoreUri 는 사실상 필수입니다.
# 선택지는 둘입니다.
#
#   원격(PostgreSQL + S3)   실제 환경의 정답. 대신 DB 와 버킷을 따로 준비해야 합니다
#   SQLite + 파일(PVC)       랩 규모에 맞음. PVC 하나로 끝납니다
#
# 이 랩은 만들었다 지웠다를 반복하므로 정리할 것이 하나라도 적은 쪽이 낫습니다.
# DSPA 가 MinIO 를 클러스터 안에 띄운 것과 같은 판단입니다.
#
# 실제 환경이라면 backendStoreUriFrom 으로 Secret 에서 PostgreSQL 접속 문자열을 읽고,
# artifactsDestination 을 s3:// 로 둡니다. 그 경우 storage 는 필요 없습니다.
#
# ------------------------------------------------------------------
# serveArtifacts 를 켜는 이유
# ------------------------------------------------------------------
# 끄면 클라이언트(학습 파드)가 아티팩트 저장소에 **직접** 접근해야 합니다.
# 파일 기반이면 같은 PVC 를 학습 파드에도 마운트해야 하고,
# RWO 볼륨이라 서버와 학습 파드가 같은 노드에 있어야 합니다. 실습에서 잘 깨집니다.
#
# 켜면 학습 파드는 MLflow REST API 로만 말하면 됩니다.
---
apiVersion: mlflow.opendatahub.io/v1
kind: MLflow
metadata:
  name: mlflow
  namespace: ${RHOAI_NAMESPACE}
spec:
  replicas: 1

  # sqlite 파일과 아티팩트가 같은 PVC 에 들어갑니다.
  storage:
    accessModes: ["ReadWriteOnce"]
    storageClassName: ${STORAGE_CLASS}
    resources:
      requests:
        storage: 10Gi

  # 슬래시 네 개입니다. sqlite:// 스킴 뒤에 절대경로 /mlflow/mlflow.db 가 붙습니다.
  # 세 개로 쓰면 상대경로가 되어 파드마다 다른 파일을 보게 됩니다.
  backendStoreUri: "sqlite:////mlflow/mlflow.db"

  # 학습 파드가 REST API 로만 아티팩트를 주고받게 합니다.
  serveArtifacts: true
  artifactsDestination: "file:///mlflow/artifacts"

  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: "1"
      memory: 2Gi
