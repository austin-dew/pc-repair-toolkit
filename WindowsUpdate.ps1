# ==========================================
# SELF-ELEVATION BLOCK (Crucial for Auto-Resume)
# ==========================================
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

# ==========================================
# Auto-Copy to Local Drive
# ==========================================
$LocalDir = "C:\GS_Temp"
$LocalScriptPath = "$LocalDir\$($MyInvocation.MyCommand.Name)"

# Define persistent log files for the summary
$SuccessLog = "$LocalDir\WU_Success.txt"
$FailedLog = "$LocalDir\WU_Failed.txt"

# Check if we are running from a removable drive (USB)
$ScriptDrive = $PSCommandPath.Substring(0,1)
$IsRemovable = (Get-Volume -DriveLetter $ScriptDrive -ErrorAction SilentlyContinue).DriveType -eq 'Removable'

if ($IsRemovable) {
    Write-Host "USB Drive detected. Staging payload to local drive ($LocalDir)..." -ForegroundColor Yellow
    
    if (-not (Test-Path $LocalDir)) { New-Item -ItemType Directory -Path $LocalDir | Out-Null }
    
    # Copy itself to the local temp folder
    Copy-Item -Path $PSCommandPath -Destination $LocalScriptPath -Force
    
    Write-Host "Payload dropped. Relaunching locally so you can remove your USB..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2
    
    # Launch the local copy and instantly kill this USB instance
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File `"$LocalScriptPath`""
    Exit
}

# Full session transcript (cumulative across all reboot-resume passes) for diagnosing
# runs that don't behave as expected after the fact
$TranscriptPath = "$LocalDir\WU_Transcript.log"
try { Start-Transcript -Path $TranscriptPath -Append -ErrorAction Stop | Out-Null } catch {}

$host.UI.RawUI.WindowTitle = "Windows Updates"
Write-Host "=== Installing Windows Updates via PowerShell ===" -ForegroundColor Green

# Bypasses execution policy just this once
Set-ExecutionPolicy Bypass -Scope Process -Force

# Force TLS 1.2 up front - brand new OOBE machines sometimes default to an older
# protocol, which can silently hang the NuGet/PSGallery calls below
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Auto-accept NuGet provider BEFORE touching PSGallery. PSGallery is a NuGet-based
# repository, so if Get-PSRepository/Set-PSRepository below runs first and NuGet
# isn't installed yet, PowerShellGet throws its own interactive "NuGet provider is
# required to continue" prompt right there - installing NuGet first prevents that
# prompt from ever being triggered.
if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false | Out-Null
}

# Trust PSGallery up front - an untrusted repo can silently hang Install-Module below
if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
}

# Installs and Imports windows module update silently
if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)){
    Install-Module -Name PSWindowsUpdate -Force -SkipPublisherCheck | Out-Null
}
Import-Module PSWindowsUpdate

# Adds the Microsoft Update service to catch optional/OEM updates
Add-WUServiceManager -ServiceID "7971f918-a847-4430-9279-4a52d1efe18d" -Confirm:$false | Out-Null

# ==========================================
# SMART CACHE HEALTH CHECK
# ==========================================
Write-Host "Evaluating Windows Update Cache health..." -ForegroundColor Cyan

# Only look at events since the last time we checked (persisted across reboot-resume
# passes), so a stale historical failure doesn't trigger a fresh flush on every pass
$CacheCheckMarker = "$LocalDir\WU_LastCacheCheck.txt"
$CheckSince = if (Test-Path $CacheCheckMarker) { Get-Date (Get-Content -Path $CacheCheckMarker -Raw) } else { (Get-Date).AddHours(-1) }

# Scans the System log for Windows Update Installation Failures (Event ID 20) since then
$LastUpdateAttempts = Get-WinEvent -FilterHashTable @{
    LogName='System'
    ProviderName='Microsoft-Windows-WindowsUpdateClient'
    StartTime=$CheckSince
} -ErrorAction SilentlyContinue

(Get-Date).ToString("o") | Out-File -FilePath $CacheCheckMarker -Encoding UTF8 -Force

