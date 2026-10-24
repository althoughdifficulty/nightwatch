@echo off
rem ASCII-only launcher (all Chinese output comes from PowerShell)
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Toggle-Task.ps1" %*
endlocal