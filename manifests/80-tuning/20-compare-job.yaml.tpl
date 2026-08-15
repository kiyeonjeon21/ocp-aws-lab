# 학습 전후를 같은 질문으로 비교합니다.
#
# ------------------------------------------------------------------
# 왜 이 Job 이 필요한가
# ------------------------------------------------------------------
# "PyTorchJob 이 Succeeded 이고 어댑터 파일이 생겼다" 는 학습이 됐다는 증거가 아닙니다.
# 손실이 안 내려갔어도, 데이터가 잘못 토크나이즈됐어도 파일은 똑같이 생깁니다.
#
# 실제 증거는 **같은 질문에 답이 달라지는 것**입니다.
# 그래서 베이스 모델과 어댑터를 붙인 모델에 같은 질문을 던지고 나란히 출력합니다.
#
# 이건 Job 입니다. PyTorchJob 이 아닙니다.
# 분산 배선이 필요 없는 단일 추론이라 여기서 PyTorchJob 을 쓰면 과합니다.
# 무엇을 언제 쓰는지가 이 두 파일의 대비입니다.
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: tuning-compare-code
  namespace: ${RHOAI_NAMESPACE}
data:
  compare.py: |
    import os, torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    BASE = os.environ["TUNE_BASE_MODEL"]
    ADAPTER = os.environ["TUNE_ADAPTER"]

    QUESTIONS = [
        "이 랩의 GPU 인스턴스 타입은?",
        "이 랩의 벡터 DB 는?",
        "이 랩은 llm-d 를 쓸 수 있나?",
    ]

    tok = AutoTokenizer.from_pretrained(BASE)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token

    def ask(model, q):
        msgs = [{"role": "user", "content": q}]
        text = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
        ids = tok(text, return_tensors="pt").to(model.device)
        # 온도를 안 씁니다. 두 모델을 비교하는 자리라 무작위성이 섞이면 안 됩니다.
        out = model.generate(**ids, max_new_tokens=80, do_sample=False,
                             pad_token_id=tok.pad_token_id)
        return tok.decode(out[0][ids["input_ids"].shape[1]:], skip_special_tokens=True).strip()

    print("=" * 70, flush=True)
    print("베이스 모델 (학습 전)", flush=True)
    print("=" * 70, flush=True)
    base = AutoModelForCausalLM.from_pretrained(BASE, torch_dtype=torch.bfloat16, device_map="cuda")
    base.eval()
    before = {}
    for q in QUESTIONS:
        before[q] = ask(base, q)
        print(f"\nQ. {q}\nA. {before[q]}", flush=True)

    del base
    torch.cuda.empty_cache()

    print("\n" + "=" * 70, flush=True)
    print("어댑터 적용 (학습 후)", flush=True)
    print("=" * 70, flush=True)
    from peft import PeftModel
    m = AutoModelForCausalLM.from_pretrained(BASE, torch_dtype=torch.bfloat16, device_map="cuda")
    m = PeftModel.from_pretrained(m, ADAPTER)
    m.eval()
    for q in QUESTIONS:
        after = ask(m, q)
        print(f"\nQ. {q}\nA. {after}", flush=True)
        print(f"   [달라졌나] {'예' if after != before[q] else '아니오'}", flush=True)
---
apiVersion: batch/v1
kind: Job
metadata:
  name: lora-compare
  namespace: ${RHOAI_NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: compare
          image: ${IMAGE_TRAINING}
          command: ["/bin/sh", "-lc"]
          args:
            - |
              set -e
              python -c "import peft" 2>/dev/null || pip install --no-cache-dir peft
              exec python /code/compare.py
          env:
            - name: TUNE_BASE_MODEL
              value: "${TUNE_BASE_MODEL}"
            - name: TUNE_ADAPTER
              value: "/out/${TUNE_ADAPTER_NAME}"
            - name: HOME
              value: "/tmp"
            - name: HF_HOME
              value: "/tmp/hf"
          resources:
            requests:
              cpu: "2"
              memory: 8Gi
              nvidia.com/gpu: 1
            limits:
              cpu: "3"
              memory: 12Gi
              nvidia.com/gpu: 1
          volumeMounts:
            - name: code
              mountPath: /code
            - name: out
              mountPath: /out
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: code
          configMap:
            name: tuning-compare-code
        - name: out
          persistentVolumeClaim:
            claimName: tuning-output
        - name: tmp
          emptyDir: {}
