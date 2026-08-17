# ocp-aws-lab

AWS 에 OpenShift 를 IPI 로 설치하고, 그 위에 agent 스택과 Red Hat OpenShift AI 를 올려 보고, 깨끗하게 지우는 실습 레포입니다.

배경과 전체 그림은 [README.md](README.md) 에 있습니다.
이 파일은 **이 레포에서 작업할 때 지켜야 하는 규칙**만 담습니다.

폐쇄망 버전은 [ocp-airgap-lab](https://github.com/kiyeonjeon21/ocp-airgap-lab) 입니다.
같은 스택을 인터넷 없는 환경에 올립니다. 두 레포는 짝으로 봐야 의미가 있습니다.

---

## 1. 실행 기록은 선택이 아닙니다

**AWS 리소스를 만들거나 지우거나 클러스터 상태를 바꾸는 작업은 반드시 실행 기록을 연 상태에서 합니다.**

```bash
./scripts/runlog.sh new 01-install "ai 프로파일 설치"
```

이유는 세 가지입니다.

1. `destroy-cluster.sh` 가 실패했을 때 손으로 지울 목록이 필요합니다. 방치된 NAT Gateway 하나가 한 달에 $32이고, GPU 노드 하나는 $600입니다.
2. 설치 실패는 40분 뒤에 드러납니다. 그때 본 화면이 유일한 단서입니다.
3. 이 랩은 만들었다 지웠다를 반복합니다. 2회차에 터미널 스크롤백은 이미 사라져 있습니다.

### 기록 규칙

| 상황 | 해야 할 것 |
| --- | --- |
| AWS 리소스를 만들었을 때 | `./scripts/runlog.sh res <종류> <ID> "<설명>"` 을 **즉시** 실행 |
| AWS 나 클러스터를 바꾸는 명령을 실행할 때 | `./scripts/runlog.sh run -- <명령>` 으로 감싸서 실행 |
| 판단이나 우회를 했을 때 | `./scripts/runlog.sh note "<무엇을 왜>"` |
| 단계가 끝났을 때 | `./scripts/runlog.sh done ok\|fail\|partial` |

`run --` 으로 감싸면 출력과 종료 코드까지 기록에 남습니다.
실패한 명령은 접히지 않고 펼쳐진 채로 남습니다. 나중에 다시 볼 때 찾는 건 대부분 그쪽이라서입니다.

`done` 은 소요 시간에 프로파일 단가와 살아 있는 GPU 노드 수를 곱해 추정 비용을 계산합니다.
그리고 클러스터가 아직 살아 있으면 경고합니다.

읽기 전용 조회(`aws ec2 describe-*`, `oc get`)까지 감쌀 필요는 없습니다.
기록이 노이즈로 덮이면 아무도 안 읽게 됩니다.

### 반드시 기록해야 하는 것

`infraID` 입니다.
`create-cluster.sh` 직후에 이걸 남기세요.

```bash
./scripts/runlog.sh res infra "$(cluster_infra_id)" "destroy 의 기준"
```

`clusters/<name>/` 를 통째로 잃어버렸을 때, 기록에 남은 `infraID` 가 수동 정리의 유일한 출발점이 됩니다.
`verify-clean.sh` 는 인자로 `infraID` 를 받습니다.

### 기록에 넣으면 안 되는 것

`docs/runlog/` 는 커밋됩니다.

- pull secret, kubeconfig 내용, LiteLLM master key
- AWS 액세스 키 (계정 ID 는 괜찮습니다)
- 성공한 명령의 전체 출력 (`runlog.sh run` 이 120줄 넘으면 알아서 앞뒤만 남깁니다)

---

## 2. 환경 로드

**AWS 나 클러스터를 건드리는 모든 명령 앞에 이게 먼저입니다.**

```bash
source scripts/env.sh
```

이 계정에는 다른 프로젝트 IAM 유저가 여럿 있습니다.
`AWS_PROFILE` 없이 실행하면 권한 오류로 끝나면 다행이고, 최악의 경우 의도하지 않은 계정 컨텍스트로 리소스를 건드립니다.

`openshift-install` 은 `.env` 를 읽지 않습니다. AWS SDK 의 기본 프로파일을 씁니다.
`oc` 도 마찬가지로 예전 컨텍스트에 붙을 수 있습니다.

`scripts/*.sh` 는 전부 `lib.sh` 를 source 하고 `load_env` 를 호출하므로 스크립트로 실행할 때는 자동입니다.
클러스터를 건드리는 스크립트는 `need_cluster` 로 `KUBECONFIG` 까지 고정합니다.
**수동으로 `aws` 나 `oc` 를 칠 때가 위험합니다.**

---

## 3. 절대 하면 안 되는 것

| 금지 | 이유 |
| --- | --- |
| `clusters/<name>/` 삭제 | `metadata.json` 이 자동 삭제의 유일한 근거입니다. 지우면 태그로 역추적해 손으로 지워야 합니다 |
| 비용이 나가는 작업을 예상 비용 없이 시작 | 시간당 과금입니다. 시작 전에 "이건 시간당 얼마"를 먼저 말합니다 |
| GPU 노드를 붙여 두고 방치 | 시간당 $0.83입니다. 안 쓰면 `gpu-node.sh down` |
| `clusters/` 아래 렌더링 결과물을 직접 수정 | gitignore 됩니다. `profiles/` 와 `manifests/` 의 템플릿을 고쳐야 합니다 |
| `secrets/`, `clusters/`, `.env` 를 커밋 | `.gitignore` 에 있지만 `git add -f` 로 뚫지 마세요 |
| 오퍼레이터 CR 을 문서에서 베껴 레포에 박기 | 버전마다 필드가 바뀝니다. `alm-examples` 에서 꺼내 쓰세요 (아래 5절) |
| 검증 없이 "됐다"고 보고 | 기준은 `verify-agent-stack.sh` 와 `verify-clean.sh` 통과입니다 |

### 삭제는 세 단계입니다

`destroy-cluster.sh` 하나로 끝났다고 보지 마세요.

```bash
./scripts/destroy-cluster.sh
./scripts/verify-clean.sh        # 이 클러스터가 깨끗이 지워졌나 (infraID 기준)
./scripts/sweep.sh               # 리전에 돈 나가는 게 남았나 (기준 없음)
```

`destroy` 가 놓치는 건 대부분 **클러스터가 동적으로 만든 것**입니다.
Ingress Operator 가 만든 Classic ELB, PVC 가 만든 EBS 볼륨, 프라이빗 호스팅 존(개당 월 $0.50).
agent 스택과 RHOAI 는 PVC 를 여러 개 만들기 때문에 이 랩에서 특히 잘 남습니다.

**세 번째가 반복 실습의 안전장치입니다.**
`verify-clean.sh` 는 `infraID` 가 있어야 제대로 돕니다.
설치가 중간에 깨져 `metadata.json` 이 안 생긴 세대, `clusters/` 를 지워 `infraID` 를 잃은 세대는 그걸로 안 잡힙니다.
`sweep.sh` 는 아무 기준 없이 리전의 과금 리소스를 전부 나열하고 시간당 합계를 냅니다.

**`sweep.sh` 가 "과금 리소스 없음" 이라고 해야 세션이 끝난 것입니다.**

### 반복 실습 루프

이 랩은 만들었다 지웠다를 여러 번 합니다. 매 세션 이 순서를 지키세요.

```bash
source scripts/env.sh
./scripts/sweep.sh                       # 시작 전에도 한 번. 지난 세션 잔여물 확인
./scripts/runlog.sh new 01-install "N회차"

# ... 실습 ...

./scripts/gpu-node.sh down               # GPU 를 썼다면 제일 먼저
./scripts/destroy-cluster.sh
./scripts/verify-clean.sh
./scripts/sweep.sh                       # 깨끗해야 함
./scripts/runlog.sh done ok
git add docs/runlog && git commit -m "runlog: N회차"
```

**시작 전 `sweep.sh` 를 빼먹지 마세요.**
지난 세션의 잔여물을 이번 세션 것으로 착각하면, 세션이 끝나고 "원래 있던 건가" 하며 넘어가게 됩니다.
시작 시점의 기준선을 알아야 끝에서 비교가 됩니다.

세션 중에 `./scripts/snapshot.sh` 를 한 번 돌려 두세요.
`docs/snapshots/<날짜>-<infraID>.md` 에 그 세대의 ID·엔드포인트·버전이 남습니다.
infraID 가 파일 이름에 들어가므로 세대끼리 덮어쓰지 않고, 두 세대를 diff 하면 무엇이 달라졌는지 보입니다.

**세대마다 바뀌는 값을 README 에 적지 마세요.** 다음 세대에 전부 거짓말이 됩니다.
구조와 포트는 README, ID 와 엔드포인트는 스냅샷입니다.

`metadata.json` 백업은 `clusters/_backups/` 에 세대별로 쌓입니다. 지우지 마세요.
`create-cluster.sh` 가 종료 시 백업하면서 열려 있는 실행 기록에 `infraID` 도 자동으로 적습니다.

---

## 4. 작업 흐름

번호가 곧 순서이고, 각 단계는 독립적으로 다시 돌릴 수 있어야 합니다.

```text
0. preflight.sh          쿼터/AZ 재고/DNS 위임/pull secret. 돈 나가기 전에 막을 것들
1. render-config.sh      profiles/*.tpl -> install-config.yaml
   create-cluster.sh     설치 ~40분. 여기서부터 과금
2. render-manifests.sh   manifests/*.tpl -> clusters/<name>/manifests/
   deploy-agent-stack.sh llama.cpp · LiteLLM · Qdrant · Open WebUI · Phoenix
3. install-rhoai.sh rhoai  Operator + DataScienceCluster. GPU 없이 됩니다
   install-rhoai.sh distributed  Ray · Kueue · TrainingOperator. 이것도 GPU 없이 됩니다
4. gpu-node.sh up        GPU MachineSet. 여기서부터 +$0.83/h
   install-rhoai.sh gpu  NFD + NVIDIA GPU Operator. 드라이버 빌드 10~20분
5. deploy-model.sh       가중치 PVC + InferenceService
   switch-backend.sh vllm  LiteLLM api_base 한 줄 교체
6. verify-agent-stack.sh 검증
7. tune.sh run           LoRA 파인튜닝. 서빙을 내리고 GPU 를 씁니다
   tune.sh restore       서빙 복구
9. gpu-node.sh down      GPU 반납
   destroy-cluster.sh    클러스터 삭제
   verify-clean.sh       잔여 리소스 확인
```

**`AZ` 는 설치 후에 못 바꿉니다.**
단일 AZ 로 설치하기 때문입니다.
GPU 를 쓸 계획이면 그 AZ 에 g6 가 있는지 `preflight.sh ai` 가 먼저 확인합니다.
`ap-northeast-2b` 에는 g6 가 없습니다.

**GPU(4번)는 RHOAI 설치(3번) 뒤에 옵니다. 순서를 바꾸지 마세요.**
RHOAI 오퍼레이터 설치는 GPU 를 전혀 쓰지 않습니다.
`distributed` 로 켜는 Ray·Kueue·TrainingOperator 도 마찬가지입니다.
GPU 를 먼저 올려두면 그 30분이 시간당 $0.83 으로 계산됩니다.
GPU 가 실제로 필요한 건 vLLM `InferenceService` 와 학습 잡뿐입니다.

**GPU 한 장은 서빙과 학습이 동시에 못 씁니다.**
`nvidia.com/gpu` 는 나눠 쓸 수 없는 정수 자원입니다. 0.1 장을 요청할 수 없습니다.
`tune.sh run` 이 서빙을 `replicas=0` 으로 내리고 시작하고, 자동으로 되돌리지 않습니다.
**학습이 끝나면 `tune.sh restore` 를 직접 부르세요.** 안 하면 모델 엔드포인트가 죽어 있습니다.

**MaaS 와 llm-d 는 이 랩에서 못 합니다.** 지원 가속기 목록에 L4 가 없습니다.
매번 다시 조사하지 않도록 근거를 [docs/maas-llm-d.md](docs/maas-llm-d.md) 에 적어 두었습니다.

---

## 5. 코드 규칙

### 셸 스크립트

- `scripts/` 는 `lib.sh` 를 source 하고 `load_env` 를 호출합니다.
- 클러스터를 건드리면 `need_cluster` 를 먼저 부릅니다. `KUBECONFIG` 를 고정하지 않으면 다른 클러스터에 apply 할 수 있습니다.
- `set -euo pipefail` 이 기본입니다. 단 개별 검사 실패로 전체가 죽으면 안 되는 검증 스크립트는 `-e` 를 뺍니다.
- 출력은 `lib.sh` 의 `ok` / `warn` / `bad` / `info` / `head1` / `die` 를 씁니다. 직접 `echo` 로 색을 칠하지 마세요.
- **`source` 되는 파일(`lib.sh`, `env.sh`)에 bash 전용 문법을 쓰지 마세요.** 사용자의 로그인 셸은 zsh 이고, `source scripts/env.sh` 는 그쪽으로 들어옵니다. `${BASH_SOURCE[0]}` 하나 때문에 `AWS_PROFILE` 이 조용히 안 잡힌 적이 있습니다. 고칠 때는 zsh 와 bash 양쪽에서 확인하세요.
- 값을 반환하는 함수는 **stdout 에 값만** 냅니다. 진행 표시는 `>&2` 로 보냅니다. `install-rhoai.sh` 의 `wait_csv` 가 그 예입니다.

### 오퍼레이터 CR 은 클러스터에서 꺼냅니다

`DataScienceCluster`, `ClusterPolicy`, `NodeFeatureDiscovery` 는 오퍼레이터 버전마다 필드가 바뀝니다.
문서를 보고 베껴 둔 YAML 은 반년이면 틀립니다.

그래서 이 레포는 **설치된 CSV 의 `alm-examples` 에서 그 버전의 정답을 꺼내 쓰고**, 다르게 하고 싶은 부분만 `jq` 로 덧칠합니다.

같은 이유로 하드코딩하지 않는 것들이 더 있습니다.

| 값 | 어디서 얻나 |
| --- | --- |
| Subscription 채널 | `oc get packagemanifest <pkg> -o jsonpath='{.status.defaultChannel}'` |
| vLLM ServingRuntime 이름 | `ClusterServingRuntime` -> `ServingRuntime` -> RHOAI `Template` 순으로 탐색 |
| GPU MachineSet 의 AMI·서브넷·SG·IAM | 살아 있는 워커 MachineSet 을 복제 |
| StorageClass | `is-default-class` 어노테이션으로 조회 |

**덧칠 대상 경로가 없으면 조용히 넘어가지 말고 경고를 내세요.**
그게 "이 버전에서 뭔가 바뀌었다"는 신호입니다.
`install-rhoai.sh` 의 `patch_or_warn` 이 그 역할입니다.

### 매니페스트

- `manifests/**/*.yaml.tpl` 이 원본입니다. 번호 접두사가 적용 순서입니다.
- **이미지 경로, StorageClass, 오프라인 스위치는 반드시 변수로 뺍니다.** 목표는 `ocp-airgap-lab` 과 템플릿을 바이트 단위로 같게 두고 차이를 `.env` 에만 두는 것입니다.
- 새 컴포넌트를 추가하면 `render-manifests.sh` 의 `VARS` 목록에도 변수를 넣어야 합니다. 안 넣으면 치환 검사에서 걸립니다.
- 셸 변수(`$TARGET`)가 들어가는 스크립트를 매니페스트 안에 쓸 때는 envsubst 목록에 없는 이름을 쓰세요. 목록에 있으면 렌더링 때 날아갑니다.
- YAML 블록 스칼라 안에서 **heredoc 을 쓰지 마세요.** 종료자를 들여쓰면 셸이 인식하지 못합니다. `python -c` 한 줄로 대체하세요.

### 주석

이 레포의 주석은 **무엇을 하는지가 아니라 왜 그런지**를 적습니다.
클라우드 통합이 다 해 주는 부분과 우리가 해야 하는 부분의 경계가 이 랩의 교재입니다.

나쁜 예: `# GPU 노드 생성`
좋은 예: `# 워커 MachineSet 을 복제합니다. AMI 는 RHCOS 버전과 리전에 묶여 있어 문서에서 베껴 올 수 없습니다.`

### 문서

- 한 문장은 한 줄에 씁니다.
- em dash 를 쓰지 않습니다. 일반 하이픈을 씁니다.
- 비용이 바뀌는 변경은 README 의 비용 표와 `lib.sh` 의 `profile_hourly_cost` 를 **같이** 고칩니다. 한쪽만 고치면 runlog 의 추정치가 틀어집니다.

markdownlint 설정은 `.markdownlint.yaml` 에 있고, 현재 위반 0건입니다.

```bash
npx markdownlint-cli2 "**/*.md"
```

`MD013`(줄 길이)과 `MD033`(인라인 HTML)만 꺼져 있습니다.
이유는 설정 파일에 적어 두었습니다.
나머지는 전부 켜져 있으니 새 문서도 통과시켜야 합니다.

표는 `| --- |` 형태(compact)로 통일합니다. `|---|` 로 쓰면 MD060 이 뜹니다.

`runlog.sh` 가 **생성하는** 마크다운도 린트 대상입니다.
블록을 이어 붙일 때는 `append_block` 을 쓰세요. 빈 줄을 손으로 세면 반드시 어긋납니다.

### 스크린샷 가이드 (`docs/guide/`)

화면으로 확인하는 단계를 새로 만들었으면 여기에 항목을 추가합니다.
스크린샷은 `docs/guide/images/NN-이름.jpg`, 설명은 `docs/guide/README.md` 입니다.

- **바뀌는 값을 판정 기준으로 쓰지 마세요.** 파드 이름과 도메인은 세대마다 달라집니다.
  `Running` 인지, 항목이 몇 개인지, `Ready` 가 `2/2` 인지처럼 **구조와 상태**를 기준으로 씁니다.
- 각 항목은 `확인 시점` / `이 화면에서 확인할 것들입니다.` / `어긋나면` 세 부분입니다.
- 비밀번호나 토큰이 찍힌 화면은 넣지 마세요. `docs/` 는 커밋됩니다.
- 인증서 경고나 로그인 화면처럼 **막히는 화면도 가치가 있습니다.** 다들 거기서 멈추기 때문입니다.

### 다이어그램

**README 의 다이어그램은 mermaid 로 그립니다.**
IP·포트·인스턴스 타입이 `.env` 및 `profiles/` 와 맞물려 있어서, diff 에 잡히고 리뷰되는 텍스트여야 합니다.

`docs/` 의 Excalidraw 링크는 `lab1-k6s9t` 스냅샷 보관용입니다.
워크스페이스 권한이 필요해서 외부 독자에게는 안 보입니다. 새로 그리지 마세요.

**`subgraph` 끼리 잇는 엣지를 쓰지 마세요.**

```text
PUBSUB --> PRIVSUB    # 금지. 구버전 mermaid 파서가 거부합니다
WORKER --> PRIVSUB    # 허용. 노드 -> subgraph 는 어디서나 됩니다
```

그 외 확인된 제약:

- **중첩 `subgraph` 를 피하세요.** VPC 안에 서브넷을 넣는 식으로 두 겹을 쓰면 dagre 가 거대한 빈 박스를 만들고 엣지가 화면을 가로지릅니다. CIDR 을 제목에 넣어 평탄화하세요.
- 역방향 엣지를 만들지 마세요. 아웃바운드처럼 아래로 흐르는 것은 아래쪽 `subgraph` 로 빼면 위에서 아래로 정리됩니다.
- `flowchart LR` 은 단계가 5개를 넘으면 README 폭에서 글씨를 못 읽습니다. 세로가 길어도 `TB` 가 낫습니다.
- 라벨이 좁게 잘리면 `%%{init: {"flowchart": {"wrappingWidth": 460}}}%%` 를 첫 줄에 넣으세요. 기본값 200px 때문에 긴 라벨이 "업로 드" 처럼 깨집니다. 파서가 이 지시자를 무시해도 좁아질 뿐 렌더는 됩니다.
- 최종 기준은 GitHub 입니다. push 후 한 번 보세요. 특히 `%%{init}%%` 를 쓴 다이어그램은 반드시 확인하세요.

렌더 확인:

```bash
mmdc -i diagram.mmd -o out.png -b transparent -t dark -s 2
```

**렌더해서 눈으로 보고 고치세요.** 문법이 통과하는 것과 읽히는 것은 다릅니다.

---

## 6. 이 환경에서 자주 틀리는 것

작업하다 막히면 여기부터 보세요.

| 증상 | 원인 |
| --- | --- |
| `openshift-install` 이 엉뚱한 IAM 유저로 붙음 | `source scripts/env.sh` 를 안 했음 |
| `source` 를 했는데도 엉뚱한 유저로 붙음 | 셸 차이. `echo $AWS_PROFILE` 로 확인하세요. `ocp-lab` 이 아니면 로드가 실패한 것입니다 |
| 설치가 bootstrap 에서 멈춤 | 보안 그룹, NAT 접근 불가, Route 53 전파 지연, vCPU 쿼터 |
| GPU MachineSet 을 만들었는데 Machine 이 Provisioning 에서 멈춤 | 그 AZ 에 해당 타입이 없음. `ap-northeast-2b` 에 g6 없음 |
| 노드는 Ready 인데 `nvidia.com/gpu` 가 `<none>` | 드라이버 미완성이거나 NFD 가 라벨을 안 붙임 |
| InferenceService 파드가 Pending | `nvidia.com/gpu` taint 에 대한 toleration 누락 |
| vLLM 이 OOM | `--gpu-memory-utilization` 이 높음. L4 24GB 에 1.5B 면 0.55 |
| PVC 가 조용히 Pending | 기본 StorageClass 없음. AWS IPI 는 `gp3-csi` |
| 파드가 스케줄조차 안 됨 | SCC. 이벤트가 Deployment 가 아니라 ReplicaSet 에 남습니다 |
| ConfigMap 을 바꿨는데 반영이 안 됨 | 파드는 자동으로 다시 읽지 않습니다. `rollout restart` 가 필요합니다 |
| `pip` / `npm` 이 Permission denied | OCP 임의 UID 가 `/` 를 홈으로 잡음. `HOME=/tmp` 를 넣으세요 |
| 컨테이너에서 `whoami` 가 실패 | 임의 UID 가 `/etc/passwd` 에 없음. 기동 시 `fix-uid` 로 넣습니다 |
| 이미지를 다시 빌드했는데 동작이 그대로 | `rollout restart` 는 spec 을 안 바꿉니다. 템플릿을 고쳤으면 `render-manifests.sh` + `oc apply` 까지 |
| 콘솔 파드 Terminal 탭이 새까맣게 빈 화면 | 콘솔(OCP 4.22.6) 버그. xterm 이 1열 1행으로 잡힙니다. `Expand` 를 누르거나 창 크기를 바꾸면 나옵니다. 파드 문제가 아닙니다 |
| RHOAI 대시보드에 학습/Ray 가 안 보임 | 화면이 셋으로 나뉩니다. Pipelines 는 Kubeflow Pipelines, Jobs 는 TrainJob·RayJob, Workload metrics 는 Kueue `Workload`. 우리 것은 세 번째에 있습니다 |
| RHOAI 대시보드 주소를 모르겠음 | 3.4 는 `data-science-gateway` 로 나갑니다. `oc get route -A \| grep data-science-gateway` |
| Jobs 화면이 계속 비어 있음 | `TrainJob` 은 `trainer` 컴포넌트가 필요하고 JobSet 오퍼레이터가 이 카탈로그에 없습니다. `RayCluster` 말고 `RayJob` 을 쓰면 뜹니다 |
| 큐 라벨을 붙였는데 `Workload` 가 안 생김 | `Kueue/cluster` 의 `frameworks` 기본값이 `BatchJob` 하나입니다. PyTorchJob·RayCluster 를 추가해야 합니다 |
| Kueue 가 승인했는데 파드가 Pending | 승인은 스케줄 보장이 아닙니다. Kueue 는 자기가 관리하는 워크로드만 셉니다. Deployment(vLLM 서빙)가 쥔 GPU 는 안 보입니다 |
| destroy 후에도 과금이 계속됨 | Classic ELB, PVC 가 만든 EBS, 프라이빗 존. `verify-clean.sh` |

---

## 7. 보고 규칙

- 검증하지 않은 것을 "됐다"고 하지 않습니다. 이 레포에서 "됐다"의 기준은 `verify-agent-stack.sh` 와 `verify-clean.sh` 통과입니다.
- 실패하면 실패했다고 그대로 말하고 출력을 같이 보여 줍니다.
- 건너뛴 단계가 있으면 명시합니다.
- **AWS 비용이 발생하는 작업을 시작하기 전에 예상 비용을 먼저 말합니다.** 시간당 얼마이고 이 작업이 몇 시간짜리인지.
- 실습이 끝났는데 클러스터가 살아 있으면, 다른 무슨 얘기를 하든 그 사실을 먼저 말합니다.
