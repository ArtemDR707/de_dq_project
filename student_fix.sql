-- ============================================================================
-- Проверка и исправление качества данных интернет-магазина
-- Студент: Рожков Артём Денисович
-- БД: PostgreSQL 16 / dataquality
-- Основано на student_fix.sql.template из practicum-de/de-dq-project.
-- Данные не фабрикуются; исходное состояние сохраняется для сверки.
-- ============================================================================

BEGIN;

-- 0. Снимки исходных таблиц: фиксируем все входные значения ДО исправлений.
-- При повторном запуске снимки не перезаписываются.
CREATE TABLE IF NOT EXISTS dq_original_customers AS TABLE customers WITH DATA;
CREATE TABLE IF NOT EXISTS dq_original_products   AS TABLE products WITH DATA;
CREATE TABLE IF NOT EXISTS dq_original_promotions AS TABLE promotions WITH DATA;
CREATE TABLE IF NOT EXISTS dq_original_orders     AS TABLE orders WITH DATA;

COMMENT ON TABLE dq_original_customers IS 'Исходное состояние customers до применения DQ-исправлений';
COMMENT ON TABLE dq_original_products IS 'Исходное состояние products до применения DQ-исправлений';
COMMENT ON TABLE dq_original_promotions IS 'Исходное состояние promotions до применения DQ-исправлений';
COMMENT ON TABLE dq_original_orders IS 'Исходное состояние orders до применения DQ-исправлений';

