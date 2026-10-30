#!/usr/bin/env bash
# Проверка стенда: запускать после «docker compose up -d» или после ручного подъёма.
# Использование: ./smoke_test.sh [--compose | --local]
set -uo pipefail

MODE="${1:---local}"
PGUSER="${PGUSER:-postgres}"
ok=0; fail=0
pass() { echo "  OK   $*"; ok=$((ok+1)); }
nope() { echo "  FAIL $*"; fail=$((fail+1)); }

if [ "$MODE" = "--compose" ]; then
  psql_master() { docker compose exec -T master-shard1 psql -U "$PGUSER" -tAc "$1"; }
  psql_replica() { docker compose exec -T replica-shard1 psql -U "$PGUSER" -tAc "$1"; }
else
  psql_master() { psql -h 127.0.0.1 -p 5432 -U "$PGUSER" -tAc "$1"; }
  psql_replica() { psql -h 127.0.0.1 -p 5434 -U "$PGUSER" -tAc "$1"; }
fi

echo "1) мастер отвечает"
[ "$(psql_master 'select 1')" = "1" ] && pass "мастер принимает запросы" || nope "мастер недоступен"

echo "2) репликация идёт"
STATE="$(psql_master "select state from pg_stat_replication limit 1")"
[ "$STATE" = "streaming" ] && pass "state=streaming" || nope "репликация не streaming (получено: '$STATE')"

echo "3) реплика синхронна и не отстаёт"
ROW="$(psql_master "select sync_state, replay_lsn >= flush_lsn from pg_stat_replication limit 1")"
case "$ROW" in
  "sync|t") pass "sync_state=sync и replay_lsn догнал flush_lsn" ;;
  *)        nope "синхронность не подтверждена (получено: '$ROW')" ;;
esac

echo "4) реплика только для чтения"
[ "$(psql_replica 'select pg_is_in_recovery()')" = "t" ] && pass "pg_is_in_recovery = t" || nope "реплика не в режиме восстановления"

echo "5) идемпотентность: повтор ключа не создаёт дубль"
psql_master "create table if not exists smoke_op(user_id int, key text, primary key(user_id,key));" >/dev/null
psql_master "insert into smoke_op values (1,'k1') on conflict do nothing;" >/dev/null
CNT="$(psql_master "select count(*) from smoke_op where user_id=1 and key='k1'")"
[ "$CNT" = "1" ] && pass "после повтора записей: $CNT" || nope "ожидалась 1 запись, получено $CNT"
psql_master "drop table if exists smoke_op;" >/dev/null

echo
echo "итог: успешно $ok, провалов $fail"
[ "$fail" -eq 0 ] || exit 1
