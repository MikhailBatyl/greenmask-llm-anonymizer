#!/bin/bash
# llm_anonymize.sh
# Обёртка для Greenmask Cmd-трансформера (JSON driver, text format).
#
# Официальный формат Greenmask JSON-driver (по одной строке на вызов):
#   Вход:  {"internal_note": {"d": "текст", "n": false}}
#   Выход: {"internal_note": {"d": "результат", "n": false}}

set -uo pipefail

trap 'exit 0' TERM

N8N_URL="${N8N_WEBHOOK_URL:?N8N_WEBHOOK_URL is not set}"
N8N_TOKEN="${N8N_WEBHOOK_TOKEN:?N8N_WEBHOOK_TOKEN is not set}"
TIMEOUT_SEC="${LLM_TIMEOUT_SEC:-45}"

while IFS= read -r LINE; do
  [ -z "$LINE" ] && continue

  FIELD_NAME=$(echo "$LINE" | jq -r 'keys[0]')
  IS_NULL=$(echo "$LINE" | jq -r ".[\"$FIELD_NAME\"].n // false")
  VALUE=$(echo "$LINE" | jq -r ".[\"$FIELD_NAME\"].d // empty")

  if [ "$IS_NULL" = "true" ] || [ -z "$VALUE" ]; then
    echo "$LINE"
    continue
  fi

  PAYLOAD=$(jq -n \
    --arg field_type "$FIELD_NAME" \
    --arg value "$VALUE" \
    '{field_type: $field_type, value: $value, context: {table: "unknown", row_id: null}}')

  RESPONSE=$(curl -s --max-time "$TIMEOUT_SEC" -X POST "$N8N_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $N8N_TOKEN" \
    -d "$PAYLOAD")

  RESULT=$(echo "$RESPONSE" | jq -r '.result // empty')

  if [ -z "$RESULT" ]; then
    RESULT="$VALUE"
  fi

  jq -n --arg field "$FIELD_NAME" --arg result "$RESULT" \
    '{($field): {"d": $result, "n": false}}'
done