<#
.SYNOPSIS
    安装「定时自动运行 BetterGI 一条龙」计划任务。

.DESCRIPTION
    创建一个以最高权限、仅在当前用户登录时运行的计划任务：
      - 每天（或指定星期）在指定时间触发
      - 勾选「唤醒计算机运行此任务」，可从睡眠(S3)/休眠(S4)/现代待机(S0ix)唤醒
      - 触发后调用 Run-BetterGI-OneDragon.ps1：启动 BetterGI → 切到一条龙 → 点开始 → 校验

    需要管理员权限（脚本会自动弹 UAC 提权）。

.EXAMPLE
    .\Install-BetterGI-OneDragon-Task.ps1 -Time 04:30 -RunNow

.EXAMPLE
    .\Install-BetterGI-OneDragon-Task.ps1 -Time 07:00 -Days Weekdays -SkipIfRanToday false
#>
[CmdletBinding()]
param(
    [string]$Time = '04:30',
    [string[]]$Days = @('Daily'),
    [string]$BetterGIPath = 'D:\BetterGI',
    [string]$TaskName = 'BetterGI-OneDragon',
    [int]$StartupDelaySeconds = 90,
    [string]$SkipIfRanToday = 'false',
    [string]$OneDragonConfigName = '',
    [string]$ApplyPowerTweaks = 'true',
    [string]$SleepAfterFinish = 'true',
    [string]$AcceptPrivacyDialog = 'true',
    [string]$StopOnBattery = 'true',
    [int]$SleepDelaySeconds = 60,
    [string]$PortalUrl = '',
    [string]$WifiSsid = '',
    [int]$MaxLatenessMinutes = 120,
    [switch]$RunNow,
    [switch]$RunDryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 自动提权
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '需要管理员权限，正在请求提权（请在弹出的 UAC 对话框点「是」）...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) {
            if ($v.IsPresent) { $argList += ('-' + $k) }
        } elseif ($v -is [array]) {
            $argList += ('-' + $k)
            $argList += ('"' + (($v -join ',')) + '"')
        } else {
            $argList += ('-' + $k)
            $argList += ('"' + [string]$v + '"')
        }
    }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
    } catch {
        Write-Host '提权被取消，安装未完成。请右键以管理员身份运行本脚本。' -ForegroundColor Red
        exit 1
    }
    exit 0
}

