# Qwen3 thinking 과 자체 호스팅

RHOAI(vLLM)에 `Qwen3-8B`를 올려 OpenRouter의 같은 모델과 비교하려다 부딪힌 것들을 정리합니다.
결론부터 적으면 **"thinking을 켜면 답을 못 얻는다"는 진단이 틀렸고, 토큰 예산이 모자랐던 것**입니다.

측정 환경은 `g6.xlarge`(NVIDIA L4 24GB), OCP 4.22.6, RHOAI 3.5.0, vLLM 0.24.0+rhaiv.9 입니다.

---

## 1. thinking 은 되고 있었습니다

같은 질문에 `max_tokens`만 바꿔 측정한 값입니다.
질문은 "파이썬으로 이진 탐색 트리를 구현하고 삽입 삭제 탐색 순회를 모두 자세히 설명해줘."입니다.

| `max_tokens` | 소요 | `finish_reason` | reasoning | content |
| --- | --- | --- | --- | --- |
| 900 | 55초 | `length` | 4,059자 | **0자** |
| 2000 | 130초 | `length` | 9,079자 | **0자** |
| **4000** | 201초 | **`stop`** | 7,326자 | **4,958자** |

4000에서는 3,273토큰만 쓰고 자연 종료했습니다.
**thinking 이 망가진 게 아니라, 생각을 끝내기 전에 예산이 떨어졌던 것**입니다.

`length`로 끊기면 본문이 한 글자도 안 나옵니다.
thinking 이 먼저 나오고 본문이 뒤에 오는 구조라 그렇습니다.
에이전트 하네스 입장에서는 본문도 툴 콜도 없으니 그냥 실패로 보입니다.

### 질문 난이도에 따른 차이

| 질문 | completion_tokens | reasoning | content |
| --- | --- | --- | --- |
| "2+2는?" (3회 반복) | 163 ~ 190 | 0자 | 12 ~ 41자 |
| "대한민국 수도는?" | 397 | 0자 | 149자 |
| 이진 탐색 트리 전체 설명 | 3,273 | 7,326자 | 4,958자 |

쉬운 질문은 thinking 을 거의 안 합니다.
어려워질수록 급격히 길어지고, 그때 예산이 부족하면 본문이 통째로 사라집니다.

**그래서 "thinking off 로 하면 쉬운 건 되는데 어려운 건 안 된다"는 관찰이 나옵니다.**
thinking off 는 어려운 문제에서 실제로 정확도가 떨어지고,
thinking on 은 예산이 모자라면 아예 답이 안 나옵니다. 증상이 달라 보이지만 같은 축의 양끝입니다.

### 권장값

에이전트 과제라면 `max_tokens`를 **4000 이상**으로 둡니다.
컨텍스트가 32768이므로 프롬프트가 27k쯤 되면 4000도 빠듯합니다. 그때는 컨텍스트부터 늘려야 합니다.

---

## 2. OpenRouter 와 thinking 길이가 다른 이유

같은 가중치인데 thinking 길이가 3~7배 차이 났습니다.
(OpenRouter reasoning 델타 120 대 자체 호스팅 317~899)

의심 순서대로 적습니다.

### 2.1 샘플링 파라미터 - 아님

이걸 먼저 의심했지만 아니었습니다.
vLLM 이 모델의 `generation_config.json`을 자동으로 읽어 적용하고 있었습니다.

```text
Default vLLM sampling parameters have been overridden by the model's
generation_config.json: {'temperature': 0.6, 'top_k': 20, 'top_p': 0.95}
```

Qwen3 공식 권장값(thinking 모드: temperature 0.6 / top_p 0.95 / top_k 20)과 같습니다.
`--generation-config`의 기본값이 `auto`라 알아서 됩니다.

### 2.2 KV 캐시 정밀도 - 유력. 그리고 우리가 만든 변수

L4 24GB에 32768 컨텍스트를 넣으려고 `--kv-cache-dtype=fp8`을 켰습니다.

| 설정 | Available KV cache | KV cache 토큰 |
| --- | --- | --- |
| 기본(bf16) | 3.31 GiB | 24,064 |
| **fp8** | 3.75 GiB | **54,576** |

가중치가 15.27 GiB를 먹어서 KV 캐시에 3~4 GiB밖에 안 남습니다.
`max-model-len`은 KV 캐시 토큰 수를 넘을 수 없으므로, fp8 없이는 32768 자체가 불가능합니다.

