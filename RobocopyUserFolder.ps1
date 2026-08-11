$usersPath = "$env:SystemDrive\Users"

$volumes = Get-Volume
$volumes | Out-Host

$backupPath = ""
$isValidBackupPath = $false
while (-not $isValidBackupPath) {
    $backupVolumeSelection = Read-Host "Select Backup Volume "
    $cleanedVolumeSelection = $backupVolumeSelection.Replace(":", "").ToUpper()

    $backupVolume = $volumes | Where-Object { $_.DriveLetter -eq $cleanedVolumeSelection }

    if($backupVolume.DriveLetter) {
        $backupPath = "$($backupVolume.DriveLetter):\Users"

        if (Test-Path -Path "$($backupVolume.DriveLetter):\") {
            $isValidBackupPath = $true
        } else {
            Write-Host "Volume exists but path is inaccessible." -ForegroundColor Red
        }
    } else {
            Write-Host "Invalid Volume Selection" -ForegroundColor Red
    }
}

try {
    $areYouSure = Read-Host "Are you sure you want to robocopy $($usersPath) to $($backupPath)? (Y/N) "
    if($areyouSure.ToLower() -eq 'y') {
        
        $includeAppData = Read-Host "Do you want to include the AppData folder? (Y/N)"

        $excludeDirs = @(
            "$usersPath\Public", 
            "$usersPath\Default", 
            "$usersPath\Default User", 
            "$usersPath\All Users"
        )
        
        # Dynamically get the actual user profile folders to avoid Robocopy wildcard errors
        $userProfiles = Get-ChildItem -Path $usersPath -Directory | Where-Object { 
            $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') 
        }

        if ($includeAppData.ToLower() -eq 'y') {
            Write-Host "AppData will be copied (safely excluding Temp and OS Shell files)." -ForegroundColor Cyan
            # Build exact exclusion paths for each user profile found
            foreach ($userProfile in $userProfiles) {
                $excludeDirs += "$($userProfile.FullName)\AppData\Local\Temp"
                $excludeDirs += "$($userProfile.FullName)\AppData\Local\Microsoft\Windows"
                $excludeDirs += "$($userProfile.FullName)\AppData\Local\Microsoft\Windows\WebCache"
            }
        } else {
            Write-Host "AppData will be skipped." -ForegroundColor Yellow
            $excludeDirs += "AppData"
        }

        $mtCount = 1 # Default safe value for HDDs or unknown hardware
        try {
            $sysDriveLetter = $env:SystemDrive.Replace(":", "")
            $diskNum = (Get-Partition -DriveLetter $sysDriveLetter).DiskNumber
            $mediaType = (Get-PhysicalDisk | Where-Object DeviceID -eq $diskNum).MediaType
            
            if ($mediaType -eq 'SSD') {
                $mtCount = 16
                Write-Host "SSD detected on source. Enabling high-speed multithreading (/MT:16)." -ForegroundColor Cyan
            } else {
                Write-Host "HDD or Unspecified drive detected. Using safe multithreading (/MT:4)." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "Could not determine drive type. Defaulting to safe multithreading (/MT:4)." -ForegroundColor Yellow
        }

        Write-Host "Starting backup... A log will be saved to $backupPath\MigrationLog.txt" -ForegroundColor Cyan
        if (-not (Test-Path $backupPath)) {
            New-Item -ItemType Directory -Force -Path $backupPath | Out-Null
        }
        $logFile = "$backupPath\RobocopyLog.txt"
        $roboArgs = @(
            $usersPath,
            $backupPath,
            "/B", "/E", "/XJ",
            "/R:1", "/W:1",
            "/MT:$mtCount",
            "/TEE",
            "/UNILOG:$logFile",
            "/XF", "ntuser.*",
            "/XD"
        )
        $roboArgs += $excludeDirs

        & robocopy $roboArgs

        if ($LASTEXITCODE -ge 8) {
            throw "Robocopy failed with exit code $LASTEXITCODE."
        }

        Write-Host "Robocopy Complete!" -ForegroundColor Green
    } else {
        Write-Host "Robocopy canceled. Bye o/"
    }
}
catch {
    Write-Host "ERROR: Robocopy encountered a problem." -ForegroundColor Red 
    Write-Host "Details: $_" -ForegroundColor Yellow
}

Write-Host ""
Read-Host "Press Enter to close this window"