Write-Host "Scanning for existing GS Restore points..." -ForegroundColor Cyan

$todayStr = Get-Date -Format 'yyyy-MM-dd'
$backupDescription = "GS Backup - $todayStr"
$existingBackup = Get-ComputerRestorePoint | Where-Object { $_.Description -match "$backupDescription" }

if ($existingBackup) {
    Write-Host "[!] A GS Backup restore point already exists on this unit." -ForegroundColor Yellow
    Write-Host "Skipping duplicate restore point." -ForegroundColor Yellow
} else {
    $free = [math]::Round((Get-PSDrive C).Free / 5GB, 2)

    if ($free -lt 5) { 
        Write-Host "WARNING: Only $free GB free on C: drive. Minimum 5 GB required." -ForegroundColor Yellow
        Write-Host "Skipping Restore Point to prevent filling the drive." -ForegroundColor Yellow
    } else { 
        Write-Host "Device has enough space ($free GB free). Creating System Restore Point..." -ForegroundColor Cyan
        
        Checkpoint-Computer -Description "$backupDescription" -RestorePointType 'MODIFY_SETTINGS'
        
        Write-Host "Restore Point created successfully!" -ForegroundColor Green
    } 
}

# Cleans up the registry key afterward
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue

Write-Host "Registry restored! Closing in 5 seconds..."
Start-Sleep -Seconds 5