**대신 어텐션 수치가 달라집니다.**
긴 생성에서 오차가 누적되면 모델이 확신을 덜 갖고 thinking 이 길어질 수 있습니다.
OpenRouter 쪽이 이걸 쓸 이유는 없습니다. 메모리가 넉넉한 GPU를 쓸 테니까요.

**공정 비교를 원하면 이 설정을 빼야 하고, 그러면 컨텍스트가 24,064로 내려갑니다.**
둘 중 하나를 포기해야 하는 트레이드오프입니다. 어느 쪽을 택하든 결과에 명시해야 합니다.

### 2.3 가중치 정밀도 - 확인 불가

우리는 HuggingFace 원본 fp16입니다.
OpenRouter 제공자들은 FP8이나 AWQ로 서빙하는 경우가 흔하고, 그러면 생성 토큰 자체가 달라집니다.
어느 제공자가 어떤 양자화를 쓰는지는 공개되지 않아 대조가 안 됩니다.

### 2.4 GPU 차이 - 가능하지만 영향이 가장 작음

L4(Ada)와 H100(Hopper)은 커널 구현과 리덕션 순서가 다릅니다.
우리 쪽은 fp8 KV 캐시 때문에 `FLASHINFER` 백엔드가 선택됐습니다.

```text
Using FLASHINFER attention backend out of potential backends: ['FLASHINFER', 'TRITON_ATTN']
```

부동소수점 결합법칙이 성립하지 않아 미세한 차이는 납니다.
다만 thinking 길이가 몇 배씩 벌어질 요인으로 보기는 어렵습니다.
**2.2와 2.3이 먼저이고, GPU 자체는 마지막입니다.**

---

## 3. 처리량은 하드웨어 한계입니다

단일 스트림 16.1 tok/s가 낮아 보이지만 오설정이 아닙니다.

```text
L4 메모리 대역폭       약 300 GB/s
Qwen3-8B fp16 가중치   15.27 GiB
이론 상한              300 / 16.4 ≈ 18.3 tok/s
실측                   16.1 tok/s  →  이론치의 약 88%
```

디코딩은 토큰마다 가중치 전체를 읽는 메모리 대역폭 바운드 작업입니다.
`--enforce-eager`는 꺼져 있고(CUDA 그래프 정상), `--gpu-memory-utilization`은 0.92입니다.
설정으로 개선할 여지가 거의 없고, 읽는 바이트를 줄여야(AWQ/FP8 가중치) 빨라집니다.

**동시 요청에서는 선형에 가깝게 오릅니다.**

| 동시 요청 | 합산 처리량 |
| --- | --- |
| 1건 | 16.1 tok/s |
| 2건 | 31.2 tok/s |

KV 캐시가 54,576토큰이고 32768 기준 동시성 1.67배라, 벤치마크를 2병렬로 돌리면 전체 시간이 거의 절반입니다.

**tok/s 는 OpenRouter 와 공정 비교가 안 되는 항목입니다.** 하드웨어가 다릅니다. 정확도만 비교하세요.

---

## 4. 서빙 설정

```text
--served-model-name=qwen3-8b
--gpu-memory-utilization=0.92
--max-model-len=32768
--kv-cache-dtype=fp8            # 32768 을 위해 필수. 2.2 의 트레이드오프
--enable-auto-tool-choice
--tool-call-parser=hermes
--reasoning-parser=qwen3        # reasoning_content 로 분리. 없으면 본문에 <think> 가 섞임
```

`--reasoning-parser=qwen3`가 없으면 `content`에 `<think>...</think>`가 그대로 들어갑니다.

thinking 을 서버에서 끄려면 이걸 추가합니다.

```text
--default-chat-template-kwargs={"enable_thinking": false}
```

`--chat-template-kwargs`가 아니라 **`--default-chat-template-kwargs`** 입니다. vLLM 0.24 기준입니다.

### thinking 예산 제한은 이 버전에 없습니다

`--reasoning-config`가 있어서 예산 제한인 줄 알았는데 아니었습니다.
`ReasoningConfig`의 필드는 파서와 시작/종료 문자열뿐입니다.

```text
reasoning_parser / reasoning_start_str / reasoning_end_str
_reasoning_start_token_ids / _reasoning_end_token_ids / _enabled
```

