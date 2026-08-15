# 벡터 DB.
#
# 이 스택에서 Qdrant 의 또 다른 역할은 대조군입니다.
# 단일 바이너리에 외부 의존이 없어서 어디서든 "그냥 도는" 게 정상입니다.
# 여기까지 안 되면 문제는 agent 스택이 아니라 스토리지 쪽입니다.
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: qdrant-storage
  namespace: ${AGENT_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  # AWS IPI 는 gp3-csi 가 기본 StorageClass 로 붙어 있습니다.
  # platform:none 에는 StorageClass 가 아예 없어서 폐쇄망 랩은 여기서 먼저 막힙니다.
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qdrant
  namespace: ${AGENT_NAMESPACE}
  labels:
    app: qdrant
spec:
  replicas: 1
  strategy:
    # RWO PVC 를 두 파드가 동시에 잡을 수 없습니다.
    type: Recreate
  selector:
    matchLabels:
      app: qdrant
  template:
    metadata:
      labels:
        app: qdrant
    spec:
      containers:
        - name: qdrant
          image: ${IMAGE_QDRANT}
          ports:
            - name: http
              containerPort: 6333
            - name: grpc
              containerPort: 6334
          env:
            - name: QDRANT__TELEMETRY_DISABLED
              value: "true"
            - name: QDRANT__SERVICE__HTTP_PORT
              value: "6333"
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /livez
              port: http
            initialDelaySeconds: 20
            periodSeconds: 30
          resources:
            requests:
              cpu: 100m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
          volumeMounts:
            - name: storage
              mountPath: /qdrant/storage
            # 스냅샷 경로는 스토리지 경로와 별개입니다.
            # 안 잡아 주면 이미지 레이어에 쓰려다 read-only 로 죽습니다.
            - name: snapshots
              mountPath: /qdrant/snapshots
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
      volumes:
        - name: storage
          persistentVolumeClaim:
            claimName: qdrant-storage
        - name: snapshots
          emptyDir:
            sizeLimit: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: qdrant
  namespace: ${AGENT_NAMESPACE}
spec:
  selector:
    app: qdrant
  ports:
    - name: http
      port: 6333
      targetPort: http
    - name: grpc
      port: 6334
      targetPort: grpc
