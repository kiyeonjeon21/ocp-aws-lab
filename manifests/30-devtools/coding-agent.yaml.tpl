# 클러스터 안에서 도는 코딩 에이전트 작업공간.
#
# ------------------------------------------------------------------
# 왜 클러스터 안인가
# ------------------------------------------------------------------
# 코딩 에이전트를 노트북에서 돌리고 base_url 만 클러스터로 돌려도 동작합니다.
# 하지만 고객사 폐쇄망에서는 그게 안 되는 경우가 많습니다.
#   - 개발자 노트북에 도구 설치가 금지됨
#   - 접근 경로가 VDI 하나뿐
#   - 소스가 클러스터 밖으로 나가면 안 됨
#
# 그래서 "개발 환경 자체가 클러스터 안" 이 실제로 요구되는 그림입니다.
# 이 파드가 그 최소 형태입니다.
#
# ------------------------------------------------------------------
# 아키텍처는 바뀌지 않습니다
# ------------------------------------------------------------------
# LiteLLM 이 OpenAI 호환이라 base_url 과 키만 주면 끝입니다.
# 그리고 여기서는 Route 를 안 거칩니다. Service DNS 로 바로 갑니다.
#
#   http://litellm.agent-lab.svc.cluster.local:4000/v1
#
# 트래픽이 클러스터 밖으로 한 발짝도 안 나갑니다.
# 폐쇄망에서 원하는 게 정확히 이것입니다.
#
# ------------------------------------------------------------------
# 쓰는 법
# ------------------------------------------------------------------
#   oc rsh -n ${AGENT_NAMESPACE} deploy/coding-agent
#   cd /workspace && aider --model openai/${VLLM_MODEL_NAME}
#
# aider 를 고른 이유는 내부적으로 LiteLLM 을 쓰기 때문입니다.
# Continue.dev, Cline, OpenCode 도 같은 두 값만 받으므로 그대로 바꿔 끼울 수 있습니다.
# Windsurf 와 Cursor 는 인덱싱과 일부 추론을 자기네 클라우드에서 해서 폐쇄망에서 반쪽만 됩니다.
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: coding-agent-workspace
  namespace: ${AGENT_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coding-agent
  namespace: ${AGENT_NAMESPACE}
  labels:
    app: coding-agent
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: coding-agent
  template:
    metadata:
      labels:
        app: coding-agent
    spec:
      containers:
        - name: workspace
          image: ${IMAGE_DEVTOOLS}
          # 파드를 살려두기만 하고 실제 작업은 oc rsh 로 들어가서 합니다.
          # 에이전트를 entrypoint 로 띄우면 대화형 세션을 붙일 수 없습니다.
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              # 배정된 UID 를 /etc/passwd 에 넣습니다.
              # 이게 없으면 tmux 가 getpwuid() 실패로 조용히 죽습니다.
              command -v fix-uid >/dev/null 2>&1 && fix-uid true || true
              # build-devimage.sh 로 만든 이미지면 도구가 이미 들어 있습니다.
              # 아직 안 만들었으면 aider 만 런타임에 받아 최소한 동작하게 합니다.
              if ! command -v aider >/dev/null 2>&1; then
                echo "aider 가 이미지에 없습니다. 런타임 설치 (build-devimage.sh 를 권합니다)"
                pip install --no-cache-dir -q aider-chat
              fi
              echo "=== 준비된 도구 ==="
              for c in nvim tmux rg fd git aider; do
                printf '  %-6s %s\n' "$c" "$(command -v $c 2>/dev/null || echo 없음)"
              done
              echo
              echo "oc rsh -n ${AGENT_NAMESPACE} deploy/coding-agent 로 들어오세요."
              echo "LazyVim 첫 설치: lazyvim-init"
              sleep infinity
          env:
            # ------------------------------------------------------
            # 이 세 줄이 연결의 전부입니다
            # ------------------------------------------------------
            # Route 가 아니라 Service DNS 입니다. 클러스터 밖으로 안 나갑니다.
            - name: OPENAI_API_BASE
              value: "http://litellm.${AGENT_NAMESPACE}.svc.cluster.local:4000/v1"
            - name: OPENAI_API_KEY
              valueFrom:
                secretKeyRef:
                  name: litellm-secret
                  key: master-key
            - name: AIDER_MODEL
              value: "openai/${VLLM_MODEL_NAME}"

            # OCP 는 임의 UID 로 돌리므로 HOME 이 / 로 잡힙니다.
            # 그대로 두면 pip 도 aider 도 설정 파일을 못 써서 죽습니다.
            - name: HOME
              value: /workspace
            - name: PIP_CACHE_DIR
              value: /workspace/.pip
            # aider 가 기동 시 PyPI 로 버전 확인을 나갑니다. 폐쇄망에서는 지연이 됩니다.
            - name: AIDER_CHECK_UPDATE
              value: "false"
            # 분석 데이터 전송을 끕니다.
            - name: AIDER_ANALYTICS
              value: "false"
            # git 이 없는 디렉토리에서도 뜨게 합니다.
            - name: AIDER_GITIGNORE
              value: "false"
          workingDir: /workspace
          volumeMounts:
            - name: workspace
              mountPath: /workspace
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 2Gi
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
      volumes:
        - name: workspace
          persistentVolumeClaim:
            claimName: coding-agent-workspace
