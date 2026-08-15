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
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: open-webui-data
---
apiVersion: v1
kind: Service
metadata:
  name: open-webui
  namespace: ${AGENT_NAMESPACE}
spec:
  selector:
    app: open-webui
  ports:
    - name: http
      port: 8080
      targetPort: http
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
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
