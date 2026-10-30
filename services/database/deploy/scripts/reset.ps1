# reset.ps1 — остановить стенд и (по желанию) снести каталоги данных.
#
#   .\reset.ps1            остановить оба кластера, данные сохранить
#   .\reset.ps1 -Stop      то же самое (явная форма)
#   .\reset.ps1 -Wipe      остановить и удалить C:\pgstand (с подтверждением)
#
# ВНИМАНИЕ: -Wipe стирает все данные стенда безвозвратно.

param(
    [switch]$Stop,
    [switch]$Wipe
)

$ErrorActionPreference = "Stop"
chcp 65001 | Out-Null

$PGBIN = "C:\Program Files\PostgreSQL\16\bin"
$ROOT  = "C:\pgstand"

foreach ($dir in @("$ROOT\shard1", "$ROOT\shard1-replica")) {
    if (Test-Path "$dir\PG_VERSION") {
        Write-Host "Останавливаю $dir" -ForegroundColor Cyan
        & "$PGBIN\pg_ctl.exe" -D $dir -m fast stop 2>$null
    }
}

if ($Wipe) {
    $answer = Read-Host "Удалить $ROOT со всеми данными стенда? Введите yes для подтверждения"
    if ($answer -eq "yes") {
        Remove-Item -Recurse -Force $ROOT
        Write-Host "Каталог $ROOT удалён" -ForegroundColor Yellow
    } else {
        Write-Host "Отменено, каталоги оставлены" -ForegroundColor DarkGray
    }
} else {
    Write-Host "Кластеры остановлены, данные на месте." -ForegroundColor Green
    Write-Host "Поднять заново: .\build.ps1" -ForegroundColor DarkGray
}
