# MaaS 와 llm-d 를 이 랩에서 할 수 있나

결론부터 적습니다.
**둘 다 이 랩의 하드웨어로는 못 합니다.** 예산이 아니라 지원 목록의 문제입니다.

RHOAI 3.4.3 에 이미지도 CRD 도 들어 있어서 "켜면 되겠네" 로 보이지만 아닙니다.
아래는 문서와 클러스터를 실제로 확인한 기록입니다.

조사 시점은 2026-08-16, 대상은 OCP 4.22.6 / RHOAI 3.4.3 / g6.xlarge(NVIDIA L4) 입니다.

---

## 1. 클러스터에는 이미 다 있습니다

먼저 이게 헷갈리는 지점입니다. 있긴 있습니다.

```bash
oc get crd | grep -iE "llminference|modelsasservice"
```

```text
llminferenceserviceconfigs.serving.kserve.io
llminferenceservices.serving.kserve.io
modelsasservices.components.platform.opendatahub.io
```

오퍼레이터 이미지 목록에도 들어 있습니다.

```text
RELATED_IMAGE_ODH_MAAS_API_IMAGE
RELATED_IMAGE_ODH_MAAS_CONTROLLER_IMAGE
RELATED_IMAGE_ODH_LLM_D_BATCH_GATEWAY_APISERVER_IMAGE
```

DSC 상태 조건에도 있습니다.

```text
ModelsAsServiceReady=False  Component ManagementState is set to Removed
```

**CRD 와 이미지가 있다는 건 "쓸 수 있다"가 아닙니다.**
전제 조건과 지원 하드웨어가 따로 있습니다.

---

## 2. MaaS 를 켜는 위치는 최상위가 아닙니다

처음에 이렇게 시도했다가 틀렸습니다.

```bash
oc patch datasciencecluster default-dsc --type=merge \
  -p '{"spec":{"components":{"modelsasservice":{"managementState":"Managed"}}}}'
```

```text
Warning: unknown field "spec.components.modelsasservice"
datasciencecluster.../default-dsc patched (no change)
```

`patched (no change)` 라 성공처럼 보이지만 아무 일도 안 일어납니다.

실제 경로는 **`kserve` 아래에 중첩**되어 있습니다.

```text
spec.components.kserve.modelsAsService.managementState   enum: Managed | Removed
```

DSC 의 `components` 키 14개만 훑어보면 `modelsasservice` 가 없어서
"이 버전엔 없구나" 로 잘못 결론 내리기 딱 좋습니다.

확인하는 법입니다.

```bash
oc get crd datascienceclusters.datasciencecluster.opendatahub.io -o json \
| jq -r '.spec.versions[]|select(.name=="v2")
         .schema.openAPIV3Schema.properties.spec.properties.components
         .properties.kserve.properties|keys[]'
```

---

## 3. 막는 것은 GPU 지원 목록입니다

여기가 핵심입니다.

Red Hat 문서의 *Supported AI accelerators for Distributed Inference with llm-d* 표입니다.

| 용도 | 지원 NVIDIA 가속기 | 권장 네트워크 |
| --- | --- | --- |
| Intelligent inference scheduling | H100, H200, B200, A100 | 25/100 GbE |
| Prefill/Decode 분리 | H100, H200, B200 | 100 GbE |
| KV cache management | H100, H200, B200, A100 | 25/100 GbE |
| Wide expert parallelism | H100, H200, B200 | InfiniBand / RoCE (RDMA) |

**L4 는 어느 줄에도 없습니다.**
`g6.xlarge` 가 L4 이므로 이 랩의 GPU 는 llm-d 지원 대상이 아닙니다.

L4 자체가 못 쓰는 카드라서가 아닙니다.
같은 문서의 일반 vLLM 표에는 Ada Lovelace L4 가 정상적으로 들어 있습니다.
**우리가 이미 하고 있는 vLLM 단일 노드 서빙은 지원 범위 안입니다.**
llm-d 가 요구하는 건 KV 캐시를 노드 간에 옮기는 등급의 카드와 네트워크입니다.

### AWS 에서 A100 을 붙이려면

지원 목록 중 AWS 에서 가장 싼 것이 A100 이고 `p4d` 계열입니다.

