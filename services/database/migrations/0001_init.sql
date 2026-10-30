-- migration 0001: начальная схема шарда (см. db/schema.sql)
-- =====================================================================
-- Схема Mail DB (один шард). Выполняется на каждом шарде отдельно.
-- PostgreSQL 16.
--
-- Запуск на мастере шарда 1:
--   psql -h localhost -p 5433 -U postgres -d postgres -f schema.sql
--
-- Эту схему владелец БД-части фиксирует и не меняет без миграции:
-- второй разработчик читает её и не правит таблицы руками.
-- =====================================================================

-- ---------- Пользователи и письма ----------

create table if not exists mail_user (
    id          bigint generated always as identity primary key,
    email       text not null unique,
    created_at  timestamptz not null default now()
);

-- Письмо лежит в конкретной папке конкретного ящика.
-- Один и тот же Message-ID может существовать у разных получателей,
-- поэтому уникальность — в пределах ящика (owner_id, message_id).
create table if not exists message (
    id            bigint generated always as identity primary key,
    message_id    text not null,                  -- заголовок Message-ID письма
    owner_id      bigint not null references mail_user(id),
    folder        text not null check (folder in ('inbox', 'sent')),
    is_read       boolean not null default false,
    from_addr     text not null,
    to_addr       text not null,
    subject       text not null default '',
    body          text not null default '',
    received_at   timestamptz not null default now(),
    deleted_at    timestamptz,                    -- безвозвратное удаление: строка удаляется,
                                                  -- поле оставлено для возможного аудита
    unique (owner_id, message_id)
);

-- Индекс под список папки: самый частый запрос интерфейса.
create index if not exists message_folder_idx
    on message (owner_id, folder, received_at desc)
    where deleted_at is null;

-- ---------- Идемпотентность пользовательских операций ----------

create table if not exists operation_key (
    user_id     bigint not null references mail_user(id),
    key         text   not null,                  -- ключ операции, приходит от клиента
    result      jsonb,                            -- сохранённый результат первой операции
    created_at  timestamptz not null default now(),
    primary key (user_id, key)
);

-- ---------- Задания межшардовой доставки ----------

create table if not exists delivery_job (
    id                  bigint generated always as identity primary key,
    message_id          text   not null,
    sender_user_id      bigint not null,
    recipient_user_id   bigint not null,
    status              text   not null default 'pending'
                            check (status in ('pending', 'in_progress', 'done', 'failed')),
    locked_by           text,                     -- какой инстанс Mail держит задание
    lease_until         timestamptz,              -- до какого момента аренда действует
    attempts            int    not null default 0,
    last_error          text,
    created_at          timestamptz not null default now()
);

-- Индекс под выборку работы обработчиком.
create index if not exists delivery_job_take_idx
    on delivery_job (created_at)
    where status in ('pending', 'in_progress');

-- ---------- Transactional outbox ----------

create table if not exists outbox (
    id          bigint generated always as identity primary key,
    event_id    text not null unique,             -- детерминированный: accepted:<msg_id>,
                                                  -- delivered:<msg_id>:<recipient_user_id>
    event_type  text not null,
    payload     jsonb not null,
    published   boolean not null default false,
    created_at  timestamptz not null default now()
);

create index if not exists outbox_unpublished_idx
    on outbox (created_at)
    where published = false;


-- =====================================================================
-- Аренда заданий: три функции, которые вызывает worker.
-- Владение — сохранённое состояние строки, поэтому перевод в in_progress
-- выполняется в том же UPDATE, что и назначение владельца и срока аренды.
-- =====================================================================

-- 1) Захват пачки заданий. Возвращает строки, которые теперь принадлежат p_owner.
create or replace function take_jobs(p_owner text, p_limit int default 50)
returns setof delivery_job
language sql
as $$
    update delivery_job
       set status      = 'in_progress',
           locked_by   = p_owner,
           lease_until = now() + interval '10 seconds',
           attempts    = attempts + 1
     where id in (
           select id
             from delivery_job
            where status = 'pending'
               or (status = 'in_progress' and lease_until < now())
            order by created_at
            limit p_limit
              for update skip locked
     )
    returning *;
$$;

-- 2) Продление аренды (heartbeat каждые 3 секунды).
-- Возвращает число продлённых заданий. Если меньше, чем ожидалось, —
-- владение потеряно: задание перехватил другой инстанс.
create or replace function heartbeat_jobs(p_owner text, p_ids bigint[])
returns int
language plpgsql
as $$
declare
    n int;
begin
    update delivery_job
       set lease_until = now() + interval '10 seconds'
     where id = any(p_ids)
       and locked_by = p_owner
       and status = 'in_progress';
    get diagnostics n = row_count;
    return n;
end;
$$;

-- 3) Завершение задания. false — значит задание уже не наше,
-- результат фиксировать нельзя (транзакцию нужно откатить).
create or replace function complete_job(p_owner text, p_id bigint)
returns boolean
language plpgsql
as $$
declare
    n int;
begin
    update delivery_job
       set status      = 'done',
           locked_by   = null,
           lease_until = null
     where id = p_id
       and locked_by = p_owner
       and status = 'in_progress';
    get diagnostics n = row_count;
    return n = 1;
end;
$$;

-- 4) Возврат задания в очередь без расхода попытки.
-- Используется, когда шард получателя ответил MIGRATING (идёт перенос диапазона):
-- это временная ошибка, а не неудачная попытка.
create or replace function release_job(p_owner text, p_id bigint)
returns boolean
language plpgsql
as $$
declare
    n int;
begin
    update delivery_job
       set status      = 'pending',
           locked_by   = null,
           lease_until = null,
           attempts    = greatest(attempts - 1, 0)
     where id = p_id
       and locked_by = p_owner;
    get diagnostics n = row_count;
    return n = 1;
end;
$$;

-- 5) Пометить задание проваленным после N попыток.
create or replace function fail_job(p_owner text, p_id bigint, p_error text)
returns boolean
language plpgsql
as $$
declare
    n int;
begin
    update delivery_job
       set status      = 'failed',
           locked_by   = null,
           lease_until = null,
           last_error  = p_error
     where id = p_id
       and locked_by = p_owner;
    get diagnostics n = row_count;
    return n = 1;
end;
$$;


-- =====================================================================
-- Пример: как выглядит обработка одного цикла у worker-а
-- (это псевдокод, в схеме не выполняется)
--
--   jobs = take_jobs('Mail-1', 50)
--   for job in jobs:
--       try:
--           -- 1. транзакция на шарде получателя:
--           insert into message (... ) values (...) on conflict do nothing;
--           insert into outbox (event_id, ...) values ('delivered:'||job.message_id||':'||job.recipient_user_id, ...) on conflict do nothing;
--           commit;
--           -- 2. отдельная транзакция на шарде отправителя:
--           complete_job('Mail-1', job.id)
--       except MigratingRange:
--           release_job('Mail-1', job.id)      -- временная ошибка, повторим позже
--       except Exception as e:
--           if job.attempts >= 5: fail_job('Mail-1', job.id, str(e))
--
-- Каждые 3 секунды в фоне: heartbeat_jobs('Mail-1', активные_ids)
-- =====================================================================


-- =====================================================================
