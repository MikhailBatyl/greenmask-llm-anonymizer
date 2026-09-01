#!/usr/bin/env python3
"""
verify_anonymization.py
Автоматическая верификация остаточных PII-данных после анонимизации Greenmask.

Проверяет:
1. Прямое совпадение строк (оригинал == анонимизированное значение) -> трансформация не сработала
2. Regex-паттерны остаточного PII в СВОБОДНОМ тексте (поля, где формат email/телефон/ИНН
   ожидаем по самому назначению колонки, исключены -- утечку там ловит проверка 1)
3. Проверка достаточности числового шума
4. Опционально: LLM-аудит текстовых полей на предмет утечки конкретики (суммы, ФИО, санкции)

Запуск:
    python3 verify_anonymization.py --source-db sanitize_demo --target-db sanitize_demo_target

Требует: psycopg2, requests (для LLM-аудита)
"""

import argparse
import re
import sys
import json
import psycopg2
from psycopg2.extras import RealDictCursor

PG_CONN_PARAMS = {
    "host": "localhost",
    "port": 5432,
    "user": "root",
    "password": None,
}

TABLES_TO_CHECK = {
    "sanitize_demo.contracts": {
        "pk": "contract_id",
        "text_columns": ["internal_note"],
        "numeric_columns": ["amount"],
        "date_columns": ["signed_date"],
    },
    "sanitize_demo.contract_payments": {
        "pk": "payment_id",
        "text_columns": ["comment"],
        "hashed_columns": ["payer_account"],
        "numeric_columns": ["payment_amount"],
    },
    "sanitize_demo.contractors": {
        "pk": "contractor_id",
        "pii_columns": ["contact_full_name", "contact_email", "contact_phone", "inn", "company_name"],
    },
}

