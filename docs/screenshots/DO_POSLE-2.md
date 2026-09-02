# Отчёт "До / После": команды и результаты прогона

Этот файл фиксирует полный набор команд, использованных для получения
скриншотов `docs/screenshots/01_before_data.png` -- `09_after_contractors.png`,
и позволяет любому воспроизвести проверку самостоятельно.

## 1. Данные ДО анонимизации (исходная схема sanitize_demo)

```bash
docker exec -it n8n-postgres-1 psql -U root -d sanitize_demo -c \
  "SELECT contract_id, internal_note FROM sanitize_demo.contracts WHERE internal_note IS NOT NULL LIMIT 10;"

docker exec -it n8n-postgres-1 psql -U root -d sanitize_demo -c \
  "SELECT payment_id, contract_id, comment, payer_account FROM sanitize_demo.contract_payments LIMIT 10;"
```

Результат зафиксирован в `docs/screenshots/01_before_data.png`: видны реальные
тестовые формулировки ("Приоритетный партнёр, скидка 8%") и номера счетов
вида `40702810001000000037`.

## 2. Запуск пайплайна

```bash
cd /opt/projects/greenmask-lab
./run_pipeline.sh
```

Полный лог (Шаг 0/4 -> Шаг 4/4, включая dump, restore и встроенную
верификацию) зафиксирован в `docs/screenshots/02_pipeline_run.png`.
Финальный статус: `PIPELINE PASSED`.

## 2а. Детальный debug-лог dump (низкоуровневая проверка)

Отдельно от `run_pipeline.sh` можно запустить сам dump в режиме debug,
чтобы увидеть работу Cmd-трансформера на уровне процесса:

```bash
docker compose -f docker-compose.greenmask.yml run --rm greenmask dump \
  --config config.yml --log-level=debug
```

Лог зафиксирован в `docs/screenshots/07_greenmask_dump_debug.png`:
видна инициализация внешнего скрипта `/scripts/llm_anonymize.sh` как
`TransformerName=Cmd` для таблиц `contracts` и `contract_payments`,
использование pgcopy (`COPY "sanitize_demo"."contracts" TO STDOUT`)
и штатное завершение процесса трансформера (`SIGTERM` -> `terminated
successfully`, `TransformerPid=16`).

## 3. n8n Executions

- `sanitize-text` (парафраз текста через LLM) -- `docs/screenshots/03_n8n_sanitize_execution.png`
- `audit-text` (независимая LLM-проверка отсутствия PII) -- `docs/screenshots/04_n8n_audit_execution.png`

Пример трансформации, зафиксированный в execution:
`"Плановый транш 2"` -> `"Регулярный транш, номер 2"`.
Результат аудита: `{"contains_pii": false, "reason": "..."}`.

## 4. Данные ПОСЛЕ анонимизации (target-схема sanitize_demo_target)

```bash
docker exec -it n8n-postgres-1 psql -U root -d sanitize_demo_target -c \
  "SELECT contract_id, internal_note FROM sanitize_demo.contracts WHERE internal_note IS NOT NULL LIMIT 10;"

docker exec -it n8n-postgres-1 psql -U root -d sanitize_demo_target -c \
  "SELECT payment_id, contract_id, comment, payer_account FROM sanitize_demo.contract_payments LIMIT 10;"
```

Результат зафиксирован в `docs/screenshots/05_after_data.png`: те же
`contract_id`/`payment_id`, но текст переформулирован LLM с сохранением
смысла, а `payer_account` заменён на необратимый хеш.

## 4а. Данные ДО/ПОСЛЕ анонимизации: таблица contractors

Схема таблицы:

```bash
docker exec -it n8n-postgres-1 psql -U root -d sanitize_demo -c "\d sanitize_demo.contractors"
```

```
Table "sanitize_demo.contractors"
  contractor_id     | integer                     | not null, PK
  company_name      | character varying(200)      | not null
  inn                | character varying(12)       | not null
  contact_full_name | character varying(150)      | not null
  contact_email     | character varying(150)      | not null
  contact_phone     | character varying(20)       | not null
  city               | character varying(100)      |
  created_at         | timestamp without time zone | default now()
```

Команды для получения данных:

```bash
docker exec -it n8n-postgres-1 psql -U root -d sanitize_demo -c \
  "SELECT * FROM sanitize_demo.contractors LIMIT 10;"

docker exec -it n8n-postgres-1 psql -U root -d sanitize_demo_target -c \
  "SELECT * FROM sanitize_demo.contractors LIMIT 10;"
```