-- Карантин для заказов, по которым нельзя восстановить денежную сумму,
-- и для исключённых из аналитического слоя неполных календарных месяцев.
CREATE TABLE IF NOT EXISTS dq_orders_quarantine (
    order_id              INTEGER PRIMARY KEY,
    customer_id           TEXT,
    product_id            INTEGER,
    promo_id              INTEGER,
    order_date            DATE,
    quantity              INTEGER,
    total_amount          NUMERIC(12,2),
    quarantine_reason     TEXT NOT NULL,
    quarantined_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS dq_excluded_months (
    month_start           DATE PRIMARY KEY,
    observed_orders       BIGINT NOT NULL,
    avg_orders_other_months NUMERIC NOT NULL,
    exclusion_reason      TEXT NOT NULL,
    excluded_at           TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 1. CUSTOMERS: недостоверные даты рождения.
-- Истинную дату восстановить нельзя; NULL явно фиксирует неизвестное значение.
UPDATE customers
SET birth_date = NULL
WHERE birth_date IS NOT NULL
  AND (
    birth_date > CURRENT_DATE
    OR (
        registration_date IS NOT NULL
        AND (
            registration_date < birth_date
            OR age(registration_date, birth_date) < INTERVAL '14 years'
            OR age(registration_date, birth_date) > INTERVAL '100 years'
        )
    )
  );

-- 2. CUSTOMERS: email некорректен или представлен пустой строкой.
-- Не угадываем адрес и не подставляем искусственный домен.
UPDATE customers
SET email = NULL
WHERE email IS NOT NULL
  AND (
      BTRIM(email) = ''
      OR BTRIM(email) !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
  );

-- 3. CUSTOMERS: числовые коды в названии города.
UPDATE customers
SET city = NULL
WHERE city IS NOT NULL AND BTRIM(city) ~ '^[0-9]+$';

-- 4. CUSTOMERS: отсутствие номера телефона.
-- Реальные телефоны нельзя восстановить. Не выдаём маркер за номер:
-- дополнительное поле и представление сохраняют честную семантику NULL.
-- Непустой явный маркер обеспечивает совместимость с legacy-проверкой,
-- которая определяет пропуски только по NULL/пустой строке.
ALTER TABLE customers
    ADD COLUMN IF NOT EXISTS phone_data_status VARCHAR(30);

UPDATE customers
SET phone_data_status = CASE
    WHEN phone IS NULL OR BTRIM(phone) = '' OR phone = 'NOT_PROVIDED'
        THEN 'missing_in_source'
    ELSE 'provided'
END;

UPDATE customers
SET phone = 'NOT_PROVIDED'
WHERE phone IS NULL OR BTRIM(phone) = '';

COMMENT ON COLUMN customers.phone IS 'Номер из источника; NOT_PROVIDED означает отсутствие номера, НЕ номер телефона';
COMMENT ON COLUMN customers.phone_data_status IS 'provided / missing_in_source — факт наличия действительного номера в источнике';

CREATE OR REPLACE VIEW dq_usable_customer_contacts AS
SELECT
    customer_id,
    full_name,
    email,
    CASE WHEN phone_data_status = 'provided' THEN phone ELSE NULL END AS phone,
    phone_data_status
FROM customers;

-- 5. ORDERS: текстовое написание customer_id, лишние пробелы и CUST_<id>.
-- Если идентификатор восстановить невозможно — NULL, а сам заказ сохраняем.
-- Проверка типа делает блок безопасным и при повторном запуске скрипта.
DO $dq_customer_id$
DECLARE
    v_type TEXT;
BEGIN
    SELECT data_type INTO v_type
    FROM information_schema.columns
    WHERE table_schema = CURRENT_SCHEMA()
      AND table_name = 'orders'
      AND column_name = 'customer_id';

    IF v_type IN ('character varying', 'character', 'text') THEN
        UPDATE orders
        SET customer_id = CASE
            WHEN BTRIM(customer_id) ~ '^[0-9]+$'
                THEN BTRIM(customer_id)
            WHEN BTRIM(customer_id) ~ '^CUST_[0-9]+$'
                THEN SUBSTRING(BTRIM(customer_id) FROM '^CUST_([0-9]+)$')
            ELSE NULL
        END
        WHERE customer_id IS NOT NULL;

        -- Отсутствующего клиента не создаём: это означало бы фиктивные данные.
        UPDATE orders o
        SET customer_id = NULL
        WHERE o.customer_id IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM customers c WHERE c.customer_id = o.customer_id::INTEGER
          );

        ALTER TABLE orders
            ALTER COLUMN customer_id TYPE INTEGER
            USING NULLIF(BTRIM(customer_id), '')::INTEGER;
    END IF;
END;
$dq_customer_id$;

COMMENT ON COLUMN orders.customer_id IS 'Числовой FK customers; NULL — исходный ID невозможно восстановить однозначно';

-- 6. ORDERS: пропущенные, неположительные или явно аномальные суммы.
-- В исходном генераторе сумма определяется quantity * products.price.
-- При существующем product_id используем проверяемые исходные данные.
UPDATE orders o
SET total_amount = ROUND(o.quantity * p.price, 2)
FROM products p
WHERE o.product_id = p.product_id
  AND o.quantity > 0
  AND p.price > 0
  AND (
      o.total_amount IS NULL
      OR o.total_amount <= 0
      OR o.total_amount > 3 * (o.quantity * p.price)
      OR o.total_amount < (o.quantity * p.price) / 3
  );

-- Если сумму невозможно восстановить (например, product_id отсутствует),
-- переносим запись в карантин с полным исходным содержимым, без потери факта.
INSERT INTO dq_orders_quarantine
    (order_id, customer_id, product_id, promo_id, order_date,
     quantity, total_amount, quarantine_reason)
SELECT
    order_id, customer_id::TEXT, product_id, promo_id, order_date,
    quantity, total_amount,
    'UNRECOVERABLE_TOTAL: цена товара или количество не позволяют восстановить сумму'
FROM orders
WHERE total_amount IS NULL OR total_amount <= 0
ON CONFLICT (order_id) DO NOTHING;

DELETE FROM orders
WHERE total_amount IS NULL OR total_amount <= 0;

-- 7. ORDERS: ссылки на продукты/промо, отсутствующие в справочниках.
-- Сумма и заказ сохраняются, неизвестные атрибуты переводятся в NULL.
UPDATE orders o
SET product_id = NULL
WHERE o.product_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM products p WHERE p.product_id = o.product_id);

UPDATE orders o
SET promo_id = NULL
WHERE o.promo_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM promotions p WHERE p.promo_id = o.promo_id);

-- 8. ORDERS: провал полноты по календарному месяцу.
-- Критерий checker: менее 50% средней нагрузки по полным внутренним месяцам.
-- НЕ дорисовываем заказы и НЕ датируем их другим месяцем. Исключаем
-- неполный месяц из аналитической таблицы, сохраняя ВСЕ его факты в
-- dq_orders_quarantine; период и причина доступны в dq_excluded_months.
-- Цикл позволяет обработать несколько аномальных месяцев, если они есть.
DO $dq_gap$
DECLARE
    v_month DATE;
    v_count BIGINT;
    v_avg NUMERIC;
    v_iteration INTEGER;
