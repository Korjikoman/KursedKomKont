# База kursed: PostgreSQL + Python

Два сервиса Docker Compose:

- `postgres` — PostgreSQL 17 с сохранением данных в именованном томе.
- `migrate` — Python 3.13. После готовности PostgreSQL применяет SQL и завершает
  работу с кодом `0`. Состояние `Exited (0)` для него нормально.

Мигратор запускает `psql` и подключается к `postgres:5432` по внутренней сети Compose.

## Запуск

Из каталога проекта:

```bash
docker compose up -d --build
docker compose logs -f migrate
docker compose ps -a
```

Успешное окончание установки: в логах `SUCCESS: migrations committed; database is ready`,
контейнер `migrate` завершился с кодом `0`.
Готовность самого PostgreSQL ещё не означает завершение установки схемы.
Для проверки кода завершения:

```bash
docker compose wait migrate
```

В `.env` укажите имена файлов:

```dotenv
SQL_SCHEMA_FILE=dump.sql
SQL_FUNCTIONS_FILE=komkont_funcs.sql
```

`POSTGRES_USER` и `POSTGRES_PASSWORD` задают учётные данные при первом создании тома.

## Подключение из DBeaver

| Параметр | Значение по умолчанию |
| --- | --- |
| Host | `localhost` |
| Port | `5433` |
| Database | `kursed` |
| Username | `root` |
| Password | `root` |

Порт опубликован только на `127.0.0.1`. Если `5433` занят, задайте другой
`POSTGRES_PORT` в `.env`. Внутри сети Docker порт остаётся `5432`.

## Применение SQL

Мигратор читает имена файлов из переменных окружения в таком порядке:

1. `SQL_SCHEMA_FILE` — схема и данные из `dump.sql`.
2. `SQL_FUNCTIONS_FILE` — дополнительные функции и триггеры. Пустой файл пропускается.

Для переноса схемы экспортируйте SQL-дамп через `pg_dump --format=plain --no-owner`.
`psql` применяет файлы и записывает историю в одной транзакции. Для обычных SQL-скриптов
мигратор также поддерживает внешнюю пару `BEGIN;` / `COMMIT;` на отдельных строках.

История и SHA-256 файлов хранятся в `migration_meta.schema_migrations`.
При повторном запуске применённые файлы пропускаются; изменение применённого
файла приводит к ошибке. Блокировка защищает от одновременного запуска мигратора.
Для первого импорта дампа нужна база без объектов из этого дампа.

Повторно запустить мигратор, например после исправления ошибки:

```bash
docker compose up -d --build migrate
docker compose logs -f migrate
```

## Проверка базы

```bash
docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\dt public.*"'
docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "TABLE migration_meta.schema_migrations;"'
```

Текущий `dump.sql` создаёт 17 таблиц без строк. При пустом `komkont_funcs.sql`
в истории будет одна запись.

## Остановка

```bash
docker compose down
```

Данные сохраняются в томе. Команда `docker compose down -v` удаляет том
вместе со всеми данными; используйте её только для намеренного сброса базы.
