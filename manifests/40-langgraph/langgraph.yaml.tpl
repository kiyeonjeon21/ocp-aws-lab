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
      volumes:
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
spec:
  selector:
    app: langgraph
  ports:
    - name: http
      port: 8000
      targetPort: http
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
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