# Checks if any recent attempts were an Installation Failure (Event ID 20)
$RecentFailures = $LastUpdateAttempts | Where-Object {$_.Id -eq 20}
if ($RecentFailures) {
    Write-Host "  -> [!] Detected recent Windows Update failures in the Event Log." -ForegroundColor Red
    Write-Host "  -> Corruption suspected. Initiating Cache Flush protocol..." -ForegroundColor Yellow
    
    # Kill the Update Services
    Stop-Service -Name wuauserv, bits, cryptSvc, msiserver -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    
    # Rename the corrupted folders
    $Time = Get-Date -Format "yyyyMMdd_HHmmss"
    Rename-Item -Path "C:\Windows\SoftwareDistribution" -NewName "SoftwareDistribution_$Time" -ErrorAction SilentlyContinue
    Rename-Item -Path "C:\Windows\System32\catroot2" -NewName "catroot2_$Time" -ErrorAction SilentlyContinue
    
    # Restart the Services
    Start-Service -Name wuauserv, bits, cryptSvc, msiserver -ErrorAction SilentlyContinue
    Write-Host "  -> Cache flushed and services restarted successfully." -ForegroundColor Green
    
    # Give the agent a few seconds to rebuild its internal folders before moving on
    Start-Sleep -Seconds 5 
} else {
    Write-Host "  -> Cache appears healthy (No recent failures). Skipping flush." -ForegroundColor Green
}

# ==========================================
# WSUS BYPASS & UPDATE INSTALLATION
# ==========================================
$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
$wsusEnabled = $false

if (Test-Path $regPath) {
    $wsusValue = (Get-ItemProperty -Path $regPath -Name "UseWuServer" -ErrorAction SilentlyContinue).UseWUServer
    if ($wsusValue -eq 1) {
        $wsusEnabled = $true
        Set-ItemProperty -Path $regPath -Name "UseWUServer" -Value 0
        Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
        Start-Service wuauserv -ErrorAction SilentlyContinue
        Write-Host "Bypassing local WSUS server to ping Microsoft directly..." -ForegroundColor Yellow
    }
}

Write-Host "Scanning for ALL available updates (This may take a minute)..." -ForegroundColor Cyan
# Pull the absolute master list of EVERYTHING (Bypassing all fragile API filters)
$AllPendingUpdates = @()
# Tracks whether the scan that actually succeeded used -MicrosoftUpdate, so the
# install loop below can match its scope - if the OEM/driver catalog crashed the
# scan entirely and we fell back to a plain scan, forcing -MicrosoftUpdate back in
# during install would reintroduce the same crash for otherwise-safe core updates
$ScanUsedMicrosoftUpdate = $false
try {
    $AllPendingUpdates = Get-WindowsUpdate -MicrosoftUpdate -ErrorAction Stop
    $ScanUsedMicrosoftUpdate = $true
}
catch {
    Write-Host "  -> [WARNING] Windows API crashed while parsing a malformed OEM driver!" -ForegroundColor Yellow
    Write-Host "  -> Dropping the OEM catalog and falling back to core Windows OS updates..." -ForegroundColor Cyan
    
    # Attempt 2: Pull ONLY core Windows updates, bypassing the broken third-party catalog
    try {
        $AllPendingUpdates = Get-WindowsUpdate -ErrorAction Stop
    } catch {
        Write-Host "  -> [ERROR] Core Windows Update service is failing." -ForegroundColor Red
        Write-Host "  -> Fatal Exception: $($_.Exception.Message)" -ForegroundColor DarkGray
        Write-Host "  -> [!] Local datastore corruption detected. Initiating Nuclear Cache Flush..." -ForegroundColor Magenta
        
        # NUCLEAR FLUSH
        Stop-Service -Name wuauserv, bits, cryptSvc, msiserver -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        
        $Time = Get-Date -Format "yyyyMMdd_HHmmss"
        Rename-Item -Path "C:\Windows\SoftwareDistribution" -NewName "SoftwareDistribution_$Time" -ErrorAction SilentlyContinue
        Rename-Item -Path "C:\Windows\System32\catroot2" -NewName "catroot2_$Time" -ErrorAction SilentlyContinue
        
        Start-Service -Name wuauserv, bits, cryptSvc, msiserver -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        
        # Attempt 3: Final attempt after Nuclear Flush
        Write-Host "  -> Cache cleared. Attempting final core OS scan..." -ForegroundColor Cyan
        try {
            $AllPendingUpdates = Get-WindowsUpdate -ErrorAction Stop
        } catch {
            Write-Host "  -> [FATAL] Windows Update is critically broken on this OS. Manual intervention required." -ForegroundColor Red
        }
    }
}

