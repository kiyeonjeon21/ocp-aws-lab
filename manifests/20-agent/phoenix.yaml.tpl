# OTEL 트레이싱 / 관측성.
#
# Langfuse 가 더 현실적이지만 web + worker + ClickHouse + Redis + MinIO 로
# 6GB 를 먹습니다. Phoenix 는 단일 컨테이너 + SQLite 라 랩 자원에 맞습니다.
#
# RHOAI 를 올리고 나면 이 자리에 TrustyAI 와 모델 모니터링이 겹칩니다.
# 두 개를 같이 띄워 보고 무엇이 겹치고 무엇이 안 겹치는지 보는 게 이 랩의 재료입니다.
#
# ------------------------------------------------------------------
# Phoenix 는 인증이 없습니다. 그래서 앞에 oauth-proxy 를 세웁니다
# ------------------------------------------------------------------
# Phoenix 에는 로그인이라는 개념이 없습니다. 열면 전부 보입니다.
# 그런데 여기 쌓이는 건 프롬프트와 응답 전문입니다. 트레이싱 도구 중에서도
# 가장 민감한 축입니다.
#
# 붙이기 전 실측입니다. 인증 없이 이만큼 됐습니다.
#   /            200
#   /graphql     200   트레이스 전문 조회
#   /v1/traces   200   트레이스 주입까지 가능
#
# ------------------------------------------------------------------
# open-webui 와 달리 앱 포트를 Service 에 남겨 둡니다
# ------------------------------------------------------------------
# open-webui 는 프록시 포트만 노출했습니다. 사람만 쓰는 화면이라 그래도 됩니다.
#
# Phoenix 는 다릅니다. 6006/4317 은 클러스터 안의 앱이 트레이스를 밀어 넣는
# 수집 엔드포인트입니다. OTLP 로 보내는 쪽은 OAuth 로그인을 할 수 없습니다.
# 프록시 뒤로 감추면 트레이싱 자체가 죽습니다.
#
# 그래서 이 파일이 막는 건 **밖에서 들어오는 경로(Route)** 입니다.
# 클러스터 안에서는 phoenix.${AGENT_NAMESPACE}.svc:6006 이 그대로 열려 있습니다.
# 그건 oauth-proxy 가 아니라 NetworkPolicy 로 좁히는 문제입니다. 층이 다릅니다.
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
# oauth-proxy 가 OAuth 클라이언트로 등록되기 위한 ServiceAccount.
# 어노테이션의 Route 이름과 아래 Route 이름이 어긋나면 리다이렉트가 거부됩니다.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: phoenix-sso
  namespace: ${AGENT_NAMESPACE}
  annotations:
    serviceaccounts.openshift.io/oauth-redirectreference.primary: >-
      {"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"phoenix"}}
---
# --openshift-sar 로 권한 검사를 하려면 사용자를 대신해
# SubjectAccessReview / TokenReview 를 만들 수 있어야 합니다.
#
# 이게 없으면 인증에 성공한 사용자까지 403 이 납니다. cluster-admin 도 막힙니다.
# 화면에는 로그인 페이지가 나와서 "인증이 안 됐나" 로 오해하기 쉽습니다.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: phoenix-sso-auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: phoenix-sso
    namespace: ${AGENT_NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: phoenix-oauth-cookie
  namespace: ${AGENT_NAMESPACE}
type: Opaque
stringData:
  # 세션 쿠키 서명 키. 랩용 고정값입니다.
  session_secret: lab-cookie-secret-not-random
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
      serviceAccountName: phoenix-sso
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
        - name: oauth-proxy
          image: ${IMAGE_OAUTH_PROXY}
          args:
            - --https-address=:8443
            - --provider=openshift
            - --openshift-service-account=phoenix-sso
            - --upstream=http://localhost:6006
            - --tls-cert=/etc/tls/private/tls.crt
            - --tls-key=/etc/tls/private/tls.key
            - --cookie-secret-file=/etc/proxy/secrets/session_secret
            # 인증(누구인가)에 더해 인가(권한이 있는가)까지 겁니다.
            - --openshift-sar={"namespace":"${AGENT_NAMESPACE}","resource":"services","verb":"get"}
          ports:
            - name: https
              containerPort: 8443
          volumeMounts:
            - name: proxy-tls
              mountPath: /etc/tls/private
            - name: proxy-cookie
              mountPath: /etc/proxy/secrets
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
      volumes:
        - name: proxy-tls
          secret:
            secretName: phoenix-tls
        - name: proxy-cookie
          secret:
            secretName: phoenix-oauth-cookie
        - name: data
          persistentVolumeClaim:
            claimName: phoenix-data
---
apiVersion: v1
kind: Service
metadata:
  name: phoenix
  namespace: ${AGENT_NAMESPACE}
  annotations:
    # OCP 가 클러스터 CA 로 서명한 인증서를 이 이름의 Secret 으로 만들어 줍니다.
    service.beta.openshift.io/serving-cert-secret-name: phoenix-tls
spec:
  selector:
    app: phoenix
  ports:
    # Route 가 쓰는 포트. 여기만 인증이 걸립니다.
    - name: https
      port: 8443
      targetPort: https
    # 클러스터 안에서 트레이스를 밀어 넣는 수집 포트입니다.
    # OTLP 클라이언트는 OAuth 를 못 하므로 프록시 뒤로 넣을 수 없습니다.
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
    targetPort: https
  tls:
    # oauth-proxy 가 TLS 를 직접 종료하므로 라우터는 재암호화해서 넘깁니다.
    # edge 로 두면 라우터-파드 구간이 평문이 되고 oauth-proxy 가 거부합니다.
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
