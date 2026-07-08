$ErrorActionPreference = "SilentlyContinue"

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " DETECTING FLASH DRIVE AND MOTHERBOARD..." -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# Gets MRI drive
$FoundDrive = (Get-Volume).DriveLetter | Where-Object { Test-Path "$_`:\AppInstalls\GS_Scripts" } | Select-Object -First 1

if ($FoundDrive) {
    $DRIVE = "$FoundDrive`:"
    Write-Host " USB Drive located at: $DRIVE" -ForegroundColor Green
} else {
    Write-Host " [CRITICAL] Could not locate the \AppInstalls\GS_Scripts folder on any drive!" -ForegroundColor Red
    Write-Host " Please ensure the flash drive is plugged in." -ForegroundColor Red
    Read-Host " Press Enter to exit..."
    Exit
}

# Modern Hardware Interrogation
$OEM = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
Write-Host " Detected System: $OEM`n" -ForegroundColor Green

# ==========================================
#  DELL LOGIC 
# ==========================================
if ($OEM -match "Dell") {
    Write-Host "Installing .NET 8 Desktop Runtime Dependency..." -ForegroundColor Yellow
    
    $DotNetInstaller = "$DRIVE\AppInstalls\GS_Scripts\Dell Command Update\windowsdesktop-runtime-8.0.27-win-x64.exe" 
    
    # Runs the .NET installer silently
    if (Test-Path $DotNetInstaller) {
        Start-Process -FilePath $DotNetInstaller -ArgumentList "/install /quiet /norestart" -Wait
    } else {
        Write-Host "[WARNING] .NET Installer missing from flash drive! DCU may fail." -ForegroundColor Red
    }

    Write-Host "Launching Dell Command Update..." -ForegroundColor Yellow
    
    # Install Dell silently
    Start-Process -FilePath "$DRIVE\AppInstalls\GS_Scripts\Dell Command Update\DellCommandUpdateApp_Setup.exe" -ArgumentList "/s" -Wait
    Start-Sleep -Seconds 10

    $ScanLog = "$env:TEMP\dcu_scan.log"

    $DcuPath = ""
    if (Test-Path "C:\Program Files\Dell\CommandUpdate\dcu-cli.exe") {
        $DcuPath = "C:\Program Files\Dell\CommandUpdate\dcu-cli.exe"
    } elseif (Test-Path "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe") {
        $DcuPath = "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe"
    } else {
        Write-Host "[ERROR] Dell Command Update CLI not found! Installation may have failed." -ForegroundColor Red
        return
    }
    
    Write-Host "Scanning Hardware..." -ForegroundColor Yellow
    Start-Process -FilePath $DcuPath -ArgumentList "/scan" -RedirectStandardOutput $ScanLog -Wait
    
    if (-not (Test-Path $ScanLog) -or (Get-Item $ScanLog).Length -eq 0) {
        Write-Host "`n[ERROR] Scan log was not generated. DCU scan failed." -ForegroundColor Red
    }
    else {
        # Parse the log for BIOS/UEFI Updates
        $ScanResults = Get-Content $ScanLog
        if ($ScanResults -match "0 updates" -or $ScanResults -match "No updates" -or $ScanResults -match "No applicable updates"){
            Write-Host "`nSystem hardware is fully up to date! " -ForegroundColor Cyan
        }
        elseif ($ScanResults -match "BIOS" -or $ScanResults -match "UEFI") {
            Write-Host "`n[CRITICAL] BIOS UPDATE DETECTED IN PENDING LIST!" -ForegroundColor Red
            # AUDIO ALARM: 3 rapid, high-pitched beeps (1500Hz)
            [System.Console]::Beep(1500, 300)
            Start-Sleep -Milliseconds 100
            [System.Console]::Beep(1500, 300)
            Start-Sleep -Milliseconds 100
            [System.Console]::Beep(1500, 600)
            $title = "Safety Gate"
            $message = "Dell CLI found a pending BIOS update. Is the unit on AC power?"
            $options = [System.Management.Automation.Host.ChoiceDescription[]] @("&Yes (Automate All)", "&No (Skip BIOS)")
            $result = $Host.UI.PromptForChoice($title, $message, $options, 1)

            if ($result -eq 0) {
                Write-Host "Installing ALL updates including BIOS..." -ForegroundColor Red
                Start-Process -FilePath $DcuPath -ArgumentList "/applyUpdates -reboot=disable" -Wait
            } else {
                Write-Host "Skipping BIOS. Installing Drivers and Apps only..." -ForegroundColor Green
                Start-Process -FilePath $DcuPath -ArgumentList "/applyUpdates -updateType=Driver,Application -reboot=disable" -Wait
            }
        } 
        else {
                Write-Host "No BIOS updates detected! Proceeding automatically..." -ForegroundColor Green
                Start-Process -FilePath $DcuPath -ArgumentList "/applyUpdates -reboot=disable" -Wait
        }
    }

    Write-Host "Cleaning up..." -ForegroundColor Yellow
    Remove-Item $ScanLog -Force
    Start-Process -FilePath "$DRIVE\AppInstalls\GS_Scripts\Dell Command Update\DellCommandUpdateApp_Setup.exe" -ArgumentList "/s /x" -Wait
    Write-Host "Finished installing updates." -ForegroundColor Green
}

