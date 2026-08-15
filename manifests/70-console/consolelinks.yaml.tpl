# OCP 콘솔 앱 런처(오른쪽 위 격자 아이콘)에 이 랩의 앱들을 등록합니다.
#
# ------------------------------------------------------------------
# 왜 별도 home 화면을 만들지 않나
# ------------------------------------------------------------------
# "앱이 여러 개인데 입구가 흩어져 있다" 는 문제는 OCP 가 이미 풀어 뒀습니다.
# ConsoleLink 를 만들면 콘솔 앱 런처에 항목이 생깁니다.
#
# RHOAI 도 같은 방식을 씁니다. 설치하면 rhodslink 라는 ConsoleLink 가 생깁니다.
#   $ oc get consolelink
#   rhodslink
#
# 커스텀 홈페이지를 만들면
#   - SSO 를 직접 구현해야 하고
#   - 앱을 추가할 때마다 페이지를 고쳐야 하고
#   - 결국 링크 모음일 뿐이라 인증 문제를 하나도 안 풉니다
# 플랫폼이 주는 걸 다시 만드는 셈입니다.
#
# ------------------------------------------------------------------
# 이 링크들이 의미를 가지려면 SSO 가 먼저입니다
# ------------------------------------------------------------------
# 앱 런처에서 눌렀는데 인증 없이 열리면 그건 그냥 북마크입니다.
# Open WebUI 와 LangGraph 에 oauth-proxy 를 붙여 둔 이유가 그것입니다.
# 콘솔에 로그인한 사용자가 그대로 통과합니다.
---
apiVersion: console.openshift.io/v1
kind: ConsoleLink
metadata:
  name: lab-open-webui
spec:
  location: ApplicationMenu
  text: Open WebUI (채팅)
  href: https://chat.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
  applicationMenu:
    section: AI 랩
    imageURL: https://chat.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/static/favicon.png
---
apiVersion: console.openshift.io/v1
kind: ConsoleLink
metadata:
  name: lab-phoenix
spec:
  location: ApplicationMenu
  text: Phoenix (트레이싱)
  href: https://trace.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
  applicationMenu:
    section: AI 랩
---
apiVersion: console.openshift.io/v1
kind: ConsoleLink
metadata:
  name: lab-langgraph
spec:
  location: ApplicationMenu
  text: LangGraph agent (API)
  href: https://agent.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/docs
  applicationMenu:
    section: AI 랩
---
# LiteLLM 은 API 라 사람이 눌러 볼 화면이 없습니다.
# 그래도 등록해 두면 "이 클러스터의 모델 게이트웨이가 여기" 라는 게 남습니다.
apiVersion: console.openshift.io/v1
kind: ConsoleLink
metadata:
  name: lab-litellm
spec:
  location: ApplicationMenu
  text: LiteLLM (모델 게이트웨이)
  href: https://litellm.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
  applicationMenu:
    section: AI 랩
---
# ------------------------------------------------------------------
# 코딩 에이전트는 웹 앱이 아닙니다
# ------------------------------------------------------------------
# 이건 oc rsh 로 들어가서 쓰는 터미널 워크로드입니다.
# Route 도 oauth-proxy 도 없습니다. 그게 맞습니다.
#   - exec 는 API 서버를 거치므로 이미 인증됩니다(kubeconfig 또는 콘솔 로그인)
#   - pods/exec 권한이 없으면 못 들어옵니다. RBAC 이 그대로 적용됩니다
#   - 웹 서버가 없으니 Route 를 열 이유가 없습니다
#
# 다만 그러면 앱 런처에 안 보여서 아는 사람만 쓰게 됩니다.
# 콘솔의 파드 터미널로 가는 링크를 걸어 발견 가능하게 합니다.
#
# 파드 이름이 아니라 Deployment 경로로 겁니다.
# 파드 이름은 재기동마다 바뀌어서 링크가 금방 깨집니다.
#
# ------------------------------------------------------------------
# 콘솔 Terminal 탭이 빈 화면으로 뜨는 건 콘솔 버그입니다
# ------------------------------------------------------------------
# OCP 4.22.6 의 콘솔 Terminal 탭은 처음 열릴 때 xterm 을 1열 1행으로 잡습니다.
# 셸은 정상으로 붙고 프롬프트 바이트도 도착하는데, 그릴 자리가 없어 새까맣게 보입니다.
#
# 확인한 방법:
#   - 콘솔이 보내는 exec 명령(sh -i -c "TERM=xterm sh")을 pty 로 그대로 재현 -> 프롬프트 정상
#   - 브라우저에서 .xterm-screen 크기 측정 -> 19x19 px, 행 1개
#   - resize 이벤트 하나 -> 1315x567, 27 행, 프롬프트 표시
#   - 우리와 무관한 파드(openshift-console 자신)에서도 동일 -> 이미지 문제가 아님
#
# 화면 오른쪽 위 Expand 를 누르거나 창 크기를 바꾸면 나옵니다.
#
# 애초에 tmux 와 neovim 을 쓸 자리는 아닙니다. 키 조합이 콘솔에 먹힙니다.
# 제대로 쓰려면 로컬 터미널에서:
#   oc rsh deploy/coding-agent
apiVersion: console.openshift.io/v1
kind: ConsoleLink
metadata:
  name: lab-coding-agent
spec:
  location: ApplicationMenu
  text: 코딩 에이전트 (터미널)
  href: https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/k8s/ns/${AGENT_NAMESPACE}/deployments/coding-agent/pods
  applicationMenu:
    section: AI 랩
---
# 네임스페이스 대시보드에도 띄웁니다.
# agent-lab 프로젝트를 보는 사람에게 "이 앱들의 입구가 여기" 를 알려 줍니다.
apiVersion: console.openshift.io/v1
kind: ConsoleLink
metadata:
  name: lab-agent-namespace
spec:
  location: NamespaceDashboard
  text: Open WebUI 열기
  href: https://chat.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
  namespaceDashboard:
    namespaces:
      - ${AGENT_NAMESPACE}
