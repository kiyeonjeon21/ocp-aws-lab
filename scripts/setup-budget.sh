#!/usr/bin/env bash
# AWS Budgets 알림 생성. 백스톱이지 주 방어선이 아닙니다.
#
#   ./scripts/setup-budget.sh                    # .env 의 BUDGET_LIMIT / BUDGET_EMAIL
#   ./scripts/setup-budget.sh 20 me@example.com
#
# Budgets 는 청구 데이터 자체가 8~24시간 지연됩니다. 시간당 \$0.93 짜리
# 클러스터를 방치했을 때 알림이 울릴 즈음엔 이미 \$20 이 나간 뒤입니다.
# 실제 방어선은 실습 직후 destroy-cluster.sh 를 돌리는 습관입니다.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env

LIMIT="${1:-${BUDGET_LIMIT:-20}}"
EMAIL="${2:-${BUDGET_EMAIL:-}}"
[[ -n "$EMAIL" ]] || die "알림 받을 이메일이 필요합니다. .env 에 BUDGET_EMAIL 을 넣거나 인자로 주세요."

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
NAME="ocp-aws-lab"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/budget.json" <<EOF
{
  "BudgetName": "$NAME",
  "BudgetLimit": { "Amount": "$LIMIT", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
EOF

# 실제 지출 50%(조기 경보)와 예측 100%(추세 경보) 두 지점에서 알립니다.
cat > "$TMP/notify.json" <<EOF
[
  {
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 50,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [ { "SubscriptionType": "EMAIL", "Address": "$EMAIL" } ]
  },
  {
    "Notification": {
      "NotificationType": "FORECASTED",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 100,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [ { "SubscriptionType": "EMAIL", "Address": "$EMAIL" } ]
  }
]
EOF

head1 "예산 알림 설정"
info "월 한도 \$$LIMIT, 알림 대상 $EMAIL"

if aws budgets describe-budget --account-id "$ACCOUNT_ID" --budget-name "$NAME" >/dev/null 2>&1; then
  aws budgets update-budget --account-id "$ACCOUNT_ID" --new-budget "file://$TMP/budget.json"
  ok "기존 예산 '$NAME' 갱신"
else
  aws budgets create-budget --account-id "$ACCOUNT_ID" \
    --budget "file://$TMP/budget.json" \
    --notifications-with-subscribers "file://$TMP/notify.json"
  ok "예산 '$NAME' 생성"
fi

printf "\n"
warn "$EMAIL 로 구독 확인 메일이 갈 수 있습니다. 확인해야 알림이 옵니다."
warn "다시 강조하면, 이건 백스톱입니다. 실습이 끝나면 바로 destroy 하세요."
printf "\n"
