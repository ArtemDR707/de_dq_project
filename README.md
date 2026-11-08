# Итоговый проект — Проверка и исправление качества данных

Это готовые файлы решения для оригинального проекта [practicum-de/de-dq-project](https://github.com/practicum-de/de-dq-project).

**Для отправки преподавателю требуются:**

- `student_fix.sql` — исправление базы PostgreSQL;
- `audit_report.md` — аналитический отчёт с причинами и методами исправлений.

**Дополнительные файлы:**

- `audit_counts.sql` — проверяемые SQL-подсчёты всех дефектов на исходном наборе;
- `fill_audit_counts.py` — внесение точных чисел в Markdown после работы `psql`;
- `.github/workflows/data-quality.yml` — запуск официального чекера после `git push`;
- `checker_result.txt` — создаётся успешным GitHub Actions запуском.

## Самый простой способ сдать через GitHub

1. Создайте **свой** репозиторий на GitHub (или используйте существующий).
2. Загрузите в корень репозитория всё содержимое этой папки, включая скрытую папку `.github` (в браузере GitHub папку с workflow можно загрузить, если загрузка сохраняет структуру; иначе воспользуйтесь Git).
3. Нажмите **Commit changes**. В **Actions → Data Quality - original checker** откроется автоматическая проверка, если Actions разрешены.
4. При успешном результате workflow автоматически заполнит в `audit_report.md` точные количества строк и добавит `checker_result.txt` в репозиторий (требуется разрешение Actions на запись в репозиторий).
5. Для сдачи прикрепите `student_fix.sql` и `audit_report.md`; при желании — вывод `checker_result.txt`.

Если автоматический запуск ограничен настройками, локальный запуск описан ниже. Не заявляйте, что тесты пройдены, пока не увидите результат `13 / 13`.

## Локальная проверка на исходном репозитории

```bash
git clone https://github.com/practicum-de/de-dq-project.git
cd de-dq-project
docker compose up -d --build
```

Скопируйте в папку `de-dq-project` файлы `student_fix.sql`, `audit_counts.sql`, `fill_audit_counts.py`, `audit_report.md`, затем:

```bash
# Linux / macOS (при необходимости установите пакет postgresql-client)
PGPASSWORD=student psql -h localhost -p 5432 -U student -d dataquality -v ON_ERROR_STOP=1 -f student_fix.sql
PGPASSWORD=student psql -h localhost -p 5432 -U student -d dataquality -At -F '|' -f audit_counts.sql > audit_counts_result.txt
python fill_audit_counts.py audit_counts_result.txt
cd checker
pip install -r requirements.txt
python run_checks.py --host localhost --port 5432 --db dataquality --user student --password student
```

Для Windows PowerShell удобнее запустить SQL из DBeaver/pgAdmin или `docker exec -i dq_postgres psql -v ON_ERROR_STOP=1 -U student -d dataquality < student_fix.sql` из `cmd.exe`/Git Bash.

Если нужно повторить аудит **с грязного состояния**, создайте чистый Docker volume/контейнер и разверните базу заново. Скрипт хранит оригинальные снимки `dq_original_*` и не удаляет их при последующих запусках.

## Архитектура очистки

- Оригинал сохраняется в `dq_original_customers`, `dq_original_products`, `dq_original_promotions`, `dq_original_orders`.
- Заказы с невосстановимой суммой или из неполного периода остаются в `dq_orders_quarantine`, период исключения — в `dq_excluded_months`.
- Отсутствующие телефоны не подделываются: `NOT_PROVIDED` — явный маркер отсутствия, `phone_data_status` — достоверный статус, `dq_usable_customer_contacts` — view с корректным `NULL` для недоступных номеров.
- Исправление повторно запускаемо и добавляет ограничения целостности к очищенной таблице заказов.
