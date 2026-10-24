# 修改「BetterGI 一条龙」定时任务的触发时间（需要管理员权限，会自动提权）
#
# 用法：
#   .\Set-BetterGI-OneDragon-Time.ps1 -Time 06:30
#   .\Set-BetterGI-OneDragon-Time.ps1 -Time 23:15 -Days Weekend
#   .\Set-BetterGI-OneDragon-Time.ps1 -Time 07:00 -Days Monday,Wednesday,Friday
#
# 不传 -Days 时保留原来的日期设置（原来每天就是每天，原来每周就还是原来那几天）。
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Time,
    [string[]]$Days = @(),
    [string]$TaskName = 'BetterGI-OneDragon'
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '需要管理员权限，正在请求提权（请点 UAC 的「是」）...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Time', ('"' + $Time + '"'), '-TaskName', ('"' + $TaskName + '"'))
    if ($Days -and $Days.Count -gt 0) {
        $argList += '-Days'
        $argList += ('"' + ($Days -join ',') + '"')
    }
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null }
    catch { Write-Host '提权被取消，时间没有修改。' -ForegroundColor Red; exit 1 }
    exit 0
}

# ---------------------------------------------------------------- 校验时间
$ts = [datetime]::MinValue
$ok = $false
foreach ($fmt in @('HH:mm', 'H:mm')) {
    if ([datetime]::TryParseExact($Time, $fmt, $null, [System.Globalization.DateTimeStyles]::None, [ref]$ts)) { $ok = $true; break }
}
if (-not $ok) { Write-Host ('时间格式不对: ' + $Time + '，请用 24 小时制如 06:30') -ForegroundColor Red; exit 1 }
$timeStr = $ts.ToString('HH:mm')

# ---------------------------------------------------------------- 找任务
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Host ('计划任务不存在: ' + $TaskName + '，请先运行 Install-BetterGI-OneDragon-Task.ps1 安装。') -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- 决定星期
$allDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
$dayList = @()
$useDaily = $true

if ($Days -and $Days.Count -gt 0) {
    $Days = @($Days | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($Days -contains 'Daily') {
        $useDaily = $true
    } elseif ($Days -contains 'Weekdays') {
        $useDaily = $false; $dayList = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
    } elseif ($Days -contains 'Weekend') {
        $useDaily = $false; $dayList = @('Saturday', 'Sunday')
    } else {
        $bad = @($Days | Where-Object { $allDays -notcontains $_ })
        if ($bad.Count -gt 0) {
            Write-Host ('星期写法不对: ' + ($bad -join ',') + '；可用 Monday..Sunday / Daily / Weekdays / Weekend') -ForegroundColor Red
            exit 1
        }
        $useDaily = $false; $dayList = $Days
    }
} else {
    # 沿用原任务的类型与星期
    $old = $task.Triggers[0]
    $oldType = ''
    try { $oldType = $old.CimClass.CimClassName } catch { }
    if ($oldType -eq 'MSFT_TaskWeeklyTrigger') {
        $useDaily = $false
        $mask = [int]$old.DaysOfWeek
        if ($mask -band 1) { $dayList += 'Sunday' }
        if ($mask -band 2) { $dayList += 'Monday' }
        if ($mask -band 4) { $dayList += 'Tuesday' }
        if ($mask -band 8) { $dayList += 'Wednesday' }
        if ($mask -band 16) { $dayList += 'Thursday' }
        if ($mask -band 32) { $dayList += 'Friday' }
        if ($mask -band 64) { $dayList += 'Saturday' }
        if ($dayList.Count -eq 0) { $useDaily = $true }
    } else {
        $useDaily = $true
    }
}

if ($useDaily) {
    $trigger = New-ScheduledTaskTrigger -Daily -At $timeStr
    $descText = '每天 ' + $timeStr
} else {
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $dayList -At $timeStr
    $descText = ($dayList -join ',') + ' ' + $timeStr
}

Set-ScheduledTask -TaskName $TaskName -Trigger $trigger | Out-Null

$t2 = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host ''
Write-Host ('已修改触发时间: ' + $descText) -ForegroundColor Green
Write-Host ('  下次运行时间 : ' + $info.NextRunTime)
Write-Host ('  唤醒运行     : ' + $t2.Settings.WakeToRun)
Write-Host ('  运行级别     : ' + $t2.Principal.RunLevel)
Write-Host ''
Write-Host '提示：如果电脑那时处于「关机」状态，Windows 无法唤醒它（只能靠 BIOS 定时开机）。' -ForegroundColor Gray
Write-Host '      休眠/睡眠都可以正常唤醒。' -ForegroundColor Gray
