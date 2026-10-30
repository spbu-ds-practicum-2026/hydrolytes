-- =====================================================================
-- -- Analytics DB (отдельная база, не шард Mail DB)
-- =====================================================================

create table if not exists processed_event (
    event_id    text primary key,                 -- inbox: защита от повторной обработки
    event_type  text not null,
    payload     jsonb not null,
    result      jsonb,
    received_at timestamptz not null default now()
);

create table if not exists delivery_history (
    message_id          text not null,
    sender_user_id      bigint not null,
    recipient_user_id   bigint not null,
    accepted_at         timestamptz,
    delivered_at        timestamptz,
    primary key (message_id, recipient_user_id)
);