# 允许 -Days "Monday,Tuesday" 这种写法
$Days = @($Days | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$doPowerTweaks = -not ($ApplyPowerTweaks -match '^(false|0|no)$')
$doSkip = -not ($SkipIfRanToday -match '^(false|0|no)$')
$doSleep = -not ($SleepAfterFinish -match '^(false|0|no)$')
$doAgree = -not ($AcceptPrivacyDialog -match '^(false|0|no)$')
$doStopOnBattery = -not ($StopOnBattery -match '^(false|0|no)$')

Write-Host ''
Write-Host '==== BetterGI 一条龙 · 定时任务安装 ====' -ForegroundColor Cyan

# ---------------------------------------------------------------- 校验
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$worker = Join-Path $scriptDir 'Run-BetterGI-OneDragon.ps1'
if (-not (Test-Path $worker)) { Write-Host ('找不到 ' + $worker) -ForegroundColor Red; exit 1 }
$exe = Join-Path $BetterGIPath 'BetterGI.exe'
if (-not (Test-Path $exe)) { Write-Host ('找不到 ' + $exe + '，请用 -BetterGIPath 指定 BetterGI 安装目录。') -ForegroundColor Red; exit 1 }

$ts = [datetime]::MinValue
$parsed = $false
foreach ($fmt in @('HH:mm', 'H:mm')) {
    if ([datetime]::TryParseExact($Time, $fmt, $null, [System.Globalization.DateTimeStyles]::None, [ref]$ts)) { $parsed = $true; break }
}
if (-not $parsed) { Write-Host ('时间格式不对: ' + $Time + '，请用 24 小时制如 04:30') -ForegroundColor Red; exit 1 }
$timeStr = $ts.ToString('HH:mm')

# ---------------------------------------------------------------- 计划任务定义
$argStr = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -BetterGIPath "{1}" -StartupDelaySeconds {2}' -f $worker, $BetterGIPath, $StartupDelaySeconds
if ($doSkip) { $argStr += ' -SkipIfRanToday' }
if ($doSleep) { $argStr += (' -SleepAfterFinish -SleepDelaySeconds ' + $SleepDelaySeconds) }
if ($doAgree) { $argStr += ' -AcceptPrivacyDialog' }
try {
    $plannedHHmm = [datetime]::ParseExact($Time, 'HH:mm', $null).ToString('HH:mm')
} catch {
    $plannedHHmm = $Time
}
$argStr += (' -PlannedStartTime "' + $plannedHHmm + '" -MaxLatenessMinutes ' + $MaxLatenessMinutes)
if ($PortalUrl) { $argStr += (' -PortalUrl "' + $PortalUrl + '"' ) }
if ($WifiSsid) { $argStr += (' -WifiSsid "' + $WifiSsid + '"' ) }
if ($OneDragonConfigName) { $argStr += (' -OneDragonConfigName "' + $OneDragonConfigName + '"') }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argStr -WorkingDirectory $scriptDir

$allDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
$useDaily = $true
$dayList = @()
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

if ($useDaily) {
    $trigger = New-ScheduledTaskTrigger -Daily -At $timeStr
} else {
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $dayList -At $timeStr
}

# 只允许在接电源（交流电）时运行：用电池时不启动，中途拔电也会停止
# （笔记本上这是硬要求：电池供电跑一条龙既费电又可能中途断）
$settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable -MultipleInstances Parallel -ExecutionTimeLimit (New-TimeSpan -Hours 6)
$settings.DisallowStartIfOnBatteries = $true
$settings.StopIfGoingOnBatteries = $doStopOnBattery
$settings.WakeToRun = $true
$settings.StartWhenAvailable = $true
try { $settings.IdleSettings.StopOnIdleEnd = $false } catch { }

# 必须是「仅当用户登录时运行 + 最高权限」：
#   只有登录会话里才有桌面可以点；BetterGI 以管理员运行，UIA 也需要同等权限
$principalTask = New-ScheduledTaskPrincipal -UserId ($identity.Name) -LogonType Interactive -RunLevel Highest

$desc = '定时启动 BetterGI 并自动执行一条龙'
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principalTask -Description $desc -Force | Out-Null
Write-Host ('已创建计划任务: ' + $TaskName) -ForegroundColor Green

# ---------------------------------------------------------------- 电源设置
if ($doPowerTweaks) {
    Write-Host ''
    Write-Host '-- 电源设置：允许唤醒定时器 / 唤醒后不需密码 --' -ForegroundColor Cyan
    $jobs = @(
        @{ A = @("/setacvalueindex", "SCHEME_CURRENT", "SUB_SLEEP", "RTCWAKE", "1"); D = "接通电源：允许使用唤醒定时器" },
        @{ A = @("/setdcvalueindex", "SCHEME_CURRENT", "SUB_SLEEP", "RTCWAKE", "1"); D = "使用电池：允许使用唤醒定时器" }
    )
    foreach ($job in $jobs) {
        $pwArgs = $job.A
        $out = & powercfg @pwArgs 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Host ("  [OK]   " + $job.D) -ForegroundColor Green }
        else { Write-Host ("  [失败] " + $job.D + " : " + ($out -join " ")) -ForegroundColor Yellow }
    }

    # 「唤醒时需要密码」在部分新系统上已从电源方案里移除，先探测再决定是否可用 powercfg
    $clGroup = "fea3413e-7e05-4911-9a71-700331f1c294"
    $clSetting = "0e796bdb-100d-47d6-a2d5-f7d2daa51f51"
    $clQuery = & powercfg /query SCHEME_CURRENT $clGroup $clSetting 2>&1
    if (@($clQuery) -match "0e796bdb") {
        foreach ($job in @(
            @{ A = @("/setacvalueindex", "SCHEME_CURRENT", "SUB_NONE", "CONSOLELOCK", "0"); D = "接通电源：唤醒后不需要密码" },
            @{ A = @("/setdcvalueindex", "SCHEME_CURRENT", "SUB_NONE", "CONSOLELOCK", "0"); D = "使用电池：唤醒后不需要密码" }
        )) {
            $pwArgs = $job.A
            $out = & powercfg @pwArgs 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Host ("  [OK]   " + $job.D) -ForegroundColor Green }
            else { Write-Host ("  [失败] " + $job.D + " : " + ($out -join " ")) -ForegroundColor Yellow }
        }
    } else {
        Write-Host "  [需要手动] 本机电源方案里没有「唤醒时需要密码」这一项，请手动关闭：" -ForegroundColor Yellow
        Write-Host "     设置 → 账户 → 登录选项 → 如果你离开了，Windows 何时要求你重新登录 → 从不" -ForegroundColor Yellow
        Write-Host "     （不关的话，唤醒后会停在锁屏，鼠标点击全部失效）" -ForegroundColor Yellow
    }
    $null = & powercfg /setactive SCHEME_CURRENT 2>&1
}