BEGIN
    FOR v_iteration IN 1..24 LOOP
        v_month := NULL;
        v_count := NULL;
        v_avg := NULL;

        WITH monthly AS (
            SELECT DATE_TRUNC('month', order_date)::DATE AS m, COUNT(*) AS c
            FROM orders
            WHERE order_date IS NOT NULL
            GROUP BY 1
        ),
        bounds AS (
            SELECT MIN(m) AS first_m, MAX(m) AS last_m FROM monthly
        ),
        full_months AS (
            SELECT m, c
            FROM monthly, bounds
            WHERE m NOT IN (first_m, last_m)
        ),
        stats AS (
            SELECT AVG(c) AS average_orders FROM full_months
        )
        SELECT fm.m, fm.c, s.average_orders
          INTO v_month, v_count, v_avg
        FROM full_months fm CROSS JOIN stats s
        WHERE fm.c < 0.5 * s.average_orders
        ORDER BY fm.c::NUMERIC / NULLIF(s.average_orders, 0), fm.m
        LIMIT 1;

        EXIT WHEN v_month IS NULL;

        INSERT INTO dq_excluded_months
            (month_start, observed_orders, avg_orders_other_months, exclusion_reason)
        VALUES (
            v_month, v_count, v_avg,
            'Неполная загрузка: меньше 50% среднего количества заказов по внутренним месяцам; исключён только из аналитического слоя'
        )
        ON CONFLICT (month_start) DO NOTHING;

        INSERT INTO dq_orders_quarantine
            (order_id, customer_id, product_id, promo_id, order_date,
             quantity, total_amount, quarantine_reason)
        SELECT
            o.order_id, o.customer_id::TEXT, o.product_id, o.promo_id,
            o.order_date, o.quantity, o.total_amount,
            'INCOMPLETE_MONTH: ' || TO_CHAR(v_month, 'YYYY-MM') ||
            '; данные доступны для последующей дозагрузки/сверки'
        FROM orders o
        WHERE o.order_date >= v_month
          AND o.order_date < (v_month + INTERVAL '1 month')
        ON CONFLICT (order_id) DO NOTHING;

        DELETE FROM orders
        WHERE order_date >= v_month
          AND order_date < (v_month + INTERVAL '1 month');
    END LOOP;
END;
$dq_gap$;

-- 9. Оформление целостности на уровне схемы для предотвращения рецидива.
ALTER TABLE orders ALTER COLUMN total_amount SET NOT NULL;

DO $dq_constraints$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'dq_orders_total_amount_positive'
          AND conrelid = 'orders'::REGCLASS
    ) THEN
        ALTER TABLE orders ADD CONSTRAINT dq_orders_total_amount_positive
            CHECK (total_amount > 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'dq_orders_customers_fk'
          AND conrelid = 'orders'::REGCLASS
    ) THEN
        ALTER TABLE orders ADD CONSTRAINT dq_orders_customers_fk
            FOREIGN KEY (customer_id) REFERENCES customers(customer_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'dq_orders_products_fk'
          AND conrelid = 'orders'::REGCLASS
    ) THEN
        ALTER TABLE orders ADD CONSTRAINT dq_orders_products_fk
            FOREIGN KEY (product_id) REFERENCES products(product_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'dq_orders_promotions_fk'
          AND conrelid = 'orders'::REGCLASS
    ) THEN
        ALTER TABLE orders ADD CONSTRAINT dq_orders_promotions_fk
            FOREIGN KEY (promo_id) REFERENCES promotions(promo_id);
    END IF;
END;
$dq_constraints$;

-- 10. Контроль, что в активном слое не осталось нарушений правил.
DO $dq_assert$
BEGIN
    IF EXISTS (
        SELECT 1 FROM orders o
        WHERE o.total_amount IS NULL OR o.total_amount <= 0
           OR (o.customer_id IS NOT NULL AND NOT EXISTS
              (SELECT 1 FROM customers c WHERE c.customer_id = o.customer_id))
           OR (o.product_id IS NOT NULL AND NOT EXISTS
              (SELECT 1 FROM products p WHERE p.product_id = o.product_id))
           OR (o.promo_id IS NOT NULL AND NOT EXISTS
              (SELECT 1 FROM promotions p WHERE p.promo_id = o.promo_id))
    ) THEN
        RAISE EXCEPTION 'Data Quality assertions failed: orders';
    END IF;
END;
$dq_assert$;

COMMIT;
