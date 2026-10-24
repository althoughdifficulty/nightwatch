# 卸载「定时自动运行 BetterGI 一条龙」计划任务（需要管理员权限）
[CmdletBinding()]
param(
    [string]$TaskName = 'BetterGI-OneDragon'
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '需要管理员权限，正在请求提权...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-TaskName', ('"' + $TaskName + '"'))
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null }
    catch { Write-Host '提权被取消。' -ForegroundColor Red; exit 1 }
    exit 0
}

$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $t) {
    Write-Host ("计划任务不存在: " + $TaskName) -ForegroundColor Yellow
} else {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host ("已删除计划任务: " + $TaskName) -ForegroundColor Green
}

Write-Host ''
Write-Host '注意：电源设置（允许唤醒定时器 / 唤醒后不需密码）没有回滚，如有需要可自行在「电源选项」里改回。' -ForegroundColor Gray
Write-Host '如需彻底还原：powercfg /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 1 ; powercfg /setactive SCHEME_CURRENT' -ForegroundColor Gray
