# 交互式修改「BetterGI 一条龙」的触发时间
#
# 直接运行（双击 Change-Time.cmd，或手动跑本脚本）会提示输入新时间；
# 也可以带参数直接改：  .\Change-Time.ps1 -Time 06:30 [-Days Weekdays]
[CmdletBinding()]
param(
    [string]$Time = '',
    [string]$Days = '',
    [string]$TaskName = 'BetterGI-OneDragon'
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$setter = Join-Path $here 'Set-BetterGI-OneDragon-Time.ps1'
if (-not (Test-Path $setter)) { Write-Host ('找不到 ' + $setter) -ForegroundColor Red; exit 1 }

function Show-Current {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) {
        Write-Host ''
        Write-Host ('  任务不存在：' + $TaskName) -ForegroundColor Yellow
        Write-Host '  请先运行「一键安装」那两个文件。' -ForegroundColor Yellow
        Write-Host ''
        return $false
    }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host ''
    Write-Host '  ===== 当前状态 =====' -ForegroundColor Cyan
    Write-Host ('  任务    : ' + $TaskName)
    Write-Host ('  状态    : ' + $t.State + $(if ($t.State -eq 'Disabled') { '  (已暂停)' } else { '  (已启用)' }))
    Write-Host ('  下次运行: ' + $info.NextRunTime)
    Write-Host ('  上次运行: ' + $info.LastRunTime + '   结果=' + $info.LastTaskResult)
    Write-Host ''
    return $true
}

# 交互模式：提示输入
if (-not $Time) {
    if (-not (Show-Current)) { Read-Host '按回车退出'; exit 1 }
    Write-Host '  请输入新的触发时间，格式 24 小时制，例如 04:30 或 6:30' -ForegroundColor Gray
    $Time = Read-Host '  新时间'
    if (-not $Time) { Write-Host '  没输入，退出。' -ForegroundColor Yellow; Read-Host '按回车退出'; exit 0 }
    $Time = $Time.Trim()
    Write-Host ''
    Write-Host '  只想改时间就直接回车；也可以填 Weekdays / Weekend / Monday,Tuesday' -ForegroundColor Gray
    $Days = Read-Host '  星期（可留空）'
    if ($Days) { $Days = $Days.Trim() }
}

# 先在这里校验，避免提权之后才发现格式不对
$ts = [datetime]::MinValue
$ok = $false
foreach ($fmt in @('HH:mm', 'H:mm')) {
    if ([datetime]::TryParseExact($Time, $fmt, $null, [System.Globalization.DateTimeStyles]::None, [ref]$ts)) { $ok = $true; break }
}
if (-not $ok) {
    Write-Host ''
    Write-Host ('  时间格式不对：' + $Time) -ForegroundColor Red
    Write-Host '  要写成 24 小时制的 时:分，例如 04:30' -ForegroundColor Red
    Read-Host '  按回车退出'
    exit 1
}
$normalized = $ts.ToString('HH:mm')

Write-Host ''
Write-Host ('  即将把触发时间改为 ' + $normalized + $(if ($Days) { ('（' + $Days + '）') } else { '（星期设置保持不变）' })) -ForegroundColor Green
Write-Host '  接下来会弹 UAC，请点「是」。' -ForegroundColor Yellow
Write-Host ''

# 提权执行真正的修改
$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $setter + '"'), '-Time', $normalized, '-TaskName', ('"' + $TaskName + '"'))
if ($Days) { $argList += '-Days'; $argList += ('"' + $Days + '"') }

try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait
} catch {
    Write-Host '  提权被取消，时间没有修改。' -ForegroundColor Red
    Read-Host '  按回车退出'
    exit 1
}

Start-Sleep -Seconds 1
[void](Show-Current)
Read-Host '  按回车退出'