Результаты зафиксированы в `docs/screenshots/08_before_contractors.png`
(исходные данные) и `docs/screenshots/09_after_contractors.png` (после
анонимизации).

ДО: реальные названия российских компаний (например, ООО "СибМеталлТранс"),
настоящие ИНН (10-значные числовые), реальные ФИО контактных лиц, корпоративные
email-адреса на доменах компаний, российские номера телефонов формата +7913...

ПОСЛЕ: `company_name` заменён на синтетическое англоязычное название
(например, "Dynamic Resources LLC."), `contact_full_name` -- на
сгенерированное имя, `contact_email` -- локальная часть адреса заменена
хешем, домен заменён на публичный почтовый сервис (yandex.com, yahoo.com,
zoho.com и т. п.), `contact_phone` -- случайная последовательность цифр,
`inn` -- 10-символьный hex-хеш.

**Известные ограничения**:

- `inn` заменён на hex-хеш, а не на валидный числовой формат ИНН (10/12 цифр); исходный формат (числовой, начинающийся с кода региона) не сохранён
- сгенерированные ФИО и названия компаний англоязычные, тогда как исходные данные -- русскоязычные; `city` при этом остаётся русским
- `contact_email` меняет домен на публичные почтовые сервисы вместо сохранения корпоративного домена компании
- поле `created_at` одинаково во всех 10 строках как ДО, так и ПОСЛЕ анонимизации (`2026-08-30 16:03:14.76869`) -- это особенность генерации тестовых данных, а не артефакт трансформации Greenmask

## 5. Отдельная верификация

```bash
python3 verify_anonymization.py \
  --host 127.0.0.1 \
  --port 5432 \
  --user root \
  --password "$(grep -E '^PGPASSWORD=' .env | cut -d= -f2)" \
  --source-db sanitize_demo \
  --target-db sanitize_demo_target \
  --llm-audit \
  --webhook-url "$(grep -E '^N8N_WEBHOOK_URL=' .env | cut -d= -f2)" \
  --webhook-token "$(grep -E '^N8N_WEBHOOK_TOKEN=' .env | cut -d= -f2)" \
  --output verification_report.json
```

Результат: `PASSED`, `Найдено проблем: 0` --
`docs/screenshots/06_verification_passed.png`.

## Итоговое сравнение (пример трёх строк, contracts/payments)

| contract_id | ДО | ПОСЛЕ |
|---|---|---|
| 3 | Приоритетный партнёр, скидка 8% | Приоритетный партнёр, действуют льготные условия |
| 4 | Высокий риск срыва сроков, штрафные санкции применены ранее | Повышенный риск нарушения сроков, ранее применялись санкции |
| 5 | Конфиденциальные маршруты, ограниченный доступ к данным | Ограниченные маршруты, защищённый доступ к информации |

| payment_id | ДО (payer_account) | ПОСЛЕ (payer_account) |
|---|---|---|
| 1 | 40702810001000000037 | 1a83edb4c0080a1cbb111bf88e25e208 |
| 2 | 40702810001000000038 | 44168ae5c360b1e1889d695a8b8308ae |

## Итоговое сравнение: contractors (пример трёх строк)

| contractor_id | Поле | ДО | ПОСЛЕ |
|---|---|---|---|
| 1 | company_name | ООО "СибМеталлТранс" | Dynamic Resources LLC. |
| 1 | inn | 5401234567 | c555ea5a0f |
| 1 | contact_full_name | Иванов Пётр Сергеевич | Martine Morissette |
| 1 | contact_email | ivanov.ps@sibmetaltrans.ru | f4a6e24200dbb75c9d9b@yandex.com |
| 1 | contact_phone | +79131234501 | +789143510627 |
| 2 | company_name | АО "УралАлюминийСервис" | Apex Resources Inc. |
| 2 | inn | 6607654321 | 8d5511a92d |
| 2 | contact_full_name | Смирнова Ольга Дмитриевна | Kariane Kilback |
| 2 | contact_email | smirnova.od@uralalum.ru | e9c1826d260b2b39f114@yahoo.com |
| 2 | contact_phone | +79021234502 | +856239147810 |
| 3 | company_name | ООО "БратскСтройМонтаж" | Prime Enterprises Corp. |
| 3 | inn | 3808112233 | d56025ba1a |
| 3 | contact_full_name | Кузнецов Артём Игоревич | Devonte O'Conner |
| 3 | contact_email | kuznetsov.ai@bratskstroy.ru | 18083462159e85a4e548@aol.com |
| 3 | contact_phone | +79231234503 | +793107286154 |
