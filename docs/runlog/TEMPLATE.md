# 실행 기록 양식

`scripts/runlog.sh new <phase>` 가 이 형식으로 파일을 만듭니다.
손으로 쓸 일이 있을 때 참고용으로 남겨 둡니다.
이 파일 자체는 `runlog.sh list` 에서 제외됩니다.

## 왜 남기나

이 랩은 만들었다 지웠다를 반복하고, 그동안 시간당 과금이 계속 돕니다.
2회차에 반드시 다시 찾게 되는 것이 세 가지입니다.

1. **AWS 리소스 ID** - `destroy-cluster.sh` 가 실패했을 때 손으로 지울 목록이 됩니다. 방치된 NAT Gateway 하나가 한 달에 $32이고, GPU 노드 하나는 $600입니다.
2. **실패한 명령과 그 출력** - 설치 실패는 40분 뒤에 드러나고, 그때 본 화면이 유일한 단서입니다.
3. **시작과 종료 시각** - 이 실습이 실제로 얼마를 썼는지. `runlog.sh done` 이 프로파일 단가와 GPU 노드 수를 보고 계산해 줍니다.

터미널 스크롤백은 2회차쯤이면 이미 사라져 있습니다.

## 무엇을 남기지 않나

- 시크릿. 이 파일들은 커밋됩니다. pull secret, kubeconfig 내용, LiteLLM master key 는 절대 넣지 마세요.
- AWS 액세스 키. `aws sts get-caller-identity` 출력에 계정 ID 가 들어가는 것까지는 괜찮지만 키는 안 됩니다.
- 성공한 명령의 전체 출력. `runlog.sh run` 이 120줄을 넘으면 알아서 앞뒤만 남깁니다.

## 단계 이름

스크립트 이름과 맞춥니다. 그래야 파일명만 보고 무슨 일이 있었는지 압니다.

| phase | 대응 스크립트 |
| --- | --- |
| `00-preflight` | `preflight.sh`, `setup-budget.sh` |
| `01-install` | `render-config.sh`, `create-cluster.sh` |
| `02-agent-stack` | `render-manifests.sh`, `deploy-agent-stack.sh` |
| `03-gpu` | `gpu-node.sh up`, `install-rhoai.sh gpu` |
| `04-rhoai` | `install-rhoai.sh rhoai` |
| `05-model` | `deploy-model.sh`, `switch-backend.sh` |
| `06-verify` | `verify-agent-stack.sh` |
| `09-destroy` | `gpu-node.sh down`, `destroy-cluster.sh`, `verify-clean.sh` |

---

## 생성되는 파일 형태

아래는 `runlog.sh` 가 만드는 파일의 예시입니다.
문서 구조가 꼬이지 않게(그리고 h1 이 둘이 되지 않게) 코드블록으로 감싸 두었습니다.
손으로 쓸 일이 있으면 이 블록을 그대로 복사하세요.

````markdown
# ai 프로파일 설치

- **단계**: `01-install`
- **시작**: 2026-08-16 14:02:03 KST
- **실행자**: kiyeon
- **리전 / AZ**: ap-northeast-2 / ap-northeast-2a
- **프로파일**: ai (시간당 약 $1.52)
- **클러스터**: lab1.ocp.example.com (OCP 4.22.6)
- **AWS 프로파일**: ocp-lab
- **커밋**: `abc1234`

## 만들어진 리소스

| 종류 | ID | 설명 | 시각 |
| --- | --- | --- | --- |
| `infra` | `lab1-k6s9t` | infraID. destroy 의 기준 | 14:05:11 |
| `natgw` | `nat-0e1f5805e6df7744e` | 단일 AZ, 1개 | 14:12:40 |
| `machineset` | `lab1-k6s9t-gpu-ap-northeast-2a` | g6.xlarge, replicas=1 | 15:40:02 |

## 기록

- `14:03:10` preflight 통과. G/VT 쿼터 32 확인
- `14:05:11` create-cluster 시작

<details>
<summary><code>./scripts/create-cluster.sh</code> - OK (2612s)</summary>

```text
INFO Waiting up to 40m0s for bootstrap-complete...
INFO Install complete!
```

</details>

## 마무리

- **종료**: 2026-08-16 19:20:44 KST
- **결과**: ok
- **소요**: 18821초 (5.23시간)
- **추정 비용**: 약 $12.29 (시간당 $2.35 = ai 프로파일 + GPU 1대)

### 다음에 다르게 할 것

- GPU 를 설치 직후에 붙였는데 실제로 쓴 건 마지막 1시간뿐이었다. 다음엔 `deploy-model.sh` 직전에 `gpu-node.sh up`
````
