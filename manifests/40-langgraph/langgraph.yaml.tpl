# LangGraph 로 만든 agent 를 클러스터 안에서 서빙합니다.
#
# ------------------------------------------------------------------
# aider 와 무엇이 다른가
# ------------------------------------------------------------------
# aider 는 남이 만든 완성품입니다. 우리는 base_url 만 꽂았습니다.
# LangGraph 는 우리가 그래프를 직접 짜서 도는 agent 를 만듭니다.
#
# 그래서 이쪽에서만 보이는 것들이 있습니다.
#   - 상태(state)를 어디에 두는가. 대화가 끊겼다 이어질 때 무엇이 남는가
#   - 툴 호출 루프가 실제로 몇 번 도는가
#   - 실패했을 때 어느 노드에서 멈췄는가
#
# ------------------------------------------------------------------
# 체크포인터를 왜 넣나
# ------------------------------------------------------------------
# LangGraph 의 핵심은 그래프가 아니라 상태입니다.
# 체크포인터가 없으면 파드가 죽는 순간 진행 중이던 대화가 통째로 사라집니다.
# 데모에서는 안 보이고, 실제로 쓰기 시작하면 바로 문제가 됩니다.
#
# 여기서는 PVC 에 SQLite 로 둡니다. 랩 규모에 맞고 외부 의존이 없습니다.
# 실제 환경이라면 Postgres 입니다. 여러 replica 가 같은 상태를 봐야 하니까요.
# PVC 가 RWO 라 replica 를 늘릴 수 없다는 점이 그 제약을 그대로 보여줍니다.
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
  name: langgraph-sso
  namespace: ${AGENT_NAMESPACE}
  annotations:
    serviceaccounts.openshift.io/oauth-redirectreference.primary: >-
      {"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"langgraph"}}
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
  name: langgraph-sso-auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: langgraph-sso
    namespace: ${AGENT_NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: langgraph-oauth-cookie
  namespace: ${AGENT_NAMESPACE}
type: Opaque
stringData:
  # 세션 쿠키 서명 키. 랩용 고정값입니다.
  session_secret: lab-cookie-secret-not-random
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: langgraph-state
  namespace: ${AGENT_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: langgraph-app
  namespace: ${AGENT_NAMESPACE}
data:
  app.py: |
    """LiteLLM 을 백엔드로 쓰는 최소 ReAct agent.

    도구가 둘 있습니다.
      calculator  - 순수 계산. 툴 호출이 도는지 확인용
      qdrant_search - 이미 떠 있는 벡터 DB 조회. 외부 시스템 연동 확인용

    OpenAI 호환이므로 모델을 바꿔도 코드가 안 바뀝니다.
    LiteLLM 의 model 이름만 갈아끼우면 CPU <-> GPU 가 바뀝니다.
    """
    import os, json, sqlite3, operator
    from typing import Annotated, TypedDict

    import httpx
    from fastapi import FastAPI
    from pydantic import BaseModel
    from langchain_core.messages import BaseMessage, HumanMessage, ToolMessage
    from langchain_core.tools import tool
    from langchain_openai import ChatOpenAI
    from langgraph.graph import StateGraph, END
    from langgraph.checkpoint.sqlite import SqliteSaver

    MODEL = os.environ.get("AGENT_MODEL", "qwen25-coder-7b")
    BASE = os.environ["OPENAI_API_BASE"]
    KEY = os.environ["OPENAI_API_KEY"]
    QDRANT = os.environ.get("QDRANT_URL", "http://qdrant:6333")
    STATE_DB = os.environ.get("STATE_DB", "/state/checkpoints.sqlite")

    @tool
    def calculator(expression: str) -> str:
        """Evaluate a simple arithmetic expression like '12 * 7 + 3'."""
        allowed = set("0123456789+-*/(). ")
        if not set(expression) <= allowed:
            return "error: only digits and + - * / ( ) are allowed"
        try:
            return str(eval(expression, {"__builtins__": {}}, {}))
        except Exception as e:
            return f"error: {e}"

    @tool
    def qdrant_collections(_: str = "") -> str:
        """List collections in the cluster's Qdrant vector database."""
        try:
            r = httpx.get(f"{QDRANT}/collections", timeout=10)
            return json.dumps(r.json().get("result", {}))
        except Exception as e:
            return f"error: {e}"

    TOOLS = [calculator, qdrant_collections]
    BY_NAME = {t.name: t for t in TOOLS}

    llm = ChatOpenAI(
        model=MODEL, base_url=BASE, api_key=KEY,
        temperature=0, timeout=300,
    ).bind_tools(TOOLS)

    class State(TypedDict):
        messages: Annotated[list[BaseMessage], operator.add]

    def call_model(state: State):
        return {"messages": [llm.invoke(state["messages"])]}

    def call_tools(state: State):
        last = state["messages"][-1]
        out = []
        for c in last.tool_calls:
            fn = BY_NAME.get(c["name"])
            result = fn.invoke(c["args"]) if fn else f"error: unknown tool {c['name']}"
            out.append(ToolMessage(content=str(result), tool_call_id=c["id"]))
        return {"messages": out}

    def should_continue(state: State):
        last = state["messages"][-1]
        return "tools" if getattr(last, "tool_calls", None) else END

    g = StateGraph(State)
    g.add_node("model", call_model)
    g.add_node("tools", call_tools)
    g.set_entry_point("model")
    g.add_conditional_edges("model", should_continue, {"tools": "tools", END: END})
    g.add_edge("tools", "model")

    conn = sqlite3.connect(STATE_DB, check_same_thread=False)
    graph = g.compile(checkpointer=SqliteSaver(conn))

    app = FastAPI(title="langgraph-agent")

    class Ask(BaseModel):
        message: str
        thread_id: str = "default"

    @app.get("/healthz")
    def healthz():
        return {"ok": True, "model": MODEL}

    @app.post("/chat")
    def chat(a: Ask):
        cfg = {"configurable": {"thread_id": a.thread_id}}
        res = graph.invoke({"messages": [HumanMessage(content=a.message)]}, cfg)
        msgs = res["messages"]
        return {
            "reply": msgs[-1].content,
            "turns": len(msgs),
            "tool_calls": [
                c["name"] for m in msgs for c in getattr(m, "tool_calls", []) or []
            ],
        }

    @app.get("/history/{thread_id}")
    def history(thread_id: str):
        """체크포인터가 실제로 상태를 들고 있는지 확인용."""
        cfg = {"configurable": {"thread_id": thread_id}}
        st = graph.get_state(cfg)
        return {"messages": [f"{type(m).__name__}: {str(m.content)[:120]}"
                             for m in st.values.get("messages", [])]}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: langgraph
  namespace: ${AGENT_NAMESPACE}
  labels:
    app: langgraph
spec:
  replicas: 1
  strategy:
    # SQLite 체크포인터가 RWO PVC 에 있어서 두 파드가 같이 못 붙습니다.
    # Postgres 로 바꾸면 이 제약이 사라집니다.
    type: Recreate
  selector:
    matchLabels:
      app: langgraph
  template:
    metadata:
      labels:
        app: langgraph
    spec:
      serviceAccountName: langgraph-sso
      containers:
        - name: langgraph
          image: ${IMAGE_PYTHON}
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              pip install --no-cache-dir -q \
                langgraph langchain-openai langgraph-checkpoint-sqlite \
                fastapi uvicorn httpx
              exec uvicorn app:app --host 0.0.0.0 --port 8000 --app-dir /app
          env:
            # agent 스택의 다른 것들과 같은 게이트웨이를 씁니다.
            - name: OPENAI_API_BASE
              value: "http://litellm.${AGENT_NAMESPACE}.svc.cluster.local:4000/v1"
            - name: OPENAI_API_KEY
              valueFrom:
                secretKeyRef:
                  name: litellm-secret
                  key: master-key
            # GPU 가 없으면 이 모델이 500 을 냅니다.
            # 그때는 AGENT_MODEL 을 ${MODEL_NAME} 으로 바꾸면 CPU 로 돕니다.
            # 다만 1.5B 는 툴 호출 루프를 안정적으로 못 돕니다.
            - name: AGENT_MODEL
              value: "${VLLM_MODEL_NAME}"
            - name: QDRANT_URL
              value: "http://qdrant:6333"
            - name: STATE_DB
              value: "/state/checkpoints.sqlite"
            - name: HOME
              value: /tmp
            - name: PIP_CACHE_DIR
              value: /tmp/pip
          ports:
            - name: http
              containerPort: 8000
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 40
            periodSeconds: 10
            failureThreshold: 40
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 2Gi
          volumeMounts:
            - name: app
              mountPath: /app
            - name: state
              mountPath: /state
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
            - --openshift-service-account=langgraph-sso
            - --upstream=http://localhost:8000
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
            secretName: langgraph-tls
        - name: proxy-cookie
          secret:
            secretName: langgraph-oauth-cookie
        - name: app
          configMap:
            name: langgraph-app
        - name: state
          persistentVolumeClaim:
            claimName: langgraph-state
---
apiVersion: v1
kind: Service
metadata:
  name: langgraph
  namespace: ${AGENT_NAMESPACE}
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: langgraph-tls
spec:
  selector:
    app: langgraph
  ports:
    - name: https
      port: 8443
      targetPort: https
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: langgraph
  namespace: ${AGENT_NAMESPACE}
spec:
  host: agent.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
  to:
    kind: Service
    name: langgraph
  port:
    targetPort: https
  tls:
    # oauth-proxy 가 TLS 를 직접 종료하므로 라우터는 재암호화해서 넘깁니다.
    # edge 로 두면 라우터-파드 구간이 평문이 되고 oauth-proxy 가 거부합니다.
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
