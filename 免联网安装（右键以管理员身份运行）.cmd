@echo off
rem ASCII-only launcher: installs the NO-NETWORK variant (-NoNetwork)
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-BetterGI-OneDragon-Task.ps1" -NoNetwork %*
endlocal