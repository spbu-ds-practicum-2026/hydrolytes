<#
    return_node.ps1 — возврат старого мастера как реплики УЖЕ нового мастера.
    Сценарий: после failover (promote) старый узел остановлен и/или разошёлся
    по данным; его надо пересобрать из копии нового мастера.
    Это ручной шаг 3.4 из stand.md, оформленный в скрипт (п. 4.4 «возврат узла»).

    ВНИМАНИЕ: данные в каталоге старого узла УДАЛЯЮТСЯ — это осознанно,
    после failover они считаются устаревшими.

    Пример (новый мастер на 5434, возвращаемый узел — 5433):
        .\return_node.ps1 -NewMasterPort 5434 -OldNodeDir C:\pgstand\shard1 -OldNodePort 5433 -EnableSync
#>
param(
    [string]$NewMasterHost = "localhost",
    [int]   $NewMasterPort = 5434,
    [string]$OldNodeDir    = "C:\pgstand\shard1",
    [int]   $OldNodePort   = 5433,
    [string]$SlotName      = "replica_1",   # имя слота И application_name — должны совпадать
    [string]$BinDir        = "D:\Postgre\bin",
    [switch]$EnableSync    # снять деградацию на новом мастере после возврата
)

$ErrorActionPreference = "Stop"
$env:PGCONNECT_TIMEOUT = "5"   # psql/pg_basebackup не висят на недоступном узле
$psql          = Join-Path $BinDir "psql.exe"
$pgctl         = Join-Path $BinDir "pg_ctl.exe"
$pg_basebackup = Join-Path $BinDir "pg_basebackup.exe"

function Invoke-Q([int]$Port, [string]$Sql) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"          # stderr psql не должен ронять скрипт
    $out  = & $psql -h localhost -p $Port -U postgres -tAc $Sql 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) {
        throw "psql (порт $Port) вернул код ${code}: $Sql  |  " + ($out -join " ")
    }
    return (($out | Out-String).Trim())
}

Write-Host "=== Возврат $OldNodeDir ($OldNodePort) как реплики ${NewMasterHost}:$NewMasterPort ==="

# --- 0. Новый мастер обязан быть жив и действительно мастером ---
$nm = Invoke-Q $NewMasterPort "select pg_is_in_recovery();"
if ($nm -ne "f") {
    throw "порт $NewMasterPort недоступен или не является мастером (pg_is_in_recovery=$nm)."
}
Write-Host "[ok] новый мастер $NewMasterPort отвечает (pg_is_in_recovery=f)"

# --- 1. Остановить старый узел, если запущен ---
$pidFile = Join-Path $OldNodeDir "postmaster.pid"
if (Test-Path $pidFile) {
    Write-Host "[..] останавливаю старый узел ($OldNodePort)..."
    & $pgctl -D $OldNodeDir -m immediate stop -t 15
    $waited = 0
    while ((Test-Path $pidFile) -and $waited -lt 20) {
        Start-Sleep -Seconds 1
        $waited++
    }
    if (Test-Path $pidFile) { throw "старый узел не остановился за 20 с: pg_ctl -D $OldNodeDir status" }
    Write-Host "[ok] старый узел остановлен (${waited} с)"
}
Write-Host "[ok] старый узел не запущен"

# --- 2. Слот на новом мастере: снять остаток прошлых прогонов ---
$slot = Invoke-Q $NewMasterPort "select coalesce((select active::int from pg_replication_slots where slot_name='$SlotName'), -1);"
if ($slot -eq "1") { throw "слот '$SlotName' АКТИВЕН — к нему уже подключена реплика. Останови её." }
if ($slot -eq "0") {
    Write-Host "[..] снимаю остаточный слот '$SlotName'..."
    Invoke-Q $NewMasterPort "select pg_drop_replication_slot('$SlotName');" | Out-Null
}
Write-Host "[ok] слот '$SlotName' свободен"