**thinking 은 on/off 이분법이고, "짧게 생각하기"를 서버에서 강제할 수단이 없습니다.**
조절하려면 `max_tokens`를 키우거나 요청 단위로 끄는 수밖에 없습니다.

---

## 5. 비교 실험을 설계할 때

같은 모델 이름이어도 조건이 여러 개 다릅니다. 결과에 같이 적어야 결론이 왜곡되지 않습니다.

| 항목 | 자체 호스팅(L4) | OpenRouter |
| --- | --- | --- |
| 컨텍스트 | **32,768** | 131,072 |
| KV 캐시 | **fp8** | 불명(아마 bf16) |
| 가중치 | fp16 원본 | 불명(FP8/AWQ 가능) |
| thinking 기본 | on | on |
| 단일 처리량 | 16.1 tok/s | 불명 |

**131,072는 L4 24GB에서 물리적으로 불가능합니다.** KV 캐시 상한이 54,576토큰입니다.
프롬프트 중앙값이 27k인 과제라면 32768로 대부분 커버되지만 일부는 초과합니다.
초과로 실패한 런은 따로 세야 정확도 비교가 오염되지 않습니다.

### 체크리스트

- [ ] `max_tokens` 4000 이상 (thinking on 기준)
- [ ] 컨텍스트 초과로 실패한 런을 별도 집계
- [ ] `--kv-cache-dtype=fp8` 사용 여부를 결과에 명시
- [ ] tok/s 는 비교 대상에서 제외
- [ ] thinking on/off 를 양쪽 동일하게 맞췄는지

---

## 6. 같이 걸렸던 것: 타임아웃이 세 겹

thinking 을 켜면 응답이 길어져 타임아웃에 걸립니다. 벽이 세 개였고 하나씩 드러났습니다.

| 구간 | 기본값 | 증상 | 해결 |
| --- | --- | --- | --- |
| `kube-rbac-proxy` `--upstream-timeout` | 30초 | 502 at 30.01초 | **수정 불가.** KServe 가 args 를 되돌림 |
| `oauth-proxy` `--upstream-timeout` | 30초 | 502 at 30.02초 | 우리 Deployment 라 600s 로 수정 |
| Classic ELB `IdleTimeout` | 60초 | 빈 응답 at 60.0초 | 600 으로 수정 |
| 라우터 haproxy `timeout client` | 30초 | (위에 가려 안 보였음) | `tuningOptions` 로 600s |

**앞의 벽을 치우면 다음 벽이 나옵니다.**
30초를 넘기자 60초가 나왔습니다. 한 번 고치고 "됐다"고 하면 안 되고, 실제 최대 길이로 다시 재야 합니다.

### KServe 의 kube-rbac-proxy 는 못 고칩니다

`InferenceService`에 auth 를 켜면 KServe 가 `kube-rbac-proxy` 사이드카를 주입하는데,
args 가 컨트롤러 바이너리에 하드코딩돼 있습니다.

```text
oc patch deploy ...        -> 5초 만에 되돌려짐
inferenceservice-config    -> image/cpu/memory 만 있고 args 없음
```

**우회 방법은 우리가 관리하는 프록시를 따로 세우는 것**입니다.
`qwen3-8b-predictor` 서비스(8080, vLLM 직결)를 업스트림으로 삼는 `oauth-proxy` Deployment 를 만들면
사이드카를 안 거치고 타임아웃도 우리가 정합니다.

주의: 그 서비스는 **headless**(`clusterIP: None`)입니다.
DNS 가 파드 IP 를 그대로 주므로 포트 매핑(80 -> 8080)이 동작하지 않습니다. 업스트림에 **8080 을 직접** 써야 합니다.

---

## 7. 한 줄 요약

- thinking 은 정상 동작한다. `max_tokens` 4000 이상이면 본문이 나온다
- OpenRouter 와의 thinking 길이 차이는 **우리가 켠 fp8 KV 캐시**가 가장 유력하다. GPU 자체는 마지막 용의자다
- 32768 컨텍스트와 fp8 미사용은 L4 24GB 에서 양립하지 않는다
- tok/s 는 메모리 대역폭 한계라 설정으로 못 올린다. 비교 항목에서 빼라
- 타임아웃은 프록시 30초, ELB 60초로 두 겹이었다
