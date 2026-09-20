# Qwen3-8B 서빙 셋업 (OCP + RHOAI)

외부에서 OpenAI 호환으로 쓸 수 있는 상태까지의 전체 구성입니다.
`docs/qwen3-thinking.md` 가 "왜 이렇게 됐나"라면, 이 문서는 **"무엇을 만들었나"** 입니다.

세대 고유값(도메인, infraID)은 바뀝니다. 구조와 이유만 보세요.

- 측정 환경: `g6.xlarge`(NVIDIA L4 24GB), OCP 4.22.6, RHOAI 3.5.0, vLLM 0.24.0+rhaiv.9
- 모델: `Qwen/Qwen3-8B` (HuggingFace 원본 fp16, 약 16GB)

---

## 1. 접속 정보

| 항목 | 값 |
| --- | --- |
| `base_url` | `https://qwen3-api-<ns>.apps.<cluster>.<domain>/v1` |
| `model` | `qwen3-8b` |
| `api_key` | ServiceAccount 토큰 (Bearer) |
| `ca_cert_pem` | 라우터 CA |
| `max_tokens` | **4000 이상** |

토큰과 CA 는 이렇게 뽑습니다.

```bash
source scripts/env.sh
oc create token qwen3-client -n ai-serving --duration=24h
oc get secret -n openshift-ingress-operator router-ca -o jsonpath='{.data.tls\.crt}' | base64 -d
```

`router-ca` 는 **루트 CA 하나**입니다.
`default-ingress-cert` 는 리프 인증서까지 들어 있어 신뢰 앵커로는 부정확합니다.

**`max_tokens` 4000 미만이면 어려운 과제가 전부 `length` 로 끊깁니다.**
thinking 이 먼저 나오고 본문이 뒤에 오는 구조라, 예산이 모자라면 본문이 한 글자도 안 나옵니다.

---

## 2. vLLM 인자

`InferenceService` 의 `spec.predictor.model.args` 에 둡니다.

```text
--served-model-name=qwen3-8b
--gpu-memory-utilization=0.92
--max-model-len=32768
--kv-cache-dtype=fp8
--enable-auto-tool-choice
--tool-call-parser=hermes
--reasoning-parser=qwen3
```

| 인자 | 없으면 |
| --- | --- |
| `--kv-cache-dtype=fp8` | KV 캐시가 24,064 토큰이라 `max-model-len=32768` 이 **기동 거부** |
| `--enable-auto-tool-choice` | `"auto" tool choice requires ...` 오류. 툴 콜 불가 |
| `--tool-call-parser=hermes` | 툴 콜이 파싱되지 않음 |
| `--reasoning-parser=qwen3` | `content` 에 `<think>...</think>` 가 그대로 섞임 |

메모리 실측입니다.

```text
가중치            15.27 GiB
Available KV      3.75 GiB
KV 캐시 토큰      54,576          (fp8 기준. bf16 이면 24,064)
동시성            32,768 토큰 요청 기준 1.67배
```

**`max-model-len` 은 KV 캐시 토큰 수를 넘을 수 없습니다.** 이 하드웨어의 상한이 54,576 입니다.

### 바꾸는 방법

```bash
oc patch isvc qwen3-8b -n ai-serving --type=merge \
  -p '{"spec":{"predictor":{"model":{"args":[ ... ]}}}}'
```

`oc patch deploy` 나 `oc set env deploy` 는 **KServe 가 5초 안에 되돌립니다.** ISVC 만 남습니다.

### GPU 1장이라 롤아웃이 교착합니다

args 를 바꾸면 새 파드가 뜨려는데 GPU 를 기존 파드가 쥐고 있어 `Pending` 에서 멈춥니다.
구 ReplicaSet 을 직접 0 으로 내려야 풀립니다.

```bash
oc get rs -n ai-serving | grep predictor
oc scale rs <구-ReplicaSet> -n ai-serving --replicas=0
```

재기동은 **4~5분**입니다.
컨테이너 메모리 한도(11Gi)가 체크포인트(15.26GiB)보다 작아 vLLM 이 프리페치를 못 쓰고 조각당 30초씩 읽습니다.
자주 고칠 거면 한도를 20Gi 로 올리면 빨라집니다.

### thinking 을 끄려면

```text
--default-chat-template-kwargs={"enable_thinking": false}
```

`--chat-template-kwargs` 가 아닙니다. vLLM 0.24 기준 이름이 다릅니다.
**thinking 예산 제한은 이 버전에 없습니다.** on/off 뿐입니다.

---

## 3. 외부 노출 구조

```text
클라이언트
  → Route qwen3-api (reencrypt, timeout 600s)
     → Service qwen3-gateway :8443
        → Deployment qwen3-gateway (oauth-proxy, --upstream-timeout=600s)
           → Service qwen3-8b-predictor :8080   ← vLLM 직결
```

