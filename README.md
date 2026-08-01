# ocp-aws-lab

AWS 위에 **OpenShift Container Platform(OCP)** 클러스터를 IPI 방식으로 설치하고, 연습이 끝나면 깨끗하게 지우기 위한 실습 레포입니다.

목표는 세 가지입니다.

1. `openshift-install` 기반 설치를 **반복 가능하게** 만든다
2. 연습용으로 **가장 저렴한 구성**을 기본값으로 둔다
3. 지우는 걸 잊어서 **요금 폭탄을 맞지 않는다**

> ⚠️ 이 레포의 구성은 **학습·평가 전용**입니다. 프로덕션 용도로 그대로 쓰지 마세요. 단일 AZ, 최소 노드, 최소 스토리지로 되어 있어 가용성 보장이 없습니다.

---

## 목차

- [구조 다이어그램](#구조-다이어그램)
- [사전 준비](#사전-준비)
- [빠른 시작](#빠른-시작)
- [프로파일](#프로파일)
- [비용](#비용)
- [클러스터 삭제 (중요)](#클러스터-삭제-중요)
- [라이선스 / 구독](#라이선스--구독)
- [트러블슈팅](#트러블슈팅)
- [디렉토리 구조](#디렉토리-구조)
- [참고 링크](#참고-링크)

---

## 구조 다이어그램

`minimal` 프로파일로 실제 설치했던 클러스터(`lab1-k6s9t`)를 그린 것입니다.
모든 리소스 ID, CIDR, 포트는 CloudTrail과 설치 로그에서 뽑은 실측값입니다.

| 다이어그램 | 무엇을 보여주나 |
|---|---|
| [인프라 배치](https://app.excalidraw.com/s/AU3bkHPBsIE/8sxxVui6XVZ) | VPC, 서브넷, 노드, 로드밸런서, Route 53이 어디에 놓이는지 |
| [트래픽 경로](https://app.excalidraw.com/s/AU3bkHPBsIE/4Gq0Sr9Nsfe) | `oc` 호출, 웹 콘솔, 내부 통신, 아웃바운드 네 갈래 |
| [OCP 논리 구조](https://app.excalidraw.com/s/AU3bkHPBsIE/ApRyIg8PYAP) | AWS를 걷어낸 컨트롤 플레인, 워커, 네트워크 3계층, Machine API |
| [설치·삭제 라이프사이클](https://app.excalidraw.com/s/AU3bkHPBsIE/1FzEkpAa0dX) | 46분 동안 무슨 순서로 생기고 어떻게 사라지는지 |
| [AWS 리소스 전체 인벤토리](https://app.excalidraw.com/s/AU3bkHPBsIE/60CwgVQ29If) | 생성되는 리소스 전부와 과금 대상 구분 |

그림을 보면 알게 되는 것들입니다.

**`api.<cluster>.<baseDomain>`이 조회 위치에 따라 다른 곳을 가리킵니다.**
VPC 밖에서는 퍼블릭 존이 답해 외부 NLB로 가고, VPC 안에서는 프라이빗 존이 답해 내부 NLB로 갑니다.
같은 이름인데 목적지가 다릅니다.

**로드밸런서 3개 중 하나는 인스톨러가 만든 게 아닙니다.**
NLB 2개는 설치 과정에서 생기지만, `*.apps`가 물린 Classic ELB는 설치가 끝난 뒤 Ingress Operator가 Service type=LoadBalancer로 만듭니다.
`verify-clean.sh`가 Classic ELB를 별도로 검사하는 이유입니다.

**아웃바운드 경로가 두 개입니다.**
일반 트래픽은 NAT Gateway를 타지만, S3 행 트래픽은 게이트웨이 VPC 엔드포인트로 빠져서 NAT 데이터 요금($0.045/GB)을 내지 않습니다.

**과금 대상은 네 가지뿐입니다.**
EC2, NAT Gateway, 로드밸런서, EBS입니다.
VPC, 서브넷, IGW, 라우트 테이블, 보안그룹, IAM 롤은 개수가 많아도 전부 무료입니다.

> 다이어그램은 `lab1-k6s9t` 스냅샷입니다.
> destroy 후 재설치하면 구조는 같지만 리소스 ID는 전부 바뀝니다.
> 링크는 Excalidraw 워크스페이스 권한이 필요합니다.

---

## 사전 준비

### 1. AWS

| 항목 | 내용 |
|---|---|
| IAM 권한 | IPI 설치는 광범위한 권한이 필요합니다. 학습용 계정에서 `AdministratorAccess`로 시작하고, 익숙해지면 최소 권한으로 좁히세요 |
| Route 53 | **퍼블릭 호스팅 존이 반드시 필요합니다.** 도메인이 없으면 설치가 진행되지 않습니다 |
| vCPU 쿼터 | 프로파일별 설치 피크: `sno` 12, `minimal` 20, `compact`/`default` 28 (부트스트랩 4 포함). Service Quotas의 `Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances`(`L-1216C47A`)가 이보다 커야 합니다 |
| Elastic IP | 기본 쿼터 5개. 단일 AZ면 문제없지만 멀티 AZ + 다른 리소스가 있으면 부족할 수 있습니다 |
| 리전 | `us-east-1` 권장 (서울 대비 약 20% 저렴, 인스턴스 가용성 우수) |

쿼터 확인:

```bash
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --region us-east-1
```

### 2. Red Hat

- Red Hat 계정 생성
- [60일 self-supported 평가판](https://www.redhat.com/en/technologies/cloud-computing/openshift/ocp-self-managed-trial) 신청 (무료)
- [console.redhat.com](https://console.redhat.com/openshift/install/aws/installer-provisioned)에서 **pull secret** 다운로드

> pull secret은 절대 커밋하지 마세요. `.gitignore`에 이미 포함되어 있습니다.

### 3. 로컬 CLI

바이너리는 시스템 전역이 아니라 레포의 `bin/`에 둡니다.
버전이 섞이면 디버깅이 어려워지고, `bin/`은 gitignore 되어 있어 정리도 쉽습니다.
스크립트들은 `bin/`을 `PATH` 앞에 붙입니다.

```bash
# macOS Apple Silicon
CHANNEL=stable-4.22
BASE=https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${CHANNEL}
mkdir -p bin
curl -fL ${BASE}/openshift-install-mac-arm64.tar.gz | tar xz -C bin openshift-install
curl -fL ${BASE}/openshift-client-mac-arm64.tar.gz  | tar xz -C bin oc kubectl
xattr -dr com.apple.quarantine bin/    # Gatekeeper 격리 해제
chmod +x bin/*

./bin/openshift-install version
```

다른 플랫폼이면 파일명만 바꾸면 됩니다.
`openshift-install-linux.tar.gz`(Linux x86_64), `openshift-install-mac.tar.gz`(Intel Mac).

`openshift-install version`이 출력하는 `release architecture: amd64`는 설치될 클러스터 노드의 아키텍처입니다.
Apple Silicon에서 실행해도 정상입니다.

---

## 빠른 시작

```bash
# 1. 설정
cp .env.example .env
vi .env                          # BASE_DOMAIN, CLUSTER_NAME, REGION 등

# 2. pull secret 배치
cp ~/Downloads/pull-secret.txt secrets/pull-secret.json

# 3. 사전 점검 (여기서 걸리는 건 전부 설치 30분 뒤에 터질 것들입니다)
./scripts/setup-budget.sh        # 최초 1회
./scripts/preflight.sh minimal

# 4. install-config 생성 (프로파일 선택)
./scripts/render-config.sh minimal

# 4. 설치 (약 35~45분)
./scripts/create-cluster.sh

# 5. 접속
export KUBECONFIG=$(pwd)/clusters/$CLUSTER_NAME/auth/kubeconfig
oc get nodes
oc get co                        # ClusterOperator 전부 Available=True 확인

# 6. ⚠️ 연습이 끝나면 반드시
./scripts/destroy-cluster.sh
```

---

## 프로파일

`profiles/` 아래에 용도별 `install-config` 템플릿이 있습니다.

| 프로파일 | 구성 | 시간당 (us-east-1) | 용도 |
|---|---|---|---|
| `minimal` | 마스터 3 × m6i.xlarge + 워커 2 × m6i.large, **단일 AZ** | ~$0.85 | 설치 절차 연습, 기본값 |
| `compact` | 마스터 3 × m6i.2xlarge, 워커 0 (마스터 schedulable) | ~$1.30 | 워커 없이 워크로드까지 올려볼 때 |
| `sno` | 단일 노드 1 × m6i.2xlarge | ~$0.55 | 가장 저렴, 엣지/SNO 학습 |
| `default` | 마스터 3 + 워커 3, 3 AZ (설치 프로그램 기본값) | ~$1.35 | 프로덕션에 가까운 구성 체험 |

### `minimal` install-config 예시

```yaml
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
controlPlane:
  name: master
  replicas: 3
  platform:
    aws:
      type: m6i.xlarge
      zones:
        - ${REGION}a          # 단일 AZ → NAT Gateway 3개 → 1개
      rootVolume:
        size: 120
        type: gp3
compute:
  - name: worker
    replicas: 2
    platform:
      aws:
        type: m6i.large
        zones:
          - ${REGION}a
        rootVolume:
          size: 120
          type: gp3
networking:
  networkType: OVNKubernetes
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 10.0.0.0/16
  serviceNetwork:
    - 172.30.0.0/16
platform:
  aws:
    region: ${REGION}
    userTags:
      Owner: ${OWNER}
      Purpose: lab
      AutoDelete: "true"       # 정리 스크립트/Lambda가 이 태그를 봄
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_PUBLIC_KEY}'
```

---

## 비용

### 구성 요소별 (us-east-1 온디맨드, `minimal` 프로파일)

| 항목 | 수량 | 시간당 |
|---|---|---|
| 컨트롤 플레인 m6i.xlarge | 3 | $0.576 |
| 워커 m6i.large | 2 | $0.192 |
| 부트스트랩 (설치 중 ~40분만) | 1 | 일회성 ~$0.15 |
| EBS gp3 120GB × 5 | 600GB | ~$0.07 |
| NAT Gateway (단일 AZ) | 1 | $0.045 + 데이터 $0.045/GB |
| NLB (external + internal) | 2 | ~$0.05 |
| Route 53 호스팅 존 | 1 | $0.50 / 월 |
| **합계** | | **≈ $0.93 / 시간** |

### 시나리오별 예상 금액

| 시나리오 | 비용 |
|---|---|
| 설치 1회 + 4시간 실습 + 삭제 | **약 $5** |
| 하루 8시간 × 5일 (매일 삭제) | **약 $40** |
| 삭제를 잊고 한 달 방치 | **약 $680** 😱 |

서울 리전(`ap-northeast-2`)은 위 금액에서 **약 20~25% 추가**됩니다.

> 위 단가는 2026년 8월 기준 참고값입니다. 실제 청구액은
> [AWS Pricing Calculator](https://calculator.aws/)와 Cost Explorer로 확인하세요.

### 비용을 줄이는 방법

- ✅ **단일 AZ 사용** — NAT Gateway 3개 → 1개 (월 $65 절약)
- ✅ **워커 노드 최소화** — 설치 절차 연습이 목적이면 `m6i.large` 2대로 충분
- ✅ **루트 볼륨 120GB 유지** — 기본값 이상으로 키우지 않기
- ✅ **`us-east-1` 사용** — 서울 대비 20% 저렴
- ❌ **EC2 stop만 하고 방치하지 않기** — NAT Gateway, NLB, EBS, EIP는 계속 과금됩니다
- ❌ **io1/io2 볼륨 쓰지 않기** — gp3 대비 몇 배 비쌉니다

---

## 클러스터 삭제 (중요)

**이 레포에서 가장 중요한 부분입니다.**

```bash
./scripts/destroy-cluster.sh
# 내부적으로: openshift-install destroy cluster --dir=clusters/$CLUSTER_NAME
```

`destroy`는 설치 시 생성된 메타데이터(`metadata.json`)를 기준으로 리소스를 찾습니다.
**`clusters/<name>/` 디렉토리를 지우면 자동 삭제가 불가능해집니다.** 반드시 보관하세요.

### 삭제 후 확인 체크리스트

```bash
./scripts/verify-clean.sh
```

수동으로 확인한다면:

```bash
CLUSTER_TAG="kubernetes.io/cluster/${INFRA_ID}"

aws ec2 describe-instances --filters "Name=tag-key,Values=$CLUSTER_TAG" --region $REGION
aws ec2 describe-nat-gateways --region $REGION
aws elbv2 describe-load-balancers --region $REGION
aws elb describe-load-balancers --region $REGION        # Service type=LoadBalancer 흔적
aws ec2 describe-volumes --filters "Name=status,Values=available" --region $REGION
aws ec2 describe-addresses --region $REGION             # 미사용 EIP도 과금됩니다
aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID

# 아래 세 가지는 자주 누락되지만 실제로 남습니다
aws s3api list-buckets --query "Buckets[?contains(Name,'$INFRA_ID')]"   # 버킷 2종 (아래 참고)
aws route53 list-hosted-zones \
  --query "HostedZones[?Config.PrivateZone==\`true\`]"                  # 프라이빗 존, 개당 월 \$0.50
aws iam list-roles  --query "Roles[?contains(RoleName,'$INFRA_ID')]"    # 과금은 없지만 계정이 지저분해집니다
aws iam list-users  --query "Users[?contains(UserName,'$INFRA_ID')]"    # 4.22 기준 0개. 구버전 대비 방어용
```

S3 버킷은 두 종류가 만들어집니다.
용도가 달라서 남는 이유도 다릅니다.

| 버킷 | 용도 | 언제 사라지나 |
|---|---|---|
| `openshift-bootstrap-data-<infraID>` | 부트스트랩 ignition 전달 | 부트스트랩 완료 시점에 설치 프로그램이 삭제 |
| `<infraID>-image-registry-<region>` | 내부 이미지 레지스트리 백엔드 | `destroy` 때 삭제. 이미지를 push했다면 용량만큼 과금됨 |

설치가 중간에 실패하면 첫 번째 버킷이 남아 재설치를 방해할 수 있습니다.

### 안전장치 권장

우선순위 순서입니다.
1번이 실질적인 방어선이고, 나머지는 보조 수단입니다.

1. **한 세션 안에 끝내기.**
   설치 40분, 실습, 그리고 바로 `destroy`.
   재설치가 40분이면 되므로 stop/start보다 destroy가 항상 깔끔합니다.
2. **실습을 시작하기 전에 destroy 타이머를 먼저 걸기.**
   끝나고 나서 기억해내는 것보다 확실합니다.
3. **`clusters/<name>/metadata.json` 백업.**
   `create-cluster.sh`가 `clusters/_backups/`에 자동으로 복사합니다.
   이 파일이 없으면 자동 삭제가 불가능해집니다.
4. **`Purpose=lab` 태그 + Cost Explorer 필터링.**
5. **AWS Budgets** (`./scripts/setup-budget.sh`).

> Budgets는 **청구 데이터 자체가 8~24시간 지연**됩니다.
> 시간당 $0.93짜리 클러스터를 방치했을 때 알림이 울릴 즈음이면 이미 $20이 나간 뒤입니다.
> 백스톱으로는 두되, 이걸 주 방어선으로 믿지 마세요.

---

## 라이선스 / 구독

OCP 셀프 매니지드는 **유료 구독 제품**입니다(코어/소켓 페어 단위 연간 계약, 정가 비공개).
다만 **학습 목적이라면 무료 경로**가 있습니다.

| 방법 | 비용 | 설치 연습 | 비고 |
|---|---|---|---|
| **60일 평가판** | 무료 | ✅ | 기능 제한 없음. 이 레포의 기본 전제 |
| **OKD** | 영구 무료 | ✅ | 커뮤니티 업스트림. 절차 거의 동일 |
| Developer Sandbox | 무료 | ❌ | 이미 만들어진 공유 클러스터 |
| OpenShift Local (CRC) | 무료 | ❌ | 로컬 단일 노드 개발용 |
| ROSA | 시간당 과금 | △ | 워커 4 vCPU당 $0.171/h + HCP 클러스터 $0.25/h. `rosa` CLI라 절차가 다름 |

**60일이 지난 뒤에는 OKD로 전환**하는 걸 권장합니다. `openshift-install` 대신 OKD 릴리스의 installer를 쓰는 것 외에 흐름이 거의 같습니다.

> 평가판이든 유료 구독이든 **AWS 인프라 비용은 별도**입니다. 구독은 소프트웨어에 대한 것이지 인프라를 포함하지 않습니다.

---

## 트러블슈팅

<details>
<summary><b><code>openshift-install</code>을 직접 실행했더니 엉뚱한 IAM 유저로 붙음</b></summary>

`openshift-install`은 `.env`를 읽지 않고 AWS SDK의 기본 프로파일을 씁니다.
계정에 다른 프로젝트 IAM 유저가 여럿 있으면 `UnauthorizedOperation`이 나거나, 더 나쁘게는 의도하지 않은 컨텍스트로 동작합니다.

스크립트(`create-cluster.sh`, `destroy-cluster.sh`, `preflight.sh`)를 통해 실행하면 자동으로 처리됩니다.
직접 명령을 칠 때는 먼저 환경을 로드하세요.

```bash
source scripts/env.sh
openshift-install wait-for bootstrap-complete --dir=$CLUSTER_DIR
```
</details>

<details>
<summary><b>설치가 <code>waiting for bootstrap to complete</code>에서 멈춤</b></summary>

```bash
openshift-install wait-for bootstrap-complete --dir=clusters/$CLUSTER_NAME --log-level=debug

# 부트스트랩 노드 로그 수집
openshift-install gather bootstrap --dir=clusters/$CLUSTER_NAME
```

대부분 원인: 보안 그룹, NAT/인터넷 접근 불가, Route 53 레코드 전파 지연, vCPU 쿼터 초과.
</details>

<details>
<summary><b><code>UnauthorizedOperation</code> / IAM 권한 오류</b></summary>

IPI는 IAM 역할·정책을 직접 생성합니다. 권한이 부족하면 중간에 실패합니다.
학습용이면 관리자 권한으로 시작하고, 최소 권한 구성은 Red Hat의 least-privilege 가이드를 참고하세요.
</details>

<details>
<summary><b><code>InsufficientInstanceCapacity</code></b></summary>

해당 AZ에 인스턴스가 없습니다. `zones`를 다른 AZ로 바꾸거나 인스턴스 타입을 변경하세요 (`m6i` → `m5`).
</details>

<details>
<summary><b>며칠 꺼뒀다가 켰더니 노드가 <code>NotReady</code></b></summary>

OCP는 kubelet 클라이언트 인증서를 자동 갱신하는데, 클러스터가 꺼져 있는 동안 갱신이 안 됩니다.

```bash
oc get csr -o name | xargs oc adm certificate approve
```

**24시간 이상 정지는 권장하지 않습니다.** 실습용이라면 stop/start보다 destroy 후 재설치가 훨씬 깔끔하고, 어차피 비용도 비슷합니다.
</details>

<details>
<summary><b>destroy 후에도 리소스가 남아 있음</b></summary>

주로 클러스터가 동적으로 만든 리소스입니다 (Service type=LoadBalancer로 생성된 ELB, PVC로 생성된 EBS 볼륨).
`destroy` 전에 워크로드를 먼저 지우면 예방됩니다. 남았다면 `scripts/verify-clean.sh`로 찾아 수동 삭제하세요.
</details>

---

## 디렉토리 구조

```
ocp-aws-lab/
├── README.md
├── .env.example
├── .gitignore                  # secrets/, clusters/ 제외
├── profiles/
│   ├── minimal.yaml.tpl
│   ├── compact.yaml.tpl
│   ├── sno.yaml.tpl
│   └── default.yaml.tpl
├── bin/                        # gitignored, openshift-install / oc
├── scripts/
│   ├── lib.sh                  # 공통 함수, .env 로더
│   ├── env.sh                  # source 용. 수동 명령 실행 전 환경 로드
│   ├── preflight.sh            # 쿼터/권한/DNS위임/pull secret 사전 점검
│   ├── render-config.sh        # 템플릿 → install-config.yaml
│   ├── create-cluster.sh       # 설치 + metadata.json 자동 백업
│   ├── destroy-cluster.sh
│   ├── verify-clean.sh         # 잔여 리소스 스캔
│   └── setup-budget.sh         # AWS Budgets 알림
├── secrets/                    # gitignored
│   └── .gitkeep
├── clusters/                   # gitignored, metadata.json 보관용
│   └── .gitkeep
└── docs/
    ├── cost-breakdown.md
    ├── budget-alert.md
    ├── day2-operations.md      # MachineSet, Ingress, 스토리지 등
    └── okd-migration.md
```

---

## 로드맵

- [ ] `preflight.sh` — 설치 전 쿼터·IAM·DNS 자동 점검
- [ ] 미삭제 클러스터 자동 정리 (EventBridge + Lambda, `AutoDelete=true` 태그 기준)
- [ ] Day-2 실습 시나리오 (MachineSet 스케일링, Ingress 커스터마이징, ODF)
- [ ] Spot 인스턴스 워커 MachineSet 예제
- [ ] OKD 프로파일 추가
- [ ] Terraform 기반 UPI 브랜치

---

## 참고 링크

- [OpenShift 설치 문서 (AWS)](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/installing/installing-on-aws)
- [openshift/installer — AWS 가이드](https://github.com/openshift/installer/blob/main/docs/user/aws/install.md)
- [OCP 60일 평가판](https://www.redhat.com/en/technologies/cloud-computing/openshift/ocp-self-managed-trial)
- [OKD](https://www.okd.io/)
- [AWS Pricing Calculator](https://calculator.aws/)
- [ROSA 요금](https://aws.amazon.com/rosa/pricing/)

---

## License

이 레포의 스크립트와 문서는 MIT 라이선스입니다.
OpenShift Container Platform 자체는 Red Hat의 구독 조건을 따릅니다.