# ==========================================
#  HP LOGIC
# ==========================================
elseif ($OEM -match "HP" -or $OEM -match "Hewlett-Packard") {
    $HPModel = (Get-CimInstance -ClassName Win32_ComputerSystem).Model
    
    # Detects if this is a retail/consumer line laptop
    if ($HPModel -match "Envy|Pavilion|Spectre|Omen|Victus|Stream") {
        Write-Host "`n====================================================" -ForegroundColor Magenta
        Write-Host " HP CONSUMER LINE DETECTED: $HPModel" -ForegroundColor Magenta
        Write-Host "====================================================" -ForegroundColor Magenta
        Write-Host " HP Image Assistant does not support consumer hardware." -ForegroundColor Yellow
        Write-Host " You must use the HP Support Assistant GUI." -ForegroundColor Yellow
        
        [System.Console]::Beep(800, 400)

        Write-Host " Attempting to launch HP Support Assistant..." -ForegroundColor Cyan
        
        # Paths for HPSA (Classic Win32 or Modern UWP app trigger)
        $HPSAPath = "C:\Program Files (x86)\Hewlett-Packard\HP Support Framework\HPSF.exe"
        if (Test-Path $HPSAPath) {
            Start-Process -FilePath $HPSAPath
        } else {
            # Attempts to trigger the Windows Store app version URI
            Start-Process "hpsupportassistant:" -ErrorAction SilentlyContinue
            Write-Host " [NOTE] If HPSA does not open, please launch it manually from the Start Menu." -ForegroundColor DarkGray
        }

        Read-Host " Press Enter once you finish updating via the HP GUI to continue..."
    } 
    else {
        # Standard HPIA execution for EliteBooks/ProBooks
        Write-Host " Commercial HP Detected ($HPModel). Launching HP Image Assistant..." -ForegroundColor Yellow
        
        $ReportDir = "C:\Temp\HPIA"
        
        Start-Process -FilePath "$DRIVE\AppInstalls\GS_Scripts\HP Image Assistant\HPImageAssistant.exe" -ArgumentList "/Operation:Analyze /Action:None /Silent /ReportFolder:$ReportDir" -Wait

        $UpdatesExist = Get-ChildItem -Path $ReportDir -Recurse -Include *.xml | Select-String -Pattern "<SoftPaq" -Quiet

        if(-not $UpdatesExist){
            Write-Host "`nSystem hardware is fully up to date! " -ForegroundColor Cyan
        }
        else {
            $BiosFound = Get-ChildItem -Path $ReportDir -Recurse -Include *.xml, *.html | Select-String -Pattern "BIOS|UEFI" -Quiet

            if ($BiosFound) {
                Write-Host "`n[CRITICAL] BIOS UPDATE DETECTED IN HP REPORT!" -ForegroundColor Red          
                [System.Console]::Beep(1500, 300)
                Start-Sleep -Milliseconds 100
                [System.Console]::Beep(1500, 300)
                Start-Sleep -Milliseconds 100
                [System.Console]::Beep(1500, 600)

                $title = "Safety Gate"
                $message = "HP found a pending BIOS update. How do you want to proceed?"
                $options = [System.Management.Automation.Host.ChoiceDescription[]] @("&Danger (Automate All)", "&Safe (Launch GUI to uncheck BIOS)")
                $result = $Host.UI.PromptForChoice($title, $message, $options, 1)

                if ($result -eq 0) {
                    Start-Process -FilePath "$DRIVE\AppInstalls\GS_Scripts\HP Image Assistant\HPImageAssistant.exe" -ArgumentList "/Operation:Analyze /Action:Install /NonInteractive /ReportFolder:$ReportDir" -Wait
                } 
                else {
                    Write-Host "Launching HP UI. Please uncheck the BIOS manually..." -ForegroundColor Green
                    Start-Process -FilePath "$DRIVE\AppInstalls\GS_Scripts\HP Image Assistant\HPImageAssistant.exe" -Wait
                }
            } 
            else {
                Write-Host "No BIOS updates detected! Proceeding automatically..." -ForegroundColor Green
                Start-Process -FilePath "$DRIVE\AppInstalls\GS_Scripts\HP Image Assistant\HPImageAssistant.exe" -ArgumentList "/Operation:Analyze /Action:Install /NonInteractive /ReportFolder:$ReportDir" -Wait
            }
        }
        
        Write-Host "Cleaning up..." -ForegroundColor Yellow
        if (Test-Path $ReportDir) { Remove-Item $ReportDir -Recurse -Force }
        Write-Host "Finished installing updates." -ForegroundColor Green
    }
}

