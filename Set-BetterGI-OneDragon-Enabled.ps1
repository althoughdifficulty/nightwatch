# 查询 / 暂停 / 恢复「BetterGI 一条龙」定时任务
#
#   .\Set-BetterGI-OneDragon-Enabled.ps1 -Action status    # 只看状态（不需要管理员）
#   .\Set-BetterGI-OneDragon-Enabled.ps1 -Action disable   # 暂停（保留任务，不再自动跑）
#   .\Set-BetterGI-OneDragon-Enabled.ps1 -Action enable    # 恢复
#
# 暂停不会丢任何设置，随时可以恢复。
[CmdletBinding()]
param(
    [ValidateSet('status', 'disable', 'enable')]
    [string]$Action = 'status',
    [string]$TaskName = 'BetterGI-OneDragon'
)

$ErrorActionPreference = 'Stop'

function Show-Status {
    param([string]$Name)
    $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $t) {
        Write-Host ('  任务不存在：' + $Name + '（可以用 Install-BetterGI-OneDragon-Task.ps1 重新安装）') -ForegroundColor Yellow
        return $false
    }
    $info = Get-ScheduledTaskInfo -TaskName $Name
    $enabled = ($t.State -ne 'Disabled')
    $color = if ($enabled) { 'Green' } else { 'Yellow' }
    Write-Host ''
    Write-Host ('  任务      : ' + $Name)
    Write-Host ('  状态      : ' + $t.State + $(if ($enabled) { '  (已启用)' } else { '  (已暂停)' })) -ForegroundColor $color
    if ($enabled) {
        Write-Host ('  下次运行  : ' + $info.NextRunTime)
    } else {
        Write-Host  '  下次运行  : 无（已暂停）'
    }
    Write-Host ('  上次运行  : ' + $info.LastRunTime + '   结果=' + $info.LastTaskResult)
    Write-Host ''
    return $true
}

# status 不需要管理员
if ($Action -eq 'status') {
    [void](Show-Status -Name $TaskName)
    exit 0
}

# disable / enable 需要管理员
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '需要管理员权限，正在请求提权（请点 UAC 的「是」）...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Action', $Action, '-TaskName', ('"' + $TaskName + '"'))
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null }
    catch { Write-Host '提权被取消，没有做任何改动。' -ForegroundColor Red; exit 1 }
    exit 0
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) { Write-Host ('任务不存在：' + $TaskName) -ForegroundColor Red; exit 1 }

if ($Action -eq 'disable') {
    Disable-ScheduledTask -TaskName $TaskName | Out-Null
    Write-Host ''
    Write-Host '  已暂停：不会再自动唤醒/运行。任务本身和全部设置都还在，随时可以恢复。' -ForegroundColor Yellow
} else {
    Enable-ScheduledTask -TaskName $TaskName | Out-Null
    Write-Host ''
    Write-Host '  已恢复：会按原定时间自动运行。' -ForegroundColor Green
}

[void](Show-Status -Name $TaskName)
Write-Host '  提示：日志在脚本目录的 logs\ 里。' -ForegroundColor Gray
