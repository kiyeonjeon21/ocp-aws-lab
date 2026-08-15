# OpenAI 호환 프록시.
#
# 왜 넣나:
#   agent 프레임워크는 거의 전부 OpenAI 클라이언트를 씁니다.
#   그 앞에 이걸 하나 세워 두면 앱을 안 고치고 백엔드를 갈아끼울 수 있습니다.
#   이 랩에서 실제로 그렇게 씁니다.
#     llama.cpp (CPU)  ->  RHOAI 의 vLLM (GPU)
#   바뀌는 건 아래 api_base 한 줄이고, Open WebUI 는 그대로 둡니다.
#   scripts/switch-backend.sh 가 그 한 줄을 바꿉니다.
#
# 폐쇄망에서 걸리는 지점이 둘 있습니다.
#   1. 기동 시 GitHub 에서 모델 가격표(model_prices_and_context_window.json)를 받아옴
#   2. 익명 사용 통계 전송
# 둘 다 "실패"가 아니라 "타임아웃까지 대기"로 나타납니다.
# 여기(인터넷 있음)서는 1번이 성공하고 빨리 끝납니다. 그 시간차가 기준선입니다.
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-config
  namespace: ${AGENT_NAMESPACE}
data:
  config.yaml: |
    model_list:
      # model_name 은 클라이언트가 부르는 이름입니다.
      # llama.cpp 의 --alias 와 맞춰 두면 로그 읽을 때 헷갈리지 않습니다.
      - model_name: ${MODEL_NAME}
        litellm_params:
          # openai/ 접두사는 "OpenAI 호환 API 규격으로 말하라"는 뜻입니다.
          # api.openai.com 으로 나간다는 뜻이 아닙니다. api_base 가 목적지입니다.
          model: openai/${MODEL_NAME}
          api_base: ${LLM_API_BASE}
          # llama.cpp 는 키를 검사하지 않지만 클라이언트가 빈 값을 거부합니다.
          api_key: not-needed
          # CPU 추론이라 느립니다. 기본 타임아웃이면 긴 응답에서 잘립니다.
          timeout: 600
          stream_timeout: 600

    litellm_settings:
      telemetry: false
      drop_params: true
      request_timeout: 600

    general_settings:
      # 랩이라 DB 없이 config 파일만으로 돕니다.
      # 키 관리나 예산 기능을 쓰려면 Postgres 가 필요합니다.
      master_key: os.environ/LITELLM_MASTER_KEY
---
apiVersion: v1
kind: Secret
metadata:
  name: litellm-secret
  namespace: ${AGENT_NAMESPACE}
type: Opaque
stringData:
  # 랩용 고정 키입니다. 아무나 부르게 두면 검증이 흐려집니다.
  master-key: sk-agent-lab
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: ${AGENT_NAMESPACE}
  labels:
    app: litellm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: litellm
  template:
    metadata:
      labels:
        app: litellm
      annotations:
        # ConfigMap 이 바뀌어도 Deployment 는 자동으로 재기동하지 않습니다.
        # 백엔드를 바꾸고 나서 "왜 안 바뀌지" 하는 자리가 여기입니다.
        # switch-backend.sh 는 이 값을 갱신해서 롤아웃을 강제합니다.
        lab.local/config-revision: "1"
    spec:
      containers:
        - name: litellm
          image: ${IMAGE_LITELLM}
          args:
            - --config
            - /etc/litellm/config.yaml
            - --host
            - 0.0.0.0
            - --port
            - "4000"
          ports:
            - name: http
              containerPort: 4000
          env:
            # True 면 패키지에 들어 있는 가격표 사본을 씁니다.
            # False 면 기동할 때 GitHub 로 나갑니다. 폐쇄망에서 1번 함정입니다.
            - name: LITELLM_LOCAL_MODEL_COST_MAP
              value: "${LITELLM_COST_MAP}"
            - name: LITELLM_MASTER_KEY
              valueFrom:
                secretKeyRef:
                  name: litellm-secret
                  key: master-key
            # 텔레메트리는 인터넷이 있든 없든 끕니다.
            # 이건 폐쇄망 대응이 아니라 그냥 안 보내는 게 맞아서입니다.
            - name: DO_NOT_TRACK
              value: "1"
            - name: HF_HUB_OFFLINE
              value: "${HF_OFFLINE}"
            - name: TRANSFORMERS_OFFLINE
              value: "${HF_OFFLINE}"
          readinessProbe:
            httpGet:
              path: /health/liveliness
              port: http
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 20
          resources:
            requests:
              cpu: 100m
              memory: 1Gi
            limits:
              cpu: "1"
              # 1Gi 로 뒀다가 기동 7초 만에 OOMKilled(exit 137) 났습니다.
              # LiteLLM 은 import 시점에 프로바이더 모듈을 전부 로드해서
              # 요청을 한 번도 안 받아도 1GB 를 넘깁니다.
              # 로그가 한 줄도 안 남고 죽어서 원인이 안 보입니다.
              # 그때는 컨테이너 상태의 lastState.terminated.reason 을 보세요.
              memory: 2Gi
          volumeMounts:
            - name: config
              mountPath: /etc/litellm
              readOnly: true
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
      volumes:
        - name: config
          configMap:
            name: litellm-config
---
apiVersion: v1
kind: Service
metadata:
  name: litellm
  namespace: ${AGENT_NAMESPACE}
spec:
  selector:
    app: litellm
  ports:
    - name: http
      port: 4000
      targetPort: http