if ($AllPendingUpdates) {
    # Sort the master list locally using standard PowerShell Regex
    $SafeUpdates = $AllPendingUpdates | Where-Object { $_.Title -notmatch "Firmware|BIOS" }
    $FirmwareUpdates = $AllPendingUpdates | Where-Object { $_.Title -match "Firmware|BIOS" }

    $SuccessfulUpdates = @()
    $FailedUpdates = @()
    
    # Sequential Installation Loop (Protects against mid-install crashes)
    if ($SafeUpdates) {
        Write-Host "Processing safe updates sequentially..." -ForegroundColor Cyan
        foreach ($Update in $SafeUpdates) {
            try {
                # Must match the scope of the scan that actually succeeded above - using
                # -MicrosoftUpdate when the initial scan needed it finds driver/OEM updates
                # that the plain WU service doesn't carry; omitting it when the scan fell
                # back to plain WU avoids reintroducing whatever crashed the MU scan
                if ($ScanUsedMicrosoftUpdate) {
                    $Result = $Update | Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Download -Install -IgnoreReboot -Verbose -ErrorAction Stop
                } else {
                    $Result = $Update | Get-WindowsUpdate -AcceptAll -Download -Install -IgnoreReboot -Verbose -ErrorAction Stop
                }

                if ($Result -and $Result.Result -eq "Installed") {
                    $SuccessfulUpdates += $Result
                    # Logs successful updates to log file
                    $Update.Title | Out-File -FilePath $SuccessLog -Append -Encoding UTF8

                    if ($Result.RebootRequired -match "True" -or $Result.RebootRequired -eq $true) {
                        Write-Host "  -> [!] Pending reboot state triggered. Halting queue to execute restart..." -ForegroundColor Yellow
                        break
                    }
                } else {
                    # No exception was thrown, but the update didn't actually report success either -
                    # log it as failed instead of silently dropping it from both logs
                    $FailedUpdates += $Update
                    $Update.Title | Out-File -FilePath $FailedLog -Append -Encoding UTF8
                    Write-Host "  -> [WARNING] Update did not report success: $($Update.Title). Skipping..." -ForegroundColor Magenta
                }
            }
            catch {
                $FailedUpdates += $Update
                # Logs failed updates to log file
                $Update.Title | Out-File -FilePath $FailedLog -Append -Encoding UTF8
                Write-Host "  -> [WARNING] API rejected package: $($Update.Title). Skipping..." -ForegroundColor Magenta
            }
        }
    }
} else {
    $FirmwareUpdates = $null
}

# Restores WSUS after all updates have been checked/installed
if ($wsusEnabled) {
    Set-ItemProperty -Path $regPath -Name "UseWUServer" -Value 1
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue
    Write-Host "Restored original WSUS configuration." -ForegroundColor Yellow
}

# ==========================================
# AUTO-RESUME & THE "BURN" (Self-Destruct)
# ==========================================

# Prefer the per-update signal from the install loop, but also cross-check actual
# machine state in case no single update reported RebootRequired even though one is pending
$RebootFlaggedByUpdate = [bool]($SuccessfulUpdates | Where-Object {$_.RebootRequired -match "True" -or $_.RebootRequired -eq $true})
$RebootStatus = $null
try { $RebootStatus = Get-WURebootStatus -Silent -ErrorAction Stop } catch {}
$NeedsReboot = $RebootFlaggedByUpdate -or ($RebootStatus -and $RebootStatus.RebootRequired)

# Safety net against an endless reboot loop (e.g. a flaky update that keeps re-flagging
# RebootRequired every pass). Cap how many times we're willing to auto-resume.
$PassCountFile = "$LocalDir\WU_PassCount.txt"
$MaxPasses = 15
$PassCount = if (Test-Path $PassCountFile) { [int](Get-Content -Path $PassCountFile -Raw) } else { 0 }
$PassCount++
$PassCount | Out-File -FilePath $PassCountFile -Encoding UTF8 -Force

if ($NeedsReboot -and $PassCount -ge $MaxPasses) {
    Write-Host "`n[!] Reached the maximum of $MaxPasses reboot-resume passes without finishing." -ForegroundColor Red
    Write-Host "[!] Halting auto-resume to avoid an endless reboot loop - remaining updates need manual review." -ForegroundColor Red
    $NeedsReboot = $false
}

