# 채팅 UI.
#
# ------------------------------------------------------------------
# 이 파일이 이 랩의 측정 대상입니다
# ------------------------------------------------------------------
# Open WebUI 는 기동할 때 최소 네 군데로 나갑니다.
#   1. HuggingFace  - 임베딩 모델(all-MiniLM-L6-v2) 다운로드
#   2. GitHub       - 릴리스 버전 확인
#   3. Scarf        - 다운로드 통계
#   4. 자체 텔레메트리
#
# 인터넷이 있으면 넷 다 성공하고 30~60초에 뜹니다. 그게 기준선입니다.
# 폐쇄망에서는 넷 다 타임아웃까지 매달립니다. 에러가 아니라 지연입니다.
# 로그에 아무것도 안 남고 결국 뜨기 때문에, 원인 찾기가 실패보다 어렵습니다.
#
# AGENT_OFFLINE=true 로 렌더링하면 폐쇄망 설정이 되고, 그 차이를
# verify-agent-stack.sh --baseline 이 초 단위로 재 줍니다.
# 이 랩에서 얻어갈 숫자가 그겁니다.
---
apiVersion: v1
kind: Secret
metadata:
  name: open-webui-secret
  namespace: ${AGENT_NAMESPACE}
type: Opaque
stringData:
  # 세션 쿠키 서명에 쓰입니다. 랩용 고정값입니다.
  # 실제 환경이라면 무작위로 만들어 넣으세요.
  secret-key: lab-fixed-not-a-real-secret
