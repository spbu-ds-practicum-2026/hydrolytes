# build.ps1 — поднять ручной стенд (мастер шарда 1 + реплика) на Windows 11.
#
# Использование (обычный PowerShell, НЕ от администратора):
#   cd C:\путь\к\hydrolytes\deploy\scripts
#   .\build.ps1
#
# Если PowerShell блокирует запуск скриптов:
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

$ErrorActionPreference = "Stop"
chcp 65001 | Out-Null

$PGBIN = "C:\Program Files\PostgreSQL\16\bin"
$ROOT  = "C:\pgstand"
$MASTER_DIR  = "$ROOT\shard1"
$REPLICA_DIR = "$ROOT\shard1-replica"
$MASTER_PORT = 5433
$REPLICA_PORT = 5434

if (-not (Test-Path "$PGBIN\pg_ctl.exe")) {
    Write-Host "Не найден PostgreSQL в $PGBIN" -ForegroundColor Red
    Write-Host "Установите PostgreSQL 16 с компонентом Command Line Tools." -ForegroundColor Yellow
    exit 1
}

New-Item -ItemType Directory -Force $ROOT | Out-Null

function Stop-IfRunning($dir) {
    if (Test-Path "$dir\postmaster.pid") {
        Write-Host "Останавливаю уже запущенный кластер в $dir" -ForegroundColor Yellow
        & "$PGBIN\pg_ctl.exe" -D $dir -m fast stop
        Start-Sleep -Seconds 2
    }
}

# ---------- 1. мастер ----------
if (-not (Test-Path "$MASTER_DIR\PG_VERSION")) {
    Write-Host "[1/4] initdb -> $MASTER_DIR" -ForegroundColor Cyan
    & "$PGBIN\initdb.exe" -D $MASTER_DIR -U postgres --auth=trust --encoding=UTF8 --locale=C
} else {
    Write-Host "[1/4] каталог мастера уже есть, пропускаю initdb" -ForegroundColor DarkGray
    Stop-IfRunning $MASTER_DIR
}

Write-Host "[2/4] запускаю мастер на порту $MASTER_PORT" -ForegroundColor Cyan
& "$PGBIN\pg_ctl.exe" -D $MASTER_DIR -o "-p $MASTER_PORT" -l "$ROOT\shard1.log" -w start

# ---------- 2. настройки репликации ----------
Write-Host "[3/4] включаю репликацию" -ForegroundColor Cyan
& "$PGBIN\psql.exe" -h localhost -p $MASTER_PORT -U postgres -q -c @"
alter system set wal_level = 'replica';
alter system set max_wal_senders = 10;
alter system set wal_keep_size = '256MB';
alter system set synchronous_standby_names = 'replica_1';
alter system set synchronous_commit = 'remote_apply';
"@
& "$PGBIN\pg_ctl.exe" -D $MASTER_DIR -o "-p $MASTER_PORT" -l "$ROOT\shard1.log" -w restart

# схема (если ещё не накатана)
$schema = Join-Path $PSScriptRoot "..\..\schema.sql"
if (Test-Path $schema) {
    Write-Host "      накатываю схему из services\database\schema.sql" -ForegroundColor DarkGray
    & "$PGBIN\psql.exe" -h localhost -p $MASTER_PORT -U postgres -q -f (Resolve-Path $schema)
}

# ---------- 3. реплика ----------
if (-not (Test-Path "$REPLICA_DIR\PG_VERSION")) {
    Write-Host "[4/4] pg_basebackup -> $REPLICA_DIR" -ForegroundColor Cyan
    & "$PGBIN\pg_basebackup.exe" -h localhost -p $MASTER_PORT -U postgres `
        -D $REPLICA_DIR -R -X stream -C -S replica_1
} else {
    Write-Host "[4/4] каталог реплики уже есть, пропускаю копирование" -ForegroundColor DarkGray
    Stop-IfRunning $REPLICA_DIR
}

Write-Host "      запускаю реплику на порту $REPLICA_PORT" -ForegroundColor Cyan
& "$PGBIN\pg_ctl.exe" -D $REPLICA_DIR -o "-p $REPLICA_PORT" -l "$ROOT\replica1.log" -w start

Start-Sleep -Seconds 2

# ---------- проверка ----------
Write-Host "`nПроверка:" -ForegroundColor Green
& "$PGBIN\psql.exe" -h localhost -p $MASTER_PORT -U postgres -c `
    "select client_addr, state, sync_state from pg_stat_replication;"
& "$PGBIN\psql.exe" -h localhost -p $REPLICA_PORT -U postgres -c `
    "select pg_is_in_recovery() as replica, (select timeline_id from pg_control_checkpoint()) as timeline;"

Write-Host "`nСтенд поднят. мастер :$MASTER_PORT, реплика :$REPLICA_PORT" -ForegroundColor Green
Write-Host "Остановить: .\reset.ps1 -Stop" -ForegroundColor DarkGray
