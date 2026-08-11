$backupDir = "C:\ProgramData\GeekSquad"
$backupFile = Join-Path $backupDir "ScreenTimeoutBackup.json"

if (-not (Test-Path $backupDir)) {
    New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
}

function Get-MonitorTimeout($powerType) {
    $output = powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE
    $line = $output | Select-String "Current $powerType Power Setting Index"
    if ($line -match '0x([0-9a-fA-F]+)') {
        return [Convert]::ToInt32($matches[1], 16)
    }
    return $null
}

if (Test-Path $backupFile) {
    Write-Host "[!] A screen timeout backup already exists for this device." -ForegroundColor Yellow
    Write-Host "Skipping save to avoid overwriting the original setting." -ForegroundColor Yellow
} else {
    $acSeconds = Get-MonitorTimeout "AC"
    $dcSeconds = Get-MonitorTimeout "DC"

    if ($null -eq $acSeconds -or $null -eq $dcSeconds) {
        Write-Host "ERROR: Could not read current screen timeout settings. Aborting." -ForegroundColor Red
        Start-Sleep -Seconds 5
        exit 1
    }

    @{ ACSeconds = $acSeconds; DCSeconds = $dcSeconds } | ConvertTo-Json | Set-Content -Path $backupFile
    Write-Host "Saved current screen timeout (AC: $acSeconds sec, DC: $dcSeconds sec) to $backupFile" -ForegroundColor Cyan
}

powercfg /change monitor-timeout-ac 0
powercfg /change monitor-timeout-dc 0

Write-Host "Screen turn-off time set to Never (plugged in and on battery)." -ForegroundColor Green
Start-Sleep -Seconds 3
