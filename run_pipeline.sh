#!/usr/bin/env bash
#
# run_pipeline.sh
# Единая точка входа: прогоняет весь пайплайн анонимизации от старта до
# автоматической верификации, останавливаясь на первой же ошибке.
#
# Порядок шагов:
#   0. Проверка предпосылок (env, доступность n8n webhook)
#   1. Greenmask dump (с LLM-трансформацией через n8n)
#   2. Greenmask restore в target-базу
#   3. Автоматическая верификация (verify_anonymization.py, включая LLM-аудит)
#   4. Итоговый отчёт
#
# Запуск:
#   ./run_pipeline.sh
#
# Требует: .env файл в корне проекта (см. .env.example), docker compose, python3+venv

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- Цвета для наглядного лога ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_step()  { echo -e "\n${YELLOW}==> $1${NC}"; }
log_ok()    { echo -e "${GREEN}✓ $1${NC}"; }
log_fail()  { echo -e "${RED}✗ $1${NC}"; }

# --- Шаг 0: загрузка окружения и проверка предпосылок ---
log_step "Шаг 0/4: Проверка окружения"

if [ ! -f .env ]; then
  log_fail ".env не найден. Скопируйте .env.example -> .env и заполните значения."
  exit 1
fi
set -a
source .env
set +a

for var in PGHOST PGPORT PGUSER PGPASSWORD PG_SOURCE_DB PG_TARGET_DB N8N_WEBHOOK_URL N8N_WEBHOOK_TOKEN; do
  if [ -z "${!var:-}" ]; then
    log_fail "Переменная $var не задана в .env"
    exit 1
  fi
done
log_ok "Все обязательные переменные окружения заданы"

log_step "Проверка доступности n8n webhook (sanitize-text)"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$N8N_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $N8N_WEBHOOK_TOKEN" \
  -d '{"internal_note": {"d": "проверка связи перед запуском", "n": false}}' \
  --max-time 15 || echo "000")

if [ "$HTTP_CODE" != "200" ]; then
  log_fail "n8n webhook недоступен или вернул код $HTTP_CODE. Проверьте, что workflow активирован (Published)."
  exit 1
fi
log_ok "n8n webhook отвечает (HTTP $HTTP_CODE)"

# --- Шаг 1: dump ---
log_step "Шаг 1/4: Greenmask dump (структурированные поля + LLM-парафраз текста)"

DUMP_OUTPUT=$(docker compose -f docker-compose.greenmask.yml run --rm greenmask --config=/config.yml dump 2>&1) \
  || { log_fail "Dump завершился с ошибкой"; echo "$DUMP_OUTPUT"; exit 1; }

echo "$DUMP_OUTPUT"

DUMP_ID=$(docker compose -f docker-compose.greenmask.yml run --rm greenmask --config=/config.yml list-dumps 2>/dev/null \
  | grep "$PG_SOURCE_DB" | grep "done" | head -n1 | awk '{print $2}')

if [ -z "$DUMP_ID" ]; then
  log_fail "Не удалось найти успешный dump со статусом 'done' в list-dumps"
  exit 1
fi
log_ok "Dump успешно завершён, ID: $DUMP_ID"

# --- Шаг 2: restore ---
log_step "Шаг 2/4: Restore анонимизированного дампа в $PG_TARGET_DB"

docker compose -f docker-compose.greenmask.yml run --rm greenmask --config=/config.yml restore latest \
  || { log_fail "Restore завершился с ошибкой"; exit 1; }

log_ok "Restore завершён успешно"

# --- Шаг 3: автоматическая верификация ---
log_step "Шаг 3/4: Верификация анонимизации (identical values, PII patterns, numeric drift, LLM audit)"

if [ ! -d venv ]; then
  log_step "Виртуальное окружение не найдено, создаю..."
  python3 -m venv venv
  source venv/bin/activate
  pip install -q psycopg2-binary requests
else
  source venv/bin/activate
fi

set +e
python3 verify_anonymization.py \
  --host "$PGHOST" --port "$PGPORT" --user "$PGUSER" \
  --password "$PGPASSWORD" \
  --source-db "$PG_SOURCE_DB" --target-db "$PG_TARGET_DB" \
  --llm-audit \
  --webhook-url "$N8N_WEBHOOK_URL" \
  --webhook-token "$N8N_WEBHOOK_TOKEN" \
  --output verification_report.json
VERIFY_EXIT_CODE=$?
set -e

# --- Шаг 4: итоговый отчёт ---
log_step "Шаг 4/4: Итоговый статус пайплайна"

if [ "$VERIFY_EXIT_CODE" -eq 0 ]; then
  log_ok "PIPELINE PASSED: dump создан, restore выполнен, верификация не нашла проблем"
  echo -e "  Dump ID: $DUMP_ID"
  echo -e "  Отчёт верификации: verification_report.json"
  exit 0
else
  log_fail "PIPELINE FAILED: верификация обнаружила проблемы"
  echo -e "  Отчёт с деталями: verification_report.json"
  exit 1
fi
