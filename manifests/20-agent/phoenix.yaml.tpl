# OTEL 트레이싱 / 관측성.
#
# Langfuse 가 더 현실적이지만 web + worker + ClickHouse + Redis + MinIO 로
# 6GB 를 먹습니다. Phoenix 는 단일 컨테이너 + SQLite 라 랩 자원에 맞습니다.
#
# RHOAI 를 올리고 나면 이 자리에 TrustyAI 와 모델 모니터링이 겹칩니다.
# 두 개를 같이 띄워 보고 무엇이 겹치고 무엇이 안 겹치는지 보는 게 이 랩의 재료입니다.
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: phoenix-data
  namespace: ${AGENT_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: phoenix
  namespace: ${AGENT_NAMESPACE}
  labels:
    app: phoenix
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: phoenix
  template:
    metadata:
      labels:
        app: phoenix
    spec:
      containers:
        - name: phoenix
          image: ${IMAGE_PHOENIX}
          ports:
            - name: http
              containerPort: 6006
            - name: otlp-grpc
              containerPort: 4317
          env:
            - name: PHOENIX_WORKING_DIR
              value: "/mnt/data"
            - name: PHOENIX_PORT
              value: "6006"
            - name: DO_NOT_TRACK
              value: "1"
            - name: ANONYMIZED_TELEMETRY
              value: "false"
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 30
          resources:
            requests:
              cpu: 100m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
          volumeMounts:
            - name: data
              mountPath: /mnt/data
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: phoenix-data
---
apiVersion: v1
kind: Service
metadata:
  name: phoenix
  namespace: ${AGENT_NAMESPACE}
spec:
  selector:
    app: phoenix
  ports:
    - name: http
      port: 6006
      targetPort: http
    - name: otlp-grpc
      port: 4317
      targetPort: otlp-grpc
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: phoenix
  namespace: ${AGENT_NAMESPACE}
spec:
  host: trace.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
  to:
    kind: Service
    name: phoenix
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
