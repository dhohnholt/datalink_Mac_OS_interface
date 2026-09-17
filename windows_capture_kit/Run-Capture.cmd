@echo off
setlocal
title DataLink Windows Capture
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0Start-Capture.ps1"
echo.
echo PowerShell could not be started or exited unexpectedly.
pause
