-- Воспроизводимые точные количества дефектов ИСХОДНОГО набора данных.
-- После student_fix.sql читаем сохранённые dq_original_*.
-- Для получения отчёта: psql ... -f audit_counts.sql

SELECT 'customers' AS entity, COUNT(*) AS source_rows FROM dq_original_customers
UNION ALL SELECT 'products', COUNT(*) FROM dq_original_products
UNION ALL SELECT 'promotions', COUNT(*) FROM dq_original_promotions
UNION ALL SELECT 'orders', COUNT(*) FROM dq_original_orders
ORDER BY entity;

WITH source_customer_ids AS (
    SELECT
        o.*,
        CASE
            WHEN BTRIM(o.customer_id::TEXT) ~ '^[0-9]+$'
                THEN BTRIM(o.customer_id::TEXT)
            WHEN BTRIM(o.customer_id::TEXT) ~ '^CUST_[0-9]+$'
                THEN SUBSTRING(BTRIM(o.customer_id::TEXT) FROM '^CUST_([0-9]+)$')
            ELSE NULL
        END AS normalized_id
    FROM dq_original_orders o
),
checks AS (
    SELECT '01_orders_customer_id_with_spaces' AS check_code,
           COUNT(*) FILTER (WHERE customer_id IS NOT NULL AND customer_id <> BTRIM(customer_id)) AS affected
    FROM source_customer_ids
    UNION ALL SELECT '02_orders_customer_id_prefixed', COUNT(*) FILTER (
        WHERE BTRIM(customer_id) ~ '^CUST_[0-9]+$') FROM source_customer_ids
    UNION ALL SELECT '03_orders_customer_id_unrecoverable', COUNT(*) FILTER (
        WHERE normalized_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM dq_original_customers c
            WHERE c.customer_id::TEXT = normalized_id
        )) FROM source_customer_ids
    UNION ALL SELECT '04_orders_product_id_orphan', COUNT(*) FILTER (
        WHERE product_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM dq_original_products p WHERE p.product_id = o.product_id
        )) FROM dq_original_orders o
    UNION ALL SELECT '05_orders_promo_id_orphan', COUNT(*) FILTER (
        WHERE promo_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM dq_original_promotions p WHERE p.promo_id = o.promo_id
        )) FROM dq_original_orders o
    UNION ALL SELECT '06_customers_phone_missing', COUNT(*) FILTER (
        WHERE phone IS NULL OR BTRIM(phone) = '') FROM dq_original_customers
    UNION ALL SELECT '07_customers_birth_future', COUNT(*) FILTER (
        WHERE birth_date > CURRENT_DATE) FROM dq_original_customers
    UNION ALL SELECT '08_customers_age_invalid_at_registration', COUNT(*) FILTER (
        WHERE birth_date IS NOT NULL AND registration_date IS NOT NULL
          AND (registration_date < birth_date
             OR AGE(registration_date, birth_date) < INTERVAL '14 years'
             OR AGE(registration_date, birth_date) > INTERVAL '100 years'))
        FROM dq_original_customers
    UNION ALL SELECT '09_customers_email_invalid_nonblank', COUNT(*) FILTER (
        WHERE email IS NOT NULL AND BTRIM(email) <> ''
          AND BTRIM(email) !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
        FROM dq_original_customers
    UNION ALL SELECT '10_customers_email_missing', COUNT(*) FILTER (
        WHERE email IS NULL OR BTRIM(email) = '') FROM dq_original_customers
    UNION ALL SELECT '11_customers_city_numeric', COUNT(*) FILTER (
        WHERE BTRIM(city) ~ '^[0-9]+$') FROM dq_original_customers
    UNION ALL SELECT '12_orders_total_amount_null', COUNT(*) FILTER (
        WHERE total_amount IS NULL) FROM dq_original_orders
    UNION ALL SELECT '13_orders_total_amount_nonpositive', COUNT(*) FILTER (
        WHERE total_amount <= 0) FROM dq_original_orders
    UNION ALL SELECT '14_orders_total_amount_outlier_x3', COUNT(*) FILTER (
        WHERE p.product_id IS NOT NULL AND o.quantity > 0 AND p.price > 0
          AND o.total_amount IS NOT NULL
          AND (o.total_amount > 3 * (o.quantity * p.price)
            OR o.total_amount < (o.quantity * p.price) / 3))
        FROM dq_original_orders o LEFT JOIN dq_original_products p ON p.product_id = o.product_id
    UNION ALL SELECT '15_orders_null_total_without_source_product', COUNT(*) FILTER (
        WHERE (o.total_amount IS NULL OR o.total_amount <= 0)
          AND NOT EXISTS (SELECT 1 FROM dq_original_products p
                          WHERE p.product_id = o.product_id AND p.price > 0)
        ) FROM dq_original_orders o
)
SELECT check_code, affected FROM checks ORDER BY check_code;

