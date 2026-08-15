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
