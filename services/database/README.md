# Схема базы

Владелец каталога: инфраструктура (см. `CODEOWNERS`). Остальные читают и не меняют.

Этот каталог — «сервис базы данных» в структуре проекта: схема, миграции и всё, что нужно для подъёма стенда. Кода на Python здесь нет, но по правилам репозитория у каждого каталога в `services/` есть свой `README.md` с командами запуска.

## Файлы

| Файл | Что внутри |
|---|---|
| `schema.sql` | Текущая схема шарда Mail DB: 5 таблиц + 5 функций аренды |
| `migrations/0001_init.sql` | Начальная миграция — то же содержимое, что `schema.sql`, но зафиксированное как шаг 1 |
| `deploy/` | конфигурация стенда: `docker-compose.yml`, `stand.json`, скрипты подъёма и проверок |
| `analytics_schema.sql` | Схема Analytics DB: `processed_event`, `delivery_history` |

## Как накатить

**Дев-база (одиночный PostgreSQL, порт 5432)** — с неё начинает второй разработчик:

```powershell
psql -h localhost -p 5432 -U postgres -c "create database mail_dev;"
psql -h localhost -p 5432 -U postgres -d mail_dev -f services/database/schema.sql
```

**Мастер шарда (порт 5433):**

```powershell
psql -h localhost -p 5433 -U postgres -d postgres -f services/database/schema.sql
```

**Analytics (отдельная база):**

```powershell
psql -h localhost -p 5432 -U postgres -c "create database analytics_dev;"
psql -h localhost -p 5432 -U postgres -d analytics_dev -f services/database/analytics_schema.sql
```

На реплику накатывать ничего не нужно: схема доедет сама через репликацию. Это, кстати, самая наглядная проверка вечера 2 — накатите `schema.sql` на мастер и посмотрите список таблиц на реплике.

## Правила

1. **Изменения только через миграции.** Создали `0002_add_index.sql` — накатили на дев-базу и на мастер. Никто не правит таблицы руками в `psql` на стенде.
2. **Миграции только вперёд.** Откатов нет: учебный стенд пересоздаётся через `db/schema.sql`.
3. **Одна миграция — одно изменение.** Не смешивайте «новая таблица» и «новый индекс» в один файл: при отладке непонятно, что именно сломалось.
4. **Схема и функции аренды меняются только вместе с `docs/api.md`.** Если поменялся контракт захвата задания — сначала PR в документацию, потом в схему.

## Стенд

Подъём двух шардов с репликацией — `deploy/scripts/build.ps1` (Windows) или `deploy/docker-compose.yml` (контейнеры).

```powershell
cd services\database\deploy\scripts
.\build.ps1            # поднять мастер + реплику, накатить схему
.\reset.ps1            # остановить, данные сохранить
.\reset.ps1 -Wipe      # снести каталог C:\pgstand
```

Проверки стенда: `deploy/scripts/smoke_test.sh` (пять проверок). Подробная инструкция по шагам — `docs/stand.md`.

## Что важно знать о содержимом

- `message.deleted_at` существует, хотя удаление «безвозвратное». Это нужно для идемпотентного `DELETE`: повторная команда должна вернуть прежний результат (`docs/api.md`, §2.4), а для этого факт удаления надо помнить.
- `delivery_job.status` переводится в `in_progress` **в том же `UPDATE`**, что назначает `locked_by` и `lease_until`. Разделять эти два действия нельзя — между ними задание может перехватить другой инстанс.
- `outbox.event_id` детерминированный: `accepted:<message_id>` и `delivered:<message_id>:<recipient_user_id>`. Это защита от повторной публикации события при ретрае.
- `processed_event.event_id` — первичный ключ в Analytics. Повторная обработка события невозможна на уровне схемы.