# --- 3. Снести каталог старого узла (его данные устарели) ---
Write-Warning "Каталог $OldNodeDir будет УДАЛЁН вместе с данными (после failover они устарели)."
if (Test-Path $OldNodeDir) {
    Remove-Item -Recurse -Force $OldNodeDir
}
Write-Host "[ok] каталог удалён"

# --- 4. Копия из нового мастера: -R (standby.signal + primary_conninfo) + слот ---
Write-Host "[..] pg_basebackup из ${NewMasterHost}:$NewMasterPort ..."
& $pg_basebackup -h $NewMasterHost -p $NewMasterPort -U postgres `
                 -D $OldNodeDir -R -X stream -C -S $SlotName
if ($LASTEXITCODE -ne 0) { throw "pg_basebackup завершился с ошибкой (код $LASTEXITCODE)" }
Write-Host "[ok] копия собрана"

# --- 5. Программно дописать application_name в primary_conninfo ---
# pg_basebackup -R сам НЕ пишет application_name; без него новый мастер видит
# узел как 'walreceiver', и synchronous_standby_names его не матчит (async).
$autoConf = Join-Path $OldNodeDir "postgresql.auto.conf"
$found = $false
$lines = Get-Content $autoConf | ForEach-Object {
    if ($_ -match "^\s*primary_conninfo\s*=") {
        $found = $true
        $line = $_ -replace "\s*application_name\s*=\s*[^'\s]+", ""   # снять старое (повторный запуск)
        $idx = $line.LastIndexOf("'")                                  # вставить перед закрывающей кавычкой
        if ($idx -lt 0) { throw "нет закрывающей кавычки в строке: $line" }
        $line.Substring(0, $idx) + " application_name=$SlotName" + $line.Substring($idx)
    } else { $_ }
}
if (-not $found) { throw "primary_conninfo не найден в $autoConf" }
Set-Content -Path $autoConf -Value $lines
Write-Host "[ok] primary_conninfo дополнен: application_name=$SlotName"

# --- 6. Запуск возвращаемого узла ---
$oldLog = Join-Path (Split-Path $OldNodeDir) ((Split-Path $OldNodeDir -Leaf) + ".log")
& $pgctl -D $OldNodeDir -o "-p $OldNodePort" -l $oldLog -w start
if ($LASTEXITCODE -ne 0) { throw "не удалось запустить узел — смотри $oldLog" }
Write-Host "[ok] узел запущен на порту $OldNodePort"

# --- 7. Автопроверки (с ретраем: walreceiver подключается не мгновенно) ---
$me = Invoke-Q $OldNodePort "select pg_is_in_recovery();"
if ($me -ne "t") { throw "ожидалась реплика (t) на $OldNodePort, получили '$me'" }

$peer = ""
for ($i = 0; $i -lt 10 -and $peer -eq ""; $i++) {
    Start-Sleep -Seconds 1
    $peer = Invoke-Q $NewMasterPort "select application_name||'|'||sync_state||'|'||state from pg_stat_replication where application_name='$SlotName';"
}
if ($peer -notmatch "\|streaming$") {
    $all = Invoke-Q $NewMasterPort "select coalesce(string_agg(application_name||'/'||sync_state||'/'||state, ', '), '(пусто)') from pg_stat_replication;"
    throw "новый мастер не видит реплику '$SlotName'. В pg_stat_replication сейчас: $all"
}
Write-Host "[ok] $OldNodePort -> pg_is_in_recovery=t"
Write-Host "[ok] $NewMasterPort видит: $peer"

# --- 8. Опционально: снять деградацию на новом мастере ---
if ($EnableSync) {
    & $psql -h localhost -p $NewMasterPort -U postgres -c "alter system set synchronous_standby_names = '$SlotName';"
    & $psql -h localhost -p $NewMasterPort -U postgres -c "alter system set synchronous_commit = 'remote_apply';"
    & $psql -h localhost -p $NewMasterPort -U postgres -c "select pg_reload_conf();"
    Write-Host "[ok] синхронность включена: synchronous_standby_names='$SlotName'"
}

Write-Host "=== Готово: $OldNodePort теперь реплика $NewMasterPort (имя/слот: $SlotName) ==="