```text
A100 40GB   P4d 계열   p4d.24xlarge = A100 8장   온디맨드 약 $32.77/h
H100 80GB   P5 계열    p5.48xlarge  = H100 8장   온디맨드 약 $98/h
```

한 시간에 예산의 3분의 1이 나갑니다. 그리고 애초에 못 켭니다.

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-417A185B
```

```text
Running On-Demand P instances: 0.0 vCPU
```

**쿼터가 0 입니다.** 별도 증설 신청이 필요하고, 승인돼도 위 단가입니다.
G/VT 쿼터(32 vCPU)는 P 계열에 적용되지 않습니다. 다른 쿼터입니다.

---

## 4. 오퍼레이터 전제도 안 맞습니다

GPU 를 빼고 봐도 걸립니다.

llm-d 가 요구하는 것들입니다.

| 필요한 것 | 이 클러스터 카탈로그 |
| --- | --- |
| Red Hat Connectivity Link (Gateway API 구현) | **없음**. Community `kuadrant-operator` 만 있음 |
| Istio / Sail Operator | Community `sailoperator` 만 있음 |
| cert-manager | 있음. `distributed` 액션이 설치합니다 |
| LeaderWorkerSet | 없음 (wide expert parallelism 용) |

MaaS 는 여기에 더 붙습니다.

- llm-d 분산 추론이 **먼저** 켜져 있어야 합니다 (인증 포함)
- Red Hat Connectivity Link **1.3.x** + `kuadrant-system` 에 Kuadrant CR
- Gateway API 의 GatewayClass / Gateway + **유효한 TLS 인증서**
  (`*.apps` 자체 서명 인증서로는 안 됩니다)
- User Workload Monitoring 활성화. 없으면 MaaS 가 Degraded 로 뜹니다
- **PostgreSQL 을 직접 준비해야 합니다.** RHOAI 가 제공하지 않습니다

즉 MaaS 는 llm-d 위에 얹는 거버넌스 계층이고, 아래가 안 서면 위도 안 섭니다.

---

## 5. 지원 등급도 확인해야 합니다

돌아간다 해도 프로덕션 이야기는 아닙니다.

| 기능 | 등급 |
| --- | --- |
| Distributed Inference with llm-d | Technology Preview |
| Prefill/Decode 분리 | **Developer Preview** (Red Hat 지원 없음, 문서도 없을 수 있음) |
| Wide expert parallelism | Developer Preview |
| MaaS 의 vLLM 런타임 | Technology Preview |
| MaaS 관측 대시보드 | Technology Preview |

---

## 6. 그래서 이 랩에서 하는 것

L4 한 장으로 지원 범위 안에서 할 수 있는 것들입니다.

| 항목 | 가능 | 비고 |
| --- | --- | --- |
| vLLM 단일 노드 서빙 | 가능 | 이미 함. L4 는 지원 목록에 있음 |
| LoRA 파인튜닝 (PyTorchJob) | 가능 | `trainingoperator`. 서빙과 GPU 를 나눠 써야 함 |
| Ray 분산 처리 | 가능 | `ray`. 헤드는 CPU, 워커에 GPU 1장 |
| Kueue 큐/쿼터 | 가능 | 잡을 큐에 넣고 쿼터로 막는 것까지 |
| llm-d | **불가** | L4 미지원 + P 쿼터 0 |
| MaaS | **불가** | llm-d 의존 + Connectivity Link 없음 |

MaaS 와 llm-d 를 꼭 봐야 한다면 이 랩이 아니라
**A100 이상이 있는 환경**에서 별도로 해야 합니다.
그 경우 Helm 차트(`rhaii` 프로파일)가 필요한 오퍼레이터를 OLM 으로 알아서 깝니다.

---

## 참고한 문서

- [Distributed Inference with llm-d (Red Hat AI Inference 3.5)](https://docs.redhat.com/en/documentation/red_hat_ai_inference/3.5/html-single/distributed_inference_with_llm-d/index)
- [Supported product and hardware configurations (Red Hat AI 3)](https://docs.redhat.com/en/documentation/red_hat_ai/3/html-single/supported_product_and_hardware_configurations/index)
- [Deploy and manage Models-as-a-Service (RHOAI 3.4)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas)
- [Red Hat build of Kueue (OCP 4.20)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/ai_workloads/red-hat-build-of-kueue)