# ==========================================
#  LENOVO LOGIC
# ==========================================
elseif ($OEM -match "Lenovo") {
    Write-Host "Launching Lenovo ThinInstaller..." -ForegroundColor Yellow
    
    $TiLog = "$env:TEMP\ti_scan.log"
    
    # Scans for updates
    Start-Process -FilePath "$DRIVE\AppInstalls\GS_Scripts\ThinInstaller\ThinInstaller.exe" -ArgumentList "/CM -search A -action LIST -noicon -log $TiLog" -Wait

    # Checks if log was created ( log usually indicates if there are any updates found )
    if(-not (Test-Path $TiLog) -or (Get-Item $TiLog).Length -eq 0) {
        Write-Host "`nSystem hardware is fully up to date! ( No Log generated )" -ForegroundColor Cyan
    }
    else {
        # Parse the Lenovo Log file
        $ScanResults = Get-Content $TiLog
        
        if ($ScanResults -match "0 packages" -or $ScanResults -match "No applicable packages" -or $ScanResults -match "0 updates" -or $ScanResults -match "No updates" -or $ScanResults -match "No applicable updates"){
            Write-Host "`nSystem hardware is fully up to date! " -ForegroundColor Cyan
        }
        elseif ($ScanResults -match "BIOS" -or $ScanResults -match "UEFI") {
            Write-Host "`n[CRITICAL] BIOS UPDATE DETECTED IN LENOVO LOG!" -ForegroundColor Red
            # AUDIO ALARM: 3 rapid, high-pitched beeps (1500Hz)
            [System.Console]::Beep(1500, 300)
            Start-Sleep -Milliseconds 100
            [System.Console]::Beep(1500, 300)
            Start-Sleep -Milliseconds 100
            [System.Console]::Beep(1500, 600)

            $title = "Safety Gate"
            $message = "Lenovo found a pending BIOS update. How do you want to proceed?"
            $options = [System.Management.Automation.Host.ChoiceDescription[]] @("&Danger (Automate All)", "&Safe (Launch GUI to uncheck BIOS)")
            $result = $Host.UI.PromptForChoice($title, $message, $options, 1)

            if ($result -eq 0) {
                Start-Process -FilePath "$DRIVE\AppInstalls\GS_Scripts\ThinInstaller\ThinInstaller.exe" -ArgumentList "/CM -search A -action INSTALL -noicon -noreboot" -Wait
            } else {
                Write-Host "Launching Lenovo UI. Please uncheck the BIOS manually..." -ForegroundColor Green
                Start-Process -FilePath "$DRIVE\AppInstalls\GS_Scripts\ThinInstaller\ThinInstaller.exe" -Wait
            }
        } else {
            Write-Host "No BIOS updates detected! Proceeding automatically..." -ForegroundColor Green
            Start-Process -FilePath "$DRIVE\AppInstalls\GS_Scripts\ThinInstaller\ThinInstaller.exe" -ArgumentList "/CM -search A -action INSTALL -noicon -noreboot" -Wait
        }
    }

    Write-Host "Cleaning up..." -ForegroundColor Yellow
    if(Test-Path $TiLog) {
        Remove-Item $TiLog -Force
    }
    Write-Host "Finished installing updates." -ForegroundColor Green
}
else {
    Write-Host "`n====================================================" -ForegroundColor Magenta
    Write-Host " CONSUMER / CUSTOM BUILD DETECTED" -ForegroundColor Magenta
    Write-Host "====================================================" -ForegroundColor Magenta
    Write-Host " Manufacturer ($OEM) does not support silent CLI updates." -ForegroundColor Yellow

    $Motherboard = Get-CimInstance -ClassName Win32_BaseBoard
    $BiosInfo = Get-CimInstance -ClassName Win32_BIOS

    Write-Host "`n --- HARDWARE TARGETS ---" -ForegroundColor Cyan
    Write-Host " Motherboard Maker: $($Motherboard.Manufacturer)"
    Write-Host " Motherboard Model: $($Motherboard.Product)"
    Write-Host " Current BIOS Ver : $($BiosInfo.SMBIOSBIOSVersion)"
    Write-Host " Release Date     : $($BiosInfo.ReleaseDate.ToString('yyyy-MM-dd'))"
    
    Write-Host "`n[ACTION REQUIRED] Please manually verify BIOS for $($Mobo.Product)." -ForegroundColor Red

    # AUDIO ALARM
    [System.Console]::Beep(800, 400)
    Start-Sleep -Milliseconds 100
    [System.Console]::Beep(800, 400)

    $title = "Manual Intervention"
    $message = "Do you want to open the manufacturer's support page?"
    $options = [System.Management.Automation.Host.ChoiceDescription[]] @("&Yes (Open Browser)", "&No (Skip to Windows Update)")
    $result = $Host.UI.PromptForChoice($title, $message, $options, 1)

    if ($result -eq 0) {
        # Tries to auto-search the exact motherboard model
        $SearchQuery = "$($Mobo.Manufacturer) $($Mobo.Product) drivers support"
        $SearchQuery = $SearchQuery -replace ' ', '+'
        Start-Process "https://www.google.com/search?q=$SearchQuery"
        Write-Host "Browser launched. Pausing script until you finish manual updates." -ForegroundColor Yellow
        Read-Host "Press Enter once you are done to continue to Windows Updates..."
    } 
    else {
        Write-Host "Skipping manual BIOS check..." -ForegroundColor Green
    }
}

# ==========================================
# WINDOWS UPDATE HANDOFF
# ==========================================
#Write-Host "`n====================================================" -ForegroundColor Cyan
#Write-Host " OEM UPDATES COMPLETE! LAUNCHING WINDOWS UPDATE..." -ForegroundColor Cyan
#Write-Host "====================================================" -ForegroundColor Cyan

#& "%DRIVE%\AppInstalls\GS_Scripts\Tools\WindowsUpdate.ps1"

Read-Host -Prompt "Press enter to continue..."