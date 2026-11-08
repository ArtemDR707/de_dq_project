#!/usr/bin/env python3
"""Подставляет фактические числа из psql -At -F'|' -f audit_counts.sql.

Работает только с исходными подсчётами и не вычисляет/не придумывает значения.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("counts_file", type=Path)
    parser.add_argument("--report", type=Path, default=Path("audit_report.md"))
    args = parser.parse_args()

    lines = args.counts_file.read_text(encoding="utf-8").splitlines()
    counts: dict[str, int] = {}
    missing_months: list[tuple[str, int]] = []
    for raw_line in lines:
        row = [c.strip() for c in raw_line.split("|")]
        if len(row) == 2 and re.fullmatch(r"\d{2}_[a-z0-9_]+", row[0]):
            counts[row[0]] = int(row[1])
        if len(row) == 4 and re.fullmatch(r"\d{4}-\d{2}-\d{2}", row[0]):
            if row[3] == "INCOMPLETE_MONTH":
                missing_months.append((row[0], int(row[1])))

    expected = [
        "01_orders_customer_id_with_spaces",
        "02_orders_customer_id_prefixed",
        "03_orders_customer_id_unrecoverable",
        "04_orders_product_id_orphan",
        "05_orders_promo_id_orphan",
        "06_customers_phone_missing",
        "07_customers_birth_future",
        "08_customers_age_invalid_at_registration",
        "09_customers_email_invalid_nonblank",
        "10_customers_email_missing",
        "11_customers_city_numeric",
        "12_orders_total_amount_null",
        "13_orders_total_amount_nonpositive",
        "14_orders_total_amount_outlier_x3",
        "15_orders_null_total_without_source_product",
    ]
    absent = [k for k in expected if k not in counts]
    if absent:
        raise RuntimeError(f"Отсутствуют результаты audit_counts.sql: {absent}")

    counts["GAP_MONTHS"] = len(missing_months)
    counts["GAP_ROWS"] = sum(n for _, n in missing_months)
    report = args.report.read_text(encoding="utf-8")

    def substitute(m: re.Match[str]) -> str:
        return str(counts[m.group(1)]) if m.group(1) in counts else m.group(0)

    updated = re.sub(r"\{\{([A-Za-z0-9_]+)\}\}", substitute, report)
    if re.search(r"\{\{[A-Za-z0-9_]+\}\}", updated):
        raise RuntimeError("Не все численные маркеры в отчёте удалось заполнить")

    args.report.write_text(updated, encoding="utf-8")
    print("Числа внесены в", args.report)
    print("Выявленные неполные периоды:", missing_months)
    print("Число дефектов с подсчитанными строками:", len(expected))


if __name__ == "__main__":
    main()
