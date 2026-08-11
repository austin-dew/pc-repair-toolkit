$backupDir = "C:\ProgramData\GeekSquad"
$backupFile = Join-Path $backupDir "ScreenTimeoutBackup.json"

if (-not (Test-Path $backupFile)) {
    Write-Host "[!] No screen timeout backup found on this device." -ForegroundColor Yellow
    Write-Host "Leaving current screen timeout settings unchanged." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    exit 0
}

$backup = Get-Content -Path $backupFile -Raw | ConvertFrom-Json

powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOIDLE $backup.ACSeconds
powercfg /setdcvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOIDLE $backup.DCSeconds
powercfg /setactive SCHEME_CURRENT

Write-Host "Restored screen timeout (AC: $($backup.ACSeconds) sec, DC: $($backup.DCSeconds) sec)." -ForegroundColor Green

Remove-Item -Path $backupFile -Force

Start-Sleep -Seconds 3
