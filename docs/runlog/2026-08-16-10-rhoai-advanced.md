# ray/kueue/trainer 활성화, MaaS·llm-d 조사

- **단계**: `10-rhoai-advanced`
- **시작**: 2026-08-16 04:22:41 KST
- **실행자**: kiyeon
- **리전 / AZ**: us-east-1 / us-east-1a
- **프로파일**: ai (시간당 약 $1.54)
- **클러스터**: lab1.ocp.kiyeonjeon.com (OCP 4.22.6)
- **AWS 프로파일**: ocp-lab
- **커밋**: f2e255e

## 만들어진 리소스

| 종류 | ID | 설명 | 시각 |
| --- | --- | --- | --- |

## 기록

- `04:22:41` RHOAI 3.4.3 조사 결과: llm-d(LLMInferenceService)와 MaaS(ModelsAsService) CRD 및 이미지는 존재. 단 DSC spec.components 14개 키에 modelsasservice 없음. ray/kueue/trainer/trainingoperator 는 키 있고 Removed 상태

<details>
<summary><b>./scripts/install-rhoai.sh distributed - 실패 (exit=1, 707s)</b></summary>

```text

== 1. 전제 오퍼레이터
  OK    kueue-operator  channel=stable-v1.4  source=redhat-operators
  OK    OperatorGroup 생성 (own)
  OK    Subscription 적용
  CSV 대기 ............................................................
  FAIL  CSV 가 600초 안에 Succeeded 가 되지 않았습니다
    oc get csv -n openshift-kueue-operator
    oc get installplan -n openshift-kueue-operator
```

</details>

- `04:59:19` A단계 완료: ray/trainingoperator Managed, kueue Unmanaged, cert-manager 설치. DSC Ready. RayCluster/RayJob/PyTorchJob/ClusterQueue/LocalQueue CRD 사용 가능. MaaS 는 3.4.3 DSC 가 spec.components.modelsasservice 를 unknown field 로 거부
- `05:02:27` MaaS/llm-d 조사 결론: llm-d 지원 가속기는 H100/H200/B200/A100 뿐이고 L4(g6)는 목록에 없음. AWS P 인스턴스 쿼터가 0 vCPU 라 A100 기동 자체가 불가. Red Hat Connectivity Link 는 카탈로그에 없고 Community kuadrant 만 존재. MaaS 는 llm-d + Connectivity Link + Gateway TLS + User Workload Monitoring + 외부 PostgreSQL 을 요구. 둘 다 이 랩에서 불가. MaaS 활성화 경로는 spec.components.kserve.modelsAsService.managementState (최상위 컴포넌트가 아님)
- `05:06:18` B단계 시작: GPU 1장. 튜닝(PyTorchJob LoRA) -> Ray. 서빙을 먼저 내려 GPU 를 비웁니다

<details>
<summary><code>./scripts/gpu-node.sh up 1</code> - OK (7s)</summary>

```text

== 사전 확인
  OK    g6.xlarge 가 us-east-1a 에서 제공됨
  OK    G/VT vCPU 쿼터 32 >= 필요 4

== 기존 MachineSet 확장
machineset.machine.openshift.io/lab1-cxfgs-gpu-us-east-1a scaled
  OK    lab1-cxfgs-gpu-us-east-1a -> replicas=1

  노드가 Ready 가 되기까지 5~10분 걸립니다.
    watch oc get machine -n openshift-machine-api -l machine.openshift.io/cluster-api-machineset=lab1-cxfgs-gpu-us-east-1a

  다음: ./scripts/install-rhoai.sh gpu    (NFD + NVIDIA GPU Operator)

```

</details>

<details>
<summary><code>./scripts/tune.sh run</code> - OK (7s)</summary>

```text

== 1. GPU 확보
  OK    GPU 1 장
  OK    서빙이 이미 내려가 있음

== 2. 이전 잡 정리
  이전 잡 없음

== 3. 실행
  OK    PyTorchJob lora-lab-style 적용

  베이스 모델   Qwen/Qwen2.5-0.5B-Instruct
  어댑터 이름   lab-style

  로그:  ./scripts/tune.sh logs
  상태:  ./scripts/tune.sh status

```

</details>

- `05:39:49` LoRA 튜닝 성공. 1차(attention만 r=16, 8ep, 0.44% param)는 문체만 학습하고 사실은 틀림. 2차(MLP 추가 r=32, 40ep, 3.44% param, 94초)는 3개 질문 전부 정답. 서빙 복구함

<details>
<summary><code>./scripts/ray.sh up</code> - OK (191s)</summary>

```text

== Ray 클러스터
  OK    RayCluster lab-ray 적용 (헤드만, 워커 0)
  헤드 기동 .................
  OK    RayCluster ready

  GPU 워커를 붙이려면:  ./scripts/ray.sh worker 1
    단, GPU 1장을 서빙이 쓰고 있으면 Pending 입니다

```

</details>

<details>
<summary><code>./scripts/gpu-node.sh down</code> - OK (3s)</summary>

```text

== GPU 노드 축소
machineset.machine.openshift.io/lab1-cxfgs-gpu-us-east-1a scaled
  OK    replicas=0. EC2 와 EBS 가 사라지면 과금이 멈춥니다
  MachineSet 은 남습니다. 다시 쓰려면 ./scripts/gpu-node.sh up

  실제로 사라졌는지 확인:
    oc get machine -n openshift-machine-api | grep gpu

```

</details>

- `06:25:49` MLflow 연동 완료. RHOAI 3.4 MLflow 는 멀티테넌트라 Bearer 토큰 + X-Mlflow-Workspace 헤더 둘 다 필요. 권한은 view=읽기, edit=쓰기(실험 생성 200). 전용 SA tuning 으로 분리. 실험 lora-lab-style 생성 확인(artifact_location mlflow-artifacts:/workspaces/ai-serving/2). 마지막 학습은 132/160 진행 중 GPU 반납으로 중단됨(내 조작)

<details>
<summary><code>./scripts/destroy-cluster.sh</code> - OK (5s)</summary>

```text

== 삭제 대상
  cluster : lab1
  infraID : lab1-cxfgs
  region  : us-east-1
  aws     : arn:aws:iam::584625391472:user/ocp-lab-admin

== 워크로드가 만든 AWS 리소스 확인
  OK    고아가 될 LoadBalancer 서비스 없음
  WARN  Bound 상태 PVC 11개. 지우지 않으면 EBS 볼륨이 남을 수 있습니다

  WARN  되돌릴 수 없습니다. 클러스터 이름을 그대로 입력하면 진행합니다.
클러스터 이름 (lab1): 취소했습니다.
```

</details>

- `06:35:57` 정리 완료. verify-clean(lab1-cxfgs) 전 항목 OK, sweep 과금 리소스 없음. NAT/LB/CLB/EBS/EIP/VPC/S3/IAM/프라이빗존 전부 삭제 확인. 퍼블릭존 ocp.kiyeonjeon.com 은 유지(계정 소유). 다른 프로젝트 S3 버킷 12개는 손대지 않음

## 마무리

- **종료**: 2026-08-16 06:35:57 KST
- **결과**: ok
- **소요**: 7996초 (2.22시간)
- **추정 비용**: 약 $3.42 (시간당 $1.54, ai 프로파일)

### 다음에 다르게 할 것

-