-- Месячные аномалии исходной витрины; крайние частичные месяцы исключены,
-- так же как в checker/run_checks.py.
WITH monthly AS (
    SELECT DATE_TRUNC('month', order_date)::DATE AS month_start, COUNT(*) AS order_count
    FROM dq_original_orders WHERE order_date IS NOT NULL GROUP BY 1
), bounds AS (
    SELECT MIN(month_start) AS first_month, MAX(month_start) AS last_month FROM monthly
), stats AS (
    SELECT AVG(order_count) AS average_full_month
    FROM monthly, bounds WHERE month_start NOT IN (first_month, last_month)
)
SELECT m.month_start, m.order_count, ROUND(s.average_full_month, 2) AS average_full_month,
       CASE WHEN m.month_start IN (b.first_month, b.last_month)
            THEN 'PARTIAL_BOUNDARY_MONTH'
            WHEN m.order_count < 0.5 * s.average_full_month THEN 'INCOMPLETE_MONTH'
            ELSE 'OK'
       END AS quality_status
FROM monthly m CROSS JOIN bounds b CROSS JOIN stats s
ORDER BY m.month_start;

-- Итоги очищенного слоя и прозрачность исключений.
SELECT 'orders_after' AS metric, COUNT(*) AS rows FROM orders
UNION ALL SELECT 'quarantined_orders', COUNT(*) FROM dq_orders_quarantine
UNION ALL SELECT 'excluded_months', COUNT(*) FROM dq_excluded_months
UNION ALL SELECT 'phone_missing_in_source', COUNT(*) FROM customers WHERE phone_data_status = 'missing_in_source';

-- Контроль первичных ключей и отдельный контроль справочников:
SELECT 'customers.id_dup' AS metric, COALESCE(SUM(n - 1), 0) AS defects
FROM (SELECT COUNT(*) AS n FROM dq_original_customers GROUP BY customer_id HAVING COUNT(*) > 1) t
UNION ALL SELECT 'products.id_dup', COALESCE(SUM(n - 1), 0)
FROM (SELECT COUNT(*) AS n FROM dq_original_products GROUP BY product_id HAVING COUNT(*) > 1) t
UNION ALL SELECT 'promotions.id_dup', COALESCE(SUM(n - 1), 0)
FROM (SELECT COUNT(*) AS n FROM dq_original_promotions GROUP BY promo_id HAVING COUNT(*) > 1) t
UNION ALL SELECT 'orders.id_dup', COALESCE(SUM(n - 1), 0)
FROM (SELECT COUNT(*) AS n FROM dq_original_orders GROUP BY order_id HAVING COUNT(*) > 1) t
UNION ALL SELECT 'products.price_nonpositive', COUNT(*) FROM dq_original_products WHERE price <= 0
UNION ALL SELECT 'promotions.discount_out_of_range', COUNT(*) FROM dq_original_promotions
  WHERE discount_pct < 0 OR discount_pct > 100
UNION ALL SELECT 'promotions.invalid_date_range', COUNT(*) FROM dq_original_promotions
  WHERE start_date > end_date;