# ---------------------------------------------------------------- 检查报告
Write-Host ''
Write-Host '-- 检查报告 --' -ForegroundColor Cyan

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host ('  任务状态     : ' + $task.State)
Write-Host ('  唤醒运行     : ' + $task.Settings.WakeToRun)
Write-Host ('  运行级别     : ' + $task.Principal.RunLevel)
Write-Host ('  仅接电源运行 : ' + $task.Settings.DisallowStartIfOnBatteries)
Write-Host ('  拔电即停止   : ' + $task.Settings.StopIfGoingOnBatteries + '   (可用 -StopOnBattery false 关闭)')
Write-Host ('  迟到容忍     : ' + $MaxLatenessMinutes + ' 分钟（超过就不补跑）')
Write-Host ('  登录类型     : ' + $task.Principal.LogonType)
Write-Host ('  下次运行时间 : ' + $info.NextRunTime)

Write-Host ''
Write-Host '  系统支持的睡眠状态：'
$sleepStates = & powercfg /a 2>&1
@($sleepStates) | Select-Object -First 8 | ForEach-Object { Write-Host ('    ' + $_) }

Write-Host ''
Write-Host '  当前可唤醒系统的设备：'
$wakeDev = & powercfg /devicequery wake_armed 2>&1
if ($wakeDev) { @($wakeDev) | ForEach-Object { Write-Host ('    ' + $_) } } else { Write-Host '    (无)' }

$fastStartup = $false
$hiberboot = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
if ($hiberboot -eq 1) { $fastStartup = $true }

$onedragonDir = Join-Path $BetterGIPath 'User\OneDragon'
if (Test-Path $onedragonDir) {
    foreach ($f in Get-ChildItem $onedragonDir -Filter '*.json' -File) {
        try {
            $json = Get-Content $f.FullName -Raw -Encoding UTF8
            if ($json -match '"CompletionAction"\s*:\s*"关机"') {
                Write-Host ''
                Write-Host ('  [重要] 一条龙配置「' + $f.BaseName + '」的「完成后」动作是【关机】') -ForegroundColor Yellow
                Write-Host '    关机后第二天的唤醒定时器不会生效（Windows 无法从 S5 关机唤醒）。' -ForegroundColor Yellow
                Write-Host '    BetterGI 的「完成后」没有【睡眠】选项，只有：无 / 关闭游戏 / 关闭软件 / 关闭游戏和软件 / 关机。' -ForegroundColor Yellow
                Write-Host '    建议改成【关闭游戏和软件】或【无】，睡眠交给本脚本（本任务已开启结束后自动睡眠）。' -ForegroundColor Yellow
            }
        } catch { }
    }
}

if ($fastStartup) {
    Write-Host ''
    Write-Host '  [提醒] 系统开启了「快速启动」，此时「关机」其实是半休眠，同样无法被定时唤醒。' -ForegroundColor Yellow
    Write-Host '    控制面板 → 电源选项 → 选择电源按钮的功能 → 取消「启用快速启动」。' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 立即试跑
if ($RunNow) {
    Write-Host ''
    Write-Host '-- 立即触发一次（请保持桌面已登录，便于观察）--' -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3
    Write-Host ('  已触发，运行日志在: ' + (Join-Path $scriptDir 'logs'))
}

Write-Host ''
# ---------------------------------------------------------------- 空跑验证
if ($RunDryRun) {
    Write-Host ""
    Write-Host "-- 空跑一次：切页面、定位开始按钮、截图，但不点击 --" -ForegroundColor Cyan
    $dryOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $worker -BetterGIPath $BetterGIPath -StartupDelaySeconds 0 -DryRun 2>&1
    @($dryOut) | ForEach-Object { Write-Host ("    " + $_) }
}

Write-Host '==== 安装完成 ====' -ForegroundColor Green
Write-Host ('脚本     : ' + $worker)
Write-Host ('运行日志 : ' + (Join-Path $scriptDir 'logs'))
Write-Host ('触发时间 : ' + $timeStr + '   ' + $(if ($useDaily) { '每天' } else { ($dayList -join ',') }))
Write-Host ''
Write-Host '改时间：带 -Time 参数重跑本脚本即可（覆盖同名任务）。' -ForegroundColor Gray
Write-Host '卸载  ：Uninstall-BetterGI-OneDragon-Task.ps1' -ForegroundColor Gray
Write-Host ''