if($NeedsReboot) {
    Write-Host "`n=== Updates installed. A reboot is required. ===" -ForegroundColor Yellow

    if ($FirmwareUpdates) {
        # Don't block an unattended mid-job reboot on a human - just note it here.
        # The full warning + pause happens on the final pass, right before self-destruct.
        Write-Host "Note: $($FirmwareUpdates.Count) firmware/BIOS update(s) were detected and intentionally skipped." -ForegroundColor Yellow
        Write-Host "They'll be flagged for acknowledgment once the update queue finishes." -ForegroundColor Yellow
    }

    Write-Host "Injecting UAC-Bypass auto-resume into Task Scheduler..." -ForegroundColor Cyan

    # Build the Scheduled Task to bypass Windows 11 UAC blocks
    $TaskName = "GSWUAutoResume"
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File `"$LocalScriptPath`""
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Force | Out-Null

    Write-Host "Auto-resume set. PC will restart in 5 seconds..." -ForegroundColor Red
    Start-Sleep -Seconds 5
    try { Stop-Transcript -ErrorAction Stop | Out-Null } catch {}
    shutdown.exe /r /t 00 /f
}
else {
    # This block captures BOTH scenarios that don't need a reboot:
    # Updates installed but no reboot needed.
    # System was completely up to date to begin with.

    # ==========================================
    # BIOS / FIRMWARE WARNING
    # ==========================================
    # Shown here (job complete, about to self-destruct) rather than on every pass,
    # so an unattended auto-resume reboot never hangs waiting for someone at the bench.
    if ($FirmwareUpdates) {
        Write-Host "`n====================================================" -ForegroundColor Magenta
        Write-Host " [ACTION REQUIRED] BIOS / FIRMWARE UPDATE DETECTED" -ForegroundColor Magenta
        Write-Host "====================================================" -ForegroundColor Magenta
        Write-Host "The following firmware updates are available but were INTENTIONALLY SKIPPED:" -ForegroundColor Yellow
        $FirmwareUpdates | Select-Object -Property Title, KBArticleID | Format-Table -AutoSize
        Write-Host "Please install these manually via the Windows GUI or OEM tool after rebooting." -ForegroundColor Red

        # Audio alarm to alert you at the bench
        [System.Console]::Beep(800, 400)
        Start-Sleep -Milliseconds 100
        [System.Console]::Beep(800, 400)

        # Pauses the script so it doesn't instantly self-destruct and hide the warning
        Read-Host "Press Enter to acknowledge and continue..."
    }

    # ==========================================
    # 4. BENCH SUMMARY & BURN SEQUENCE
    # ==========================================
    Write-Host "`n====================================================" -ForegroundColor Green
    Write-Host " BENCH AUTOMATION SUMMARY" -ForegroundColor Green
    Write-Host "====================================================" -ForegroundColor Green

    $LoggedSuccess = @()
    if (Test-Path $SuccessLog){
        $LoggedSuccess = @(Get-Content -Path $SuccessLog | Select-Object -Unique)
        Write-Host "Successfully Automated ($($LoggedSuccess.Count) updates across all passes):" -ForegroundColor Green
        $LoggedSuccess | ForEach-Object { Write-Host "  -> $_" -ForegroundColor DarkGreen }
    }

    if (Test-Path $FailedLog) {
        # Drop anything that eventually succeeded on a later pass, and collapse duplicate
        # entries from a stubborn update that failed the same way on multiple passes
        $LoggedFailed = @(Get-Content -Path $FailedLog | Select-Object -Unique | Where-Object { $LoggedSuccess -notcontains $_ })
        if ($LoggedFailed) {
            Write-Host "`nRequires Manual Attention ($($LoggedFailed.Count) updates across all passes):" -ForegroundColor Red
            $LoggedFailed | ForEach-Object { Write-Host "  -> $_" -ForegroundColor DarkRed }
        }
    }
    
    if (-not (Test-Path $SuccessLog) -and -not (Test-Path $FailedLog)) {
        Write-Host "System was already up to date. No updates required." -ForegroundColor Cyan
    }

    # The Burn Sequence
    Read-Host "`nReview the summary above. Press Enter to commence self-destruct"

    Write-Host "Commencing self-destruct sequence..." -ForegroundColor Red
    try { Stop-Transcript -ErrorAction Stop | Out-Null } catch {}
    Unregister-ScheduledTask -TaskName "GSWUAutoResume" -Confirm:$false -ErrorAction SilentlyContinue
    Set-Location -Path "C:\"
    $CmdArgs = "/c ping 127.0.0.1 -n 3 > nul & rmdir /s /q `"$LocalDir`""
    Start-Process cmd.exe -WindowStyle Hidden -ArgumentList $CmdArgs
    Exit 0
}