@echo off
title DISM/SFC


echo === Starting DISM and SFC scan using PowerShell ===
powershell -Command "Write-Host 'Running DISM /RestoreHealth...' -ForegroundColor Cyan; DISM /Online /Cleanup-Image /RestoreHealth; Write-Host 'DISM completed.' -ForegroundColor Green; Write-Host 'Running SFC /scannow...' -ForegroundColor Cyan; sfc /scannow; Write-Host 'SFC completed.' -ForegroundColor Green"

echo When you finish DISM/SFC, press any key to continue...
pause >nul

echo === All scans complete ===
exit