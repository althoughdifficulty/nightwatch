@echo off
rem ASCII-only launcher: all Chinese/Unicode handling is done inside PowerShell
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Change-Time.ps1" %*
endlocal