---
# oauth-proxy 가 OAuth 클라이언트로 등록되기 위한 ServiceAccount.
#
# 어노테이션이 핵심입니다.
# OCP 는 이 어노테이션을 보고 "이 SA 는 이 Route 로 리다이렉트해도 되는 OAuth 클라이언트"
# 라고 인정합니다. 별도 OAuthClient 오브젝트를 만들 필요가 없습니다.
# 이름(primary)은 아무거나 되지만 아래 kind/name 과 짝이 맞아야 합니다.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: open-webui-sso
  namespace: ${AGENT_NAMESPACE}
  annotations:
    serviceaccounts.openshift.io/oauth-redirectreference.primary: >-
      {"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"open-webui"}}
---
# oauth-proxy 가 --openshift-sar 로 권한 검사를 하려면
# 사용자를 대신해 SubjectAccessReview / TokenReview 를 만들 수 있어야 합니다.
# 그 권한이 system:auth-delegator 입니다.
#
# 이게 없으면 인증에 성공한 사용자까지 403 이 납니다.
# 심지어 cluster-admin 토큰도 막힙니다. 검사 자체가 실패하기 때문입니다.
# 화면에는 로그인 페이지가 나와서 "인증이 안 됐나" 로 오해하기 쉽습니다.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: open-webui-sso-auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: open-webui-sso
    namespace: ${AGENT_NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: open-webui-oauth-cookie
  namespace: ${AGENT_NAMESPACE}
type: Opaque
stringData:
  # 세션 쿠키 서명 키. 랩용 고정값입니다.
  session_secret: lab-cookie-secret-not-random
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: open-webui-data
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
  name: open-webui
  namespace: ${AGENT_NAMESPACE}
  labels:
    app: open-webui
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: open-webui
  template:
    metadata:
      labels:
        app: open-webui
    spec:
      serviceAccountName: open-webui-sso
      containers:
        - name: open-webui
          image: ${IMAGE_OPENWEBUI}
          ports:
            - name: http
              containerPort: 8080
          env:
            # ------------------------------------------------------
            # 오프라인 스위치. AGENT_OFFLINE 로 한 번에 뒤집힙니다.
            # ------------------------------------------------------
            - name: OFFLINE_MODE
              value: "${OFFLINE_MODE}"
            - name: HF_HUB_OFFLINE
              value: "${HF_OFFLINE}"
            - name: TRANSFORMERS_OFFLINE
              value: "${HF_OFFLINE}"
            - name: ENABLE_VERSION_UPDATE_CHECK
              value: "${VERSION_CHECK}"

            # 통계 전송은 인터넷이 있어도 끕니다.
            # 셋은 이름만 다른 게 아니라 실제로 다른 코드 경로입니다.
            # 하나만 꺼서는 부족합니다.
            - name: DO_NOT_TRACK
              value: "true"
            - name: SCARF_NO_ANALYTICS
              value: "true"
            - name: ANONYMIZED_TELEMETRY
              value: "false"

            # ------------------------------------------------------
            # 임베딩
            # ------------------------------------------------------
            # 인터넷이 있으면 기본값(로컬 sentence-transformers)이 그냥 됩니다.
            # HuggingFace 에서 모델을 받아오기 때문입니다.
            # 폐쇄망에서는 그게 안 되므로 openai 엔진으로 돌려서
            # LiteLLM 을 거쳐 임베딩을 받아야 합니다.
            - name: RAG_EMBEDDING_ENGINE
              value: "${RAG_EMBEDDING_ENGINE}"

            # ------------------------------------------------------
            # 모델 백엔드
            # ------------------------------------------------------
            # ------------------------------------------------------
            # 보조 LLM 호출 끄기. CPU 추론에서는 필수입니다.
            # ------------------------------------------------------
            # Open WebUI 는 사용자가 메시지 하나를 보내면 LLM 을 여러 번 부릅니다.
            # 본 응답 외에 제목 생성, 태그 생성, 후속질문 제안, 자동완성이
            # 각각 별도 요청으로 동시에 나갑니다.
            #
            # GPU 라면 눈에 안 띄지만, CPU 에서 1.5B 를 돌리면 이것들이
            # 본 응답과 CPU 를 나눠 쓰면서 체감 속도를 몇 배로 떨어뜨립니다.
            # 프롬프트도 큽니다. 태그 생성 프롬프트 하나가 5,000 토큰을 넘습니다.
            #
            # llama.cpp 쪽 --parallel 1 과 짝입니다.
            # 그쪽은 "동시에 처리하지 않는다", 이쪽은 "애초에 안 보낸다" 입니다.
            - name: ENABLE_TITLE_GENERATION
              value: "false"
            - name: ENABLE_TAGS_GENERATION
              value: "false"
            - name: ENABLE_FOLLOW_UP_GENERATION
              value: "false"
            - name: ENABLE_AUTOCOMPLETE_GENERATION
              value: "false"
            - name: ENABLE_RETRIEVAL_QUERY_GENERATION
              value: "false"

            - name: ENABLE_OLLAMA_API
              value: "false"
            - name: ENABLE_OPENAI_API
              value: "true"
            - name: OPENAI_API_BASE_URL
              value: "http://litellm:4000/v1"
            - name: OPENAI_API_KEY
              valueFrom:
                secretKeyRef:
                  name: litellm-secret
                  key: master-key

            # ------------------------------------------------------
            # 기타
            # ------------------------------------------------------
            # 랩이라 인증을 끕니다.
            # Route 가 퍼블릭 DNS 로 열려 있으므로 실제 환경에서는 절대 끄지 마세요.
            - name: WEBUI_AUTH
              value: "false"

            # 이게 없으면 기동 스크립트가 키를 만들어 작업 디렉토리에 쓰려 합니다.
            #   start.sh: line 46: .webui_secret_key: Permission denied
            # OCP 는 이미지에 적힌 USER 를 무시하고 네임스페이스마다 배정된
            # 임의 UID 로 컨테이너를 돌립니다. 그 UID 는 /app 에 쓸 권한이 없습니다.
            # 값을 미리 주면 파일을 만들 이유가 없어져서 문제가 사라집니다.
            #
            # 이미지가 "루트로 돌 것" 을 전제로 만들어졌을 때 나오는 전형적인 증상이고,
            # 폐쇄망이든 아니든 OCP 에서는 똑같이 납니다.
            - name: WEBUI_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: open-webui-secret
                  key: secret-key
            - name: DATA_DIR
              value: "/app/backend/data"
          readinessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 60
          resources:
            requests:
              cpu: 100m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 2Gi
          volumeMounts:
            - name: data
              mountPath: /app/backend/data
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
        # ------------------------------------------------------------
        # oauth-proxy: OCP 로그인을 이 앱 앞에 세웁니다
        # ------------------------------------------------------------
        # 이 앱들은 원래 자체 인증이 없거나 꺼져 있습니다.
        # 퍼블릭 DNS 로 Route 가 열려 있으므로 그대로 두면 도메인만 알면 누구나 씁니다.
        #
        # oauth-proxy 를 사이드카로 두면
        #   - 브라우저는 OCP 로그인 화면으로 리다이렉트됩니다(다른 콘솔과 같은 SSO)
        #   - 프로그램은 Bearer 토큰으로 붙습니다: oc whoami -t
        #
        # upstream 이 localhost 인 게 중요합니다.
        # Service 가 프록시 포트만 노출하므로 앱 포트로 우회할 수 없습니다.
        - name: oauth-proxy
          image: ${IMAGE_OAUTH_PROXY}
          args:
            - --https-address=:8443
            - --provider=openshift
            - --openshift-service-account=open-webui-sso
            - --upstream=http://localhost:8080
            - --tls-cert=/etc/tls/private/tls.crt
            - --tls-key=/etc/tls/private/tls.key
            - --cookie-secret-file=/etc/proxy/secrets/session_secret
            # 이 네임스페이스에 접근 권한이 있는 사용자만 통과시킵니다.
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
            # service.beta.openshift.io/serving-cert-secret-name 어노테이션을 보고
            # OCP 가 클러스터 CA 로 서명한 인증서를 여기에 만들어 줍니다.
            secretName: open-webui-tls
        - name: proxy-cookie
          secret:
            secretName: open-webui-oauth-cookie
        - name: data
          persistentVolumeClaim:
            claimName: open-webui-data
---
apiVersion: v1
kind: Service
metadata:
  name: open-webui
  namespace: ${AGENT_NAMESPACE}
  annotations:
    # OCP 가 클러스터 CA 로 서명한 인증서를 이 이름의 Secret 으로 만들어 줍니다.
    service.beta.openshift.io/serving-cert-secret-name: open-webui-tls
spec:
  selector:
    app: open-webui
  ports:
    # 프록시 포트만 노출합니다. 8080 을 열어 두면 인증을 우회할 수 있습니다.
    - name: https
      port: 8443
      targetPort: https
---
# IPI 클러스터라 Route 는 Ingress Operator 가 만든 Classic ELB 를 거칩니다.
# 폐쇄망 랩에서는 같은 이름이 bastion 의 HAProxy 로 들어옵니다.
# 매니페스트는 같고 경로만 다릅니다.
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: open-webui
  namespace: ${AGENT_NAMESPACE}
spec:
  host: chat.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
  to:
    kind: Service
    name: open-webui
  port:
    targetPort: https
  tls:
    # oauth-proxy 가 TLS 를 직접 종료하므로 라우터는 재암호화해서 넘깁니다.
    # edge 로 두면 라우터-파드 구간이 평문이 되고 oauth-proxy 가 거부합니다.
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
