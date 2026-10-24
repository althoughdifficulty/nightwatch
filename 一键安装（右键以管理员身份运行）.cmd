@echo off
rem ASCII-only launcher (all Chinese output comes from PowerShell)
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-BetterGI-OneDragon-Task.ps1" %*
endlocal