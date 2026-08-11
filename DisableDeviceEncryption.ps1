function Get-VolumeEncryptionInfo {
    param([Parameter(Mandatory)][string]$DriveLetter)

    $output = manage-bde -status $DriveLetter 2>&1
    $conversionStatus = ($output | Select-String 'Conversion Status:\s*(.+)').Matches |
        ForEach-Object { $_.Groups[1].Value.Trim() } | Select-Object -First 1
    $percent = ($output | Select-String 'Percentage Encrypted:\s*(.+)').Matches |
        ForEach-Object { $_.Groups[1].Value.Trim() } | Select-Object -First 1

    if (-not $conversionStatus) {
        throw "Could not read encryption status ($($output -join ' '))"
    }

    [PSCustomObject]@{
        DriveLetter      = $DriveLetter
        ConversionStatus = $conversionStatus
        PercentEncrypted = $percent
    }
}

$manageBde = Get-Command manage-bde.exe -ErrorAction SilentlyContinue
if (-not $manageBde) {
    Write-Error "manage-bde.exe was not found on this system; cannot manage device encryption."
    return
}

$fixedDrives = Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } |
    Select-Object -ExpandProperty DriveLetter

if (-not $fixedDrives) {
    Write-Warning "No fixed drives with drive letters were found."
    return
}

foreach ($letter in $fixedDrives) {
    $drive = "$letter`:"
    try {
        $before = Get-VolumeEncryptionInfo -DriveLetter $drive

        switch ($before.ConversionStatus) {
            'Fully Decrypted' {
                Write-Host "$drive is not encrypted." -ForegroundColor Green
            }
            'Decryption In Progress' {
                Write-Host "$drive is already decrypting ($($before.PercentEncrypted))." -ForegroundColor Green
            }
            default {
                # Covers 'Fully Encrypted', 'Encryption In Progress', and 'Used Space
                # Only Encrypted' (Device Encryption's default mode) - anything not
                # already decrypted/decrypting needs -off.
                Write-Host "Starting decryption on $drive (was: $($before.ConversionStatus), $($before.PercentEncrypted))..." -ForegroundColor Yellow
                manage-bde -off $drive | Out-Null

                $after = Get-VolumeEncryptionInfo -DriveLetter $drive
                Write-Host "Decryption started on $drive - now: $($after.ConversionStatus) ($($after.PercentEncrypted))." -ForegroundColor Green
                Write-Host "This runs in the background and can take a while on large drives - confirm with 'manage-bde -status $drive' before returning the device." -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Error "Failed to process $drive`: $_"
    }
}

# checks decryption status
$isDecrypted = $false
while(-not $isDecrypted) {
    # Percentage Encrypted: ##%
    $percentageDecrypted = [double]::Parse((manage-bde -status C: | findstr "Percentage").Substring(26).TrimEnd('%').Trim(), [System.Globalization.CultureInfo]::InvariantCulture)
    if($percentageDecrypted -ne 0) {
        Write-Host "Decryption still in progress: $percentageDecrypted%" -ForegroundColor Yellow
        Start-Sleep -Seconds 30
    }
    else {
        Write-Host "Decryption completed." -ForegroundColor Green
        $isDecrypted = $true
    }
}

Write-Host ""
Read-Host "Press Enter to close this window"
