# 화면으로 보는 랩 가이드

이 폴더는 **실제로 떠 있는 클러스터를 브라우저로 찍은 스크린샷**과 그 설명입니다.

[README.md](../../README.md) 는 구조와 이유를 설명합니다.
여기는 "그래서 화면에서 무엇을 보게 되는가" 를 담습니다.
처음 따라 하는 사람이 각 단계 끝에서 자기 화면과 대조할 수 있게 하는 것이 목적입니다.

## 읽는 법

각 항목은 이렇게 구성됩니다.

- 확인 시점 - 어느 단계를 마친 뒤에 보는 화면인지
- 판정 기준 - 이 화면에서 눈으로 확인할 것
- 어긋나면 - 다를 때 어디를 보는지

## 세대가 바뀌면

스크린샷 안의 클러스터 도메인과 파드 이름은 **그 세대의 것**입니다.
재설치하면 `infraID` 가 바뀌고 파드 이름도 전부 바뀝니다.

바뀌는 값은 대조 대상이 아닙니다.
**화면의 구조와 상태 표시가 대조 대상입니다.**
`Running` 인지, 항목이 몇 개인지, 어떤 탭이 있는지를 보세요.

세대별 실제 ID 와 엔드포인트는 [docs/snapshots/](../snapshots/) 에 있습니다.
이 스냅샷들은 `lab1-cxfgs` 세대(OCP 4.22.6 / RHOAI 3.4.3)에서 찍었습니다.

---

## 1. 앱 런처 - 이 랩의 입구

![앱 런처](images/01-app-launcher.jpg)

확인 시점: `deploy-agent-stack.sh` 와 `70-console` 매니페스트 적용 후.

콘솔 오른쪽 위 격자 아이콘을 누르면 나옵니다.

이 화면에서 확인할 것들입니다.

- `AI 랩` 섹션이 있고 항목이 5개입니다.
  LangGraph agent / LiteLLM / Open WebUI / Phoenix / 코딩 에이전트
- 그 아래 `OpenShift Self Managed Services` 에 `Red Hat OpenShift AI` 가 있습니다.
  이건 우리가 만든 게 아니라 RHOAI 가 설치되면서 스스로 등록한 `rhodslink` 입니다.
- 오른쪽 위 사용자 이름이 `kube:admin` 이 아니라 `devuser` 입니다.
  IdP 가 붙었다는 뜻입니다.

**여기가 이 랩의 "홈 화면" 입니다.**
별도 포털을 만들지 않은 이유는 [consolelinks.yaml.tpl](../../manifests/70-console/consolelinks.yaml.tpl) 주석에 적어 두었습니다.

어긋나면: `oc get consolelink` 로 등록 여부를 봅니다.
브라우저 캐시 때문에 안 보일 때가 있어 새로고침을 한 번 하세요.

---

## 2. agent 스택 파드 - 사이드카가 눈에 보입니다

![agent-lab 파드](images/02-agent-lab-pods.jpg)

확인 시점: `deploy-agent-stack.sh` 이후. `verify-agent-stack.sh` 가 통과한 상태입니다.

이 화면에서 확인할 것들입니다.

Ready 열의 숫자가 이 랩의 SSO 설계를 그대로 보여 줍니다.

| 파드 | Ready | 왜 |
| --- | --- | --- |
| `langgraph` | **2/2** | 앱 + oauth-proxy |
| `open-webui` | **2/2** | 앱 + oauth-proxy |
| `phoenix` | **2/2** | 앱 + oauth-proxy |
| `litellm` | 1/1 | API 라 마스터 키로 지킵니다. oauth-proxy 를 붙이면 CLI 가 못 씁니다 |
| `llama-cpp` | 1/1 | 내부 전용. Route 없음 |
| `qdrant` | 1/1 | 내부 전용 |
| `coding-agent` | 1/1 | 웹 서버가 아닙니다. `oc rsh` 로 씁니다 |

`coding-agent-N-build` 가 `Completed` 로 남아 있는 것은 정상입니다.
이미지 빌드 기록이라 지워도 됩니다.

어긋나면: 2/2 여야 할 것이 1/1 이면 매니페스트를 다시 적용하지 않은 것입니다.
`rollout restart` 는 spec 을 바꾸지 않습니다.
`render-manifests.sh` 후 `oc apply` 까지 해야 합니다.

---

## 3. SSO 가 걸린 화면

![Phoenix SSO](images/03-phoenix-sso.jpg)

확인 시점: Phoenix / Open WebUI / LangGraph 에 접속했을 때. 로그인 세션이 없으면 이게 먼저 나옵니다.

이 화면에서 확인할 것들입니다.

- `Log in with OpenShift` 버튼
- 아래에 작게 **`Secured with OpenShift oauth-proxy`**

이 두 줄이 "앱 앞에 인증이 걸렸다" 의 증거입니다.

Phoenix 는 원래 로그인 개념이 없는 도구입니다.
붙이기 전에는 인증 없이 이만큼 됐습니다.

```text
/            200
/graphql     200   트레이스 전문 조회
/v1/traces   200   트레이스 주입까지 가능
```

프롬프트와 응답 전문이 쌓이는 곳이라 그대로 두면 안 됩니다.

어긋나면: 이 화면 없이 앱이 바로 열리면 프록시를 안 거친 것입니다.
`verify-agent-stack.sh 5` 가 이걸 검사합니다.
반대로 로그인 후에도 403 이면 `system:auth-delegator` ClusterRoleBinding 이 없는 경우입니다.

---

## 4. 노드 - 무엇이 어디서 도는가

![노드 목록](images/04-nodes.jpg)

확인 시점: 아무 때나. GPU 를 올리기 전후로 비교하면 좋습니다.

이 화면에서 확인할 것들입니다.

- 노드 6개. 마스터 3 + 워커 3 입니다.
- `Machine set` 열이 출처를 말해 줍니다.
  `CPMS cluster` 는 컨트롤 플레인(ControlPlaneMachineSet),
  `MS lab1-...-worker-us-east-1a` 는 워커입니다.
- 워커는 8 cores / 30.83 GiB, 마스터는 4 cores / 15.35 GiB 입니다.
  `ai` 프로파일이 워커를 크게 잡은 결과입니다. RHOAI 대시보드가 이걸 요구합니다.
- 이름이 전부 `ip-10-0-*` 입니다. **프라이빗 서브넷의 사설 IP 입니다.**
  퍼블릭 IP 를 가진 노드가 하나도 없다는 뜻입니다.

**GPU 를 올리면** `lab1-...-gpu-us-east-1a` MachineSet 에서 노드가 하나 더 생깁니다.
지금 화면에 없는 이유는 `gpu-node.sh down` 으로 반납했기 때문입니다.

---

## 아직 못 찍은 화면

- **RHOAI 대시보드**: `rhods-dashboard-...apps` 는 브라우저에서 인증서 경고가 먼저 뜹니다.
  `*.apps` 인증서는 클러스터 ingress CA 가 서명한 것이라 시스템 신뢰 저장소에 없습니다.
  호스트마다 한 번씩 예외를 승인해야 합니다. `curl` 로 확인할 때 `-k` 가 필요한 것과 같은 이유입니다.
- **파이프라인 실행 그래프**: RHOAI 대시보드 안에 있어 위와 같은 이유로 보류했습니다.
- **콘솔 파드 터미널**: 처음 열면 검은 화면입니다. 콘솔 버그이고 `Expand` 를 누르면 나옵니다.
  자세한 것은 [README 트러블슈팅](../../README.md#트러블슈팅) 에 있습니다.