**KServe 가 주입한 `kube-rbac-proxy` 사이드카를 거치지 않습니다.**
그 사이드카는 `--upstream-timeout` 이 30초로 고정이고 바꿀 수 없습니다.

### 만든 리소스

| 종류 | 이름 | 역할 |
| --- | --- | --- |
| ServiceAccount | `qwen3-client` | 클라이언트 신원. 이 토큰이 api_key |
| Role / RoleBinding | `qwen3-8b-invoker` | `inferenceservices/qwen3-8b` `get` 만 |
| ServiceAccount | `qwen3-gateway` | oauth-proxy 신원 |
| ClusterRoleBinding | `qwen3-gateway-auth-delegator` | TokenReview / SAR 권한 |
| Service | `qwen3-gateway` | serving cert 자동 발급 |
| Deployment | `qwen3-gateway` | oauth-proxy 1 파드 |
| Secret | `qwen3-gateway-cookie` | 랜덤 32자 |
| Route | `qwen3-api` | reencrypt + timeout 600s |
| ClusterRoleBinding | `qwen3-8b-auth-delegator` | (rbac-proxy 경로 시도 때 만든 것. 지금 경로에는 불필요) |
| Service | `qwen3-8b-authenticated` | (같음. 지금 경로에는 불필요) |

마지막 둘은 `kube-rbac-proxy` 경로를 쓰려다 남긴 것입니다. 지워도 됩니다.

### 권한 모델

`qwen3-client` 토큰은 `inferenceservices/qwen3-8b` 에 `get` 하나만 가집니다.
유출돼도 클러스터의 다른 것은 못 건드립니다.
즉시 무효화하려면 SA 를 지웠다 다시 만들면 기존 토큰이 전부 죽습니다.

---

## 4. 타임아웃이 세 겹이었습니다

이게 이 셋업에서 제일 많은 시간을 먹은 부분입니다.

| 구간 | 기본값 | 증상 | 대응 |
| --- | --- | --- | --- |
| `kube-rbac-proxy --upstream-timeout` | 30초 | 502 at 30.01초 | **수정 불가.** 우회해야 함 |
| `oauth-proxy --upstream-timeout` | 30초 | 502 at 30.02초 | 우리 Deployment → 600s |
| Classic ELB `IdleTimeout` | **60초** | 빈 응답 at 60.0초 | 600 으로 변경 |
| 라우터 haproxy `timeout client` | 30초 | 위에 가려 안 보였음 | `tuningOptions` 600s |

**앞의 벽을 치우면 다음 벽이 나옵니다.**
30초를 넘기자 60초가 나왔습니다. 55초짜리 요청은 통과해서 한때 해결된 줄 알았습니다.
**한 번 고치고 "됐다" 라고 하면 안 되고, 실제 최대 길이로 다시 재야 합니다.**

### 각각의 명령

```bash
# 라우트 (백엔드 timeout server 만 바꿉니다)
oc annotate route qwen3-api -n ai-serving \
  haproxy.router.openshift.io/timeout=600s --overwrite

# 라우터 전역 (timeout client 는 여기서만 바뀝니다. 라우터 파드 재시작)
oc patch ingresscontroller default -n openshift-ingress-operator --type=merge \
  -p '{"spec":{"tuningOptions":{"clientTimeout":"600s","serverTimeout":"600s"}}}'

# Classic ELB (어노테이션이 즉시 반영 안 되면 AWS API 로 직접)
oc annotate svc router-default -n openshift-ingress \
  service.beta.kubernetes.io/aws-load-balancer-connection-idle-timeout=600 --overwrite
aws elb modify-load-balancer-attributes --region "$REGION" \
  --load-balancer-name <name> \
  --load-balancer-attributes '{"ConnectionSettings":{"IdleTimeout":600}}'
```

ELB 이름은 이렇게 찾습니다.

```bash
aws elb describe-load-balancers --region "$REGION" \
  --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text
```

### 어디가 끊는지 찾는 법

클러스터 **안에서** 구간을 나눠 재면 한 번에 좁혀집니다.

```bash
POD=$(oc get pods -n ai-serving --no-headers | awk '/predictor/ && $3=="Running"{print $1}')
IP=$(oc get pod "$POD" -n ai-serving -o jsonpath='{.status.podIP}')

# A) vLLM 직결 - 프록시와 라우터를 모두 우회
curl http://$IP:8080/v1/chat/completions ...
# B) 사이드카 경유 - 라우터만 우회
curl -k https://$IP:8443/v1/chat/completions ...
```

A 는 36초 완주, B 는 30.01초 502 로 범인이 바로 드러났습니다.

---

## 5. 함정 세 가지

### 5.1 `qwen3-8b-predictor` 는 headless 입니다

```text
clusterIP: None
ports: 80 -> 8080
```

