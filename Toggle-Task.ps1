# 「BetterGI 一条龙」定时任务开关（交互菜单）
# 只负责显示状态和转调，真正的暂停/恢复/删除由对应脚本自己提权。
[CmdletBinding()]
param(
    [string]$TaskName = 'BetterGI-OneDragon'
)

$ErrorActionPreference = 'Continue'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

function Show-Head {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '  ===== BetterGI 一条龙 定时任务 =====' -ForegroundColor Cyan
    if (-not $t) {
        Write-Host ('  任务不存在：' + $TaskName) -ForegroundColor Yellow
        Write-Host '  可以用「一键安装」重新创建。' -ForegroundColor Yellow
        return $false
    }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    $enabled = ($t.State -ne 'Disabled')
    Write-Host ('  状态    : ' + $t.State + $(if ($enabled) { '  (已启用)' } else { '  (已暂停)' })) -ForegroundColor $(if ($enabled) { 'Green' } else { 'Yellow' })
    if ($enabled) { Write-Host ('  下次运行: ' + $info.NextRunTime) } else { Write-Host '  下次运行: 无（已暂停）' }
    Write-Host ('  上次运行: ' + $info.LastRunTime + '   结果=' + $info.LastTaskResult)
    Write-Host ''
    return $true
}

while ($true) {
    Clear-Host
    $exists = Show-Head
    Write-Host '  1 = 暂停（保留任务和全部设置，之后可随时恢复）'
    Write-Host '  2 = 恢复'
    Write-Host '  3 = 彻底删除任务'
    Write-Host '  Q = 退出，什么都不做'
    Write-Host ''
    $c = (Read-Host '  请选择 (1/2/3/Q)').Trim()

    if ($c -eq '' -or $c -match '^[Qq]') { break }

    if ($c -eq '1' -or $c -eq '2') {
        if (-not $exists) { Read-Host '  按回车继续'; continue }
        $acts = if ($c -eq '1') { 'disable' } else { 'enable' }
        & (Join-Path $here 'Set-BetterGI-OneDragon-Enabled.ps1') -Action $acts -TaskName $TaskName
    } elseif ($c -eq '3') {
        if (-not $exists) { Read-Host '  按回车继续'; continue }
        $ans = (Read-Host '  确定要彻底删除这个定时任务吗？输入 YES 确认').Trim()
        if ($ans -eq 'YES') {
            & (Join-Path $here 'Uninstall-BetterGI-OneDragon-Task.ps1') -TaskName $TaskName
        } else {
            Write-Host '  已取消。' -ForegroundColor Yellow
        }
    } else {
        Write-Host '  只能输入 1 / 2 / 3 / Q' -ForegroundColor Yellow
    }
    Read-Host '  按回车继续'
}