PII_PATTERNS = {
    "email": re.compile(r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"),
    "phone_ru": re.compile(r"(\+7|8)[\s\-]?\(?\d{3}\)?[\s\-]?\d{3}[\s\-]?\d{2}[\s\-]?\d{2}"),
    "inn": re.compile(r"\b\d{10}\b|\b\d{12}\b"),
    "card_number": re.compile(r"\b(?:\d[ -]*?){13,16}\b"),
    "percent_discount": re.compile(r"\bскидк\w*\s*\d{1,2}\s*%"),
}

# Поля, чьё легитимное назначение -- содержать данные такого формата
# (после анонимизации они И ДОЛЖНЫ выглядеть как email/телефон/ИНН, просто
# со сгенерированным значением). Совпадение паттерна здесь -- НЕ утечка,
# реальную утечку (совпадение с оригиналом) ловит check_identical_values.
FIELD_EXPECTED_PATTERN = {
    "contact_email": {"email"},
    "contact_phone": {"phone_ru", "inn"},
    "inn": {"inn"},
    "payer_account": {"inn", "card_number"},
}


def get_connection(dbname, args):
    params = dict(PG_CONN_PARAMS)
    params["dbname"] = dbname
    params["host"] = args.host
    params["port"] = args.port
    params["user"] = args.user
    params["password"] = args.password
    return psycopg2.connect(**params)


def check_identical_values(source_conn, target_conn, table, pk, columns):
    """Проверка 1: строки, где анонимизированное значение совпадает с оригиналом дословно."""
    issues = []
    cols_sql = ", ".join([pk] + columns)

    with source_conn.cursor(cursor_factory=RealDictCursor) as src_cur, \
         target_conn.cursor(cursor_factory=RealDictCursor) as tgt_cur:

        src_cur.execute(f"SELECT {cols_sql} FROM {table} ORDER BY {pk}")
        tgt_cur.execute(f"SELECT {cols_sql} FROM {table} ORDER BY {pk}")

        src_rows = {row[pk]: row for row in src_cur.fetchall()}
        tgt_rows = {row[pk]: row for row in tgt_cur.fetchall()}

        for row_id, src_row in src_rows.items():
            tgt_row = tgt_rows.get(row_id)
            if not tgt_row:
                continue
            for col in columns:
                src_val = src_row.get(col)
                tgt_val = tgt_row.get(col)
                if src_val is not None and src_val == tgt_val:
                    issues.append({
                        "check": "identical_value",
                        "table": table,
                        "row_id": row_id,
                        "column": col,
                        "detail": f"Значение не изменилось: '{src_val}'",
                    })
    return issues


def check_pii_patterns(target_conn, table, pk, columns):
    """Проверка 2: остаточные PII-паттерны, за вычетом полей, где такой формат ожидаем."""
    issues = []
    cols_sql = ", ".join([pk] + columns)

    with target_conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(f"SELECT {cols_sql} FROM {table}")
        for row in cur.fetchall():
            row_id = row[pk]
            for col in columns:
                val = row.get(col)
                if not val:
                    continue
                val_str = str(val)
                expected = FIELD_EXPECTED_PATTERN.get(col, set())
                for pattern_name, pattern in PII_PATTERNS.items():
                    if pattern_name in expected:
                        continue
                    if pattern.search(val_str):
                        issues.append({
                            "check": "residual_pii_pattern",
                            "table": table,
                            "row_id": row_id,
                            "column": col,
                            "pattern": pattern_name,
                            "detail": f"Найден паттерн '{pattern_name}' в значении: '{val_str[:80]}'",
                        })
    return issues


def check_numeric_drift(source_conn, target_conn, table, pk, columns, min_ratio=0.05):
    """Проверка 3: убеждаемся, что числовые поля реально изменены (не остались как есть)."""
    issues = []
    cols_sql = ", ".join([pk] + columns)

    with source_conn.cursor(cursor_factory=RealDictCursor) as src_cur, \
         target_conn.cursor(cursor_factory=RealDictCursor) as tgt_cur:

        src_cur.execute(f"SELECT {cols_sql} FROM {table} ORDER BY {pk}")
        tgt_cur.execute(f"SELECT {cols_sql} FROM {table} ORDER BY {pk}")

        src_rows = {row[pk]: row for row in src_cur.fetchall()}
        tgt_rows = {row[pk]: row for row in tgt_cur.fetchall()}

        for row_id, src_row in src_rows.items():
            tgt_row = tgt_rows.get(row_id)
            if not tgt_row:
                continue
            for col in columns:
                src_val = src_row.get(col)
                tgt_val = tgt_row.get(col)
                if src_val is None or tgt_val is None:
                    continue
                try:
                    src_f, tgt_f = float(src_val), float(tgt_val)
                except (TypeError, ValueError):
                    continue
                if src_f == 0:
                    continue
                diff_ratio = abs(src_f - tgt_f) / abs(src_f)
                if diff_ratio < min_ratio:
                    issues.append({
                        "check": "insufficient_numeric_noise",
                        "table": table,
                        "row_id": row_id,
                        "column": col,
                        "detail": f"Изменение только {diff_ratio:.1%} (ожидалось >= {min_ratio:.0%}): {src_f} -> {tgt_f}",
                    })
    return issues


def run_llm_audit(target_conn, table, pk, columns, webhook_url, webhook_token):
    """Проверка 4 (опционально): LLM-аудит текстовых полей на предмет скрытой конкретики."""
    import requests

    issues = []
    with target_conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(f"SELECT {pk}, {', '.join(columns)} FROM {table}")
        rows = cur.fetchall()

    for row in rows:
        for col in columns:
            val = row.get(col)
            if not val:
                continue
            try:
                resp = requests.post(
                    webhook_url.replace("sanitize-text", "audit-text"),
                    json={"value": val},
                    headers={"Authorization": f"Bearer {webhook_token}"},
                    timeout=30,
                )
                result = resp.json()
                if result.get("contains_pii"):
                    issues.append({
                        "check": "llm_audit",
                        "table": table,
                        "row_id": row[pk],
                        "column": col,
                        "detail": result.get("reason", "LLM пометил как содержащий PII"),
                    })
            except Exception as e:
                issues.append({
                    "check": "llm_audit_error",
                    "table": table,
                    "row_id": row[pk],
                    "column": col,
                    "detail": f"Ошибка запроса аудита: {e}",
                })
    return issues


def main():
    parser = argparse.ArgumentParser(description="Верификация анонимизации Greenmask")
    parser.add_argument("--host", default="localhost")
    parser.add_argument("--port", default=5432, type=int)
    parser.add_argument("--user", default="root")
    parser.add_argument("--password", required=True)
    parser.add_argument("--source-db", default="sanitize_demo")
    parser.add_argument("--target-db", default="sanitize_demo_target")
    parser.add_argument("--llm-audit", action="store_true")
    parser.add_argument("--webhook-url", default=None)
    parser.add_argument("--webhook-token", default=None)
    parser.add_argument("--output", default="verification_report.json")
    args = parser.parse_args()

    source_conn = get_connection(args.source_db, args)
    target_conn = get_connection(args.target_db, args)

    all_issues = []

    for table, cfg in TABLES_TO_CHECK.items():
        pk = cfg["pk"]

        if "text_columns" in cfg:
            all_issues += check_identical_values(source_conn, target_conn, table, pk, cfg["text_columns"])
            all_issues += check_pii_patterns(target_conn, table, pk, cfg["text_columns"])
            if args.llm_audit and args.webhook_url:
                all_issues += run_llm_audit(target_conn, table, pk, cfg["text_columns"], args.webhook_url, args.webhook_token)

        if "numeric_columns" in cfg:
            all_issues += check_numeric_drift(source_conn, target_conn, table, pk, cfg["numeric_columns"])

        if "pii_columns" in cfg:
            all_issues += check_identical_values(source_conn, target_conn, table, pk, cfg["pii_columns"])
            all_issues += check_pii_patterns(target_conn, table, pk, cfg["pii_columns"])

    source_conn.close()
    target_conn.close()

    report = {
        "total_issues": len(all_issues),
        "status": "FAILED" if all_issues else "PASSED",
        "issues": all_issues,
    }

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)

    print(f"\n{'='*60}")
    print(f"РЕЗУЛЬТАТ ВЕРИФИКАЦИИ: {report['status']}")
    print(f"Найдено проблем: {report['total_issues']}")
    print(f"{'='*60}\n")

    if all_issues:
        for issue in all_issues[:20]:
            print(f"  [{issue['check']}] {issue['table']}.{issue.get('column','')} row_id={issue['row_id']}: {issue['detail']}")
        if len(all_issues) > 20:
            print(f"  ... и ещё {len(all_issues) - 20} проблем, см. {args.output}")
        sys.exit(1)
    else:
        print("Все проверки пройдены успешно. Остаточных PII-данных не обнаружено.")
        sys.exit(0)


if __name__ == "__main__":
    main()