DNS 가 ClusterIP 가 아니라 **파드 IP** 를 그대로 돌려줍니다.
kube-proxy 를 안 거치므로 **포트 매핑이 동작하지 않습니다.**

- 업스트림에 `:80` 을 쓰면 `connection refused`
- `oc port-forward svc/... 8000:80` 도 같은 이유로 실패

**`:8080` 을 직접 써야 합니다.** port-forward 는 `pod/` 를 대상으로 하세요.

```bash
oc port-forward -n ai-serving pod/<predictor-pod> 8000:8080
```

### 5.2 Route 이름을 ISVC 와 같게 두지 마세요

`qwen3-8b` 라는 이름으로 Route 를 만들었더니 KServe 컨트롤러가 자기 관리 대상으로 보고 **지웠습니다.**
`qwen3-api` 처럼 다른 이름을 쓰세요.

### 5.3 reencrypt 는 백엔드 인증서 SAN 을 봅니다

파드의 serving cert SAN 은 원래 서비스 이름으로만 발급됩니다.

```text
DNS:qwen3-8b-predictor.ai-serving.svc
DNS:qwen3-8b-predictor.ai-serving.svc.cluster.local
```

다른 이름의 Service 를 백엔드로 두고 reencrypt 하면 503 이 납니다.
`destinationCACertificate` 에 **서비스 CA** 를 넣어야 합니다.

```bash
oc get cm openshift-service-ca.crt -n ai-serving -o jsonpath='{.data.service-ca\.crt}'
```

passthrough 로 두면 클라이언트가 파드 인증서를 직접 보게 되는데,
SAN 이 라우트 호스트명과 안 맞아 **정상적인 TLS 검증이 불가능**합니다. reencrypt 가 맞습니다.

---

## 6. 성능 특성

| 항목 | 값 |
| --- | --- |
| 단일 스트림 | 16.1 tok/s |
| 동시 2건 | 31.2 tok/s (합산) |
| 가중치 로드 | 약 2분 (프리페치 불가) |
| 전체 기동 | 4~5분 |

**단일 스트림 16 tok/s 는 L4 메모리 대역폭의 물리적 한계입니다.**

```text
L4 대역폭 약 300 GB/s ÷ 가중치 16.4 GiB ≈ 18.3 tok/s 이론 상한
실측 16.1 → 이론치의 88%
```

`--enforce-eager` 는 꺼져 있고 CUDA 그래프도 정상입니다. 설정으로 개선할 여지가 없습니다.

**동시 요청은 거의 선형으로 오릅니다.** 벤치마크를 2병렬로 돌리면 전체 시간이 절반입니다.

---

## 7. 검증 스니펫

```bash
source scripts/env.sh
URL="https://$(oc get route qwen3-api -n ai-serving -o jsonpath='{.spec.host}')"
TOKEN=$(oc create token qwen3-client -n ai-serving --duration=24h)
oc get secret -n openshift-ingress-operator router-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/router-ca.crt

# 인증이 살아 있나 (토큰 없으면 302)
curl -s --cacert /tmp/router-ca.crt -o /dev/null -w '%{http_code}\n' "$URL/v1/models"

# 모델과 컨텍스트
curl -s --cacert /tmp/router-ca.crt -H "Authorization: Bearer $TOKEN" "$URL/v1/models"

# 긴 응답이 안 끊기나 (60초를 넘겨야 의미 있음)
curl -s --cacert /tmp/router-ca.crt -w '\nTIME=%{time_total}\n' \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  "$URL/v1/chat/completions" \
  -d '{"model":"qwen3-8b","max_tokens":4000,"messages":[{"role":"user","content":"파이썬으로 LRU 캐시를 구현하고 시간복잡도를 분석해줘."}]}'
```

**60초 미만 요청으로는 검증이 안 됩니다.** ELB 벽이 60초라 그 아래는 다 통과합니다.

---

## 8. 정리할 때

이 셋업이 만든 것은 전부 `ai-serving` 네임스페이스와 ClusterRoleBinding 2개입니다.
`destroy-cluster.sh` 로 클러스터를 지우면 같이 사라집니다.

클러스터를 남기고 이것만 걷어내려면:

```bash
oc delete deploy,svc,sa,secret,route -n ai-serving -l '!serving.kserve.io/inferenceservice' \
  --field-selector 'metadata.name in (qwen3-gateway,qwen3-api,qwen3-client,qwen3-gateway-cookie,qwen3-8b-authenticated)'
oc delete clusterrolebinding qwen3-8b-auth-delegator qwen3-gateway-auth-delegator
```

**IngressController 와 ELB 타임아웃은 클러스터 전역 설정입니다.**
되돌릴 필요는 없지만, 다른 랩에도 영향이 있다는 것은 알고 계셔야 합니다.
