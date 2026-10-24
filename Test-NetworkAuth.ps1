# 夜巡 · 校园网自动认证「测试器」
#
# 用途：让你手动、可监督地跑一遍自动联网流程，并把每一步看到的都打印出来。
# 不需要管理员权限。
#
# 双击「测试网络认证.cmd」即可；也可以：
#   .\Test-NetworkAuth.ps1              # 菜单
#   .\Test-NetworkAuth.ps1 -Mode normal # 正常模式
#   .\Test-NetworkAuth.ps1 -Mode force  # 强制走完整流程
#   .\Test-NetworkAuth.ps1 -Mode dry    # 只算出点击位置，不点
[CmdletBinding()]
param(
    [ValidateSet('menu', 'normal', 'force', 'dry', 'status', 'rehearsal')]
    [string]$Mode = 'menu'
)

$ErrorActionPreference = 'Continue'

# 自动提权：凌晨的计划任务是管理员跑的，手动测试也要一样，
# 否则 Enable-NetAdapter / Disable-NetAdapter 这类操作会 Access denied。
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
        if ($PSBoundParameters.ContainsKey('Mode')) { $argList += @('-Mode', $Mode) }
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
        exit
    }
} catch { }
$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$portal = Join-Path $here 'Connect-CampusNetwork.ps1'

# 全程记录到日志文件：断网时 DSH 会话可能掉线，事后可以拿这份日志复盘
$logDir = Join-Path $here 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$testLog = Join-Path $logDir ('test-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.log')
try { Start-Transcript -Path $testLog -Force | Out-Null } catch { }

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host ('  ===== ' + $Text + ' =====') -ForegroundColor Cyan
}

function Test-Tcp {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 2000)
    $c = $null
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect($HostName, $Port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $c.EndConnect($ar); return $true }
        return $false
    } catch { return $false } finally { if ($c) { try { $c.Close() } catch { } } }
}

function Test-InternetHttps {
    # 用 curl 判"真能上网"：PowerShell 的 Invoke-WebRequest 在本机不可靠（IPv6/TLS 挂起）
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    foreach ($u in @('https://www.baidu.com', 'https://www.qq.com')) {
        try {
            $code = & $curl -s -o NUL -w '%{http_code}' --max-time 8 $u 2>$null
            $s = ($code | Out-String).Trim()
            if ($s -match '^[1-5][0-9][0-9]$') { return $true }
        } catch { }
    }
    return $false
}

function Show-State {
    Write-Head '当前网络状态'

    $ssid = ''
    try {
        $lines = & netsh wlan show interfaces 2>&1
        foreach ($ln in $lines) {
            if ($ln -match '^\s*SSID\s*:\s*(.+)$') { $ssid = $matches[1].Trim() }
        }
    } catch { }
    if (-not $ssid) { $ssid = '(未连接或无 WiFi)' }

    $ip = ''
    try {
        $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address }
        if ($cfg) { $ip = (($cfg | Select-Object -First 1).IPv4Address.IPAddress -join ',') }
    } catch { }
    if (-not $ip) { $ip = '(无)' }

    $inet = Test-InternetHttps
    $portalOk = Test-Tcp -HostName '202.117.144.205' -Port 8601 -TimeoutMs 2500
    $edge = @(Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })

    Write-Host ('  WiFi SSID    : ' + $ssid)
    Write-Host ('  本机 IP      : ' + $ip)
    Write-Host ('  外网连通     : ' + $(if ($inet) { '是 ✅' } else { '否 ❌（需要认证）' })) -ForegroundColor $(if ($inet) { 'Green' } else { 'Yellow' })
    Write-Host ('  校园门户可达 : ' + $(if ($portalOk) { '是' } else { '否' })) -ForegroundColor $(if ($portalOk) { 'Green' } else { 'Yellow' })
    Write-Host ('  Edge 进程    : ' + $(if ($edge.Count -gt 0) { '运行中（' + $edge.Count + ' 个窗口）' } else { '未运行' }))
    Write-Host ''
    Write-Host '  判定：' -ForegroundColor Gray
    if (-not $portalOk) {
        Write-Host '    门户不可达 —— 现在不在校园网里，测不了认证流程。' -ForegroundColor Yellow
        Write-Host '    （手机热点共享的情况下门户连不通，需要笔记本自己连校园网 SSID）' -ForegroundColor Yellow
    } elseif ($inet) {
        Write-Host '    门户可达且外网已通 —— 当前已认证，正常模式会直接跳过。' -ForegroundColor Yellow
        Write-Host '    想看它怎么操作，请选 2（强制）或 3（只算不点）。' -ForegroundColor Yellow
    } else {
        Write-Host '    门户可达但外网不通 —— 正是需要认证的状态，可以测。' -ForegroundColor Green
    }
    Write-Host ''
    return @{ Inet = $inet; Portal = $portalOk; Ssid = $ssid }
}

function Invoke-PortalTest {
    param([string[]]$ArgList)
    Write-Head '开始执行（下面每一行都是脚本的输出）'
    Write-Host ''
    # 注意：必须显式 Write-Host，否则子进程输出会当成函数返回值被调用方丢弃（踩过）
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $portal @ArgList | ForEach-Object { Write-Host ('  ' + $_) }
    $code = $LASTEXITCODE
    Write-Host ''
    Write-Head ('执行结束，退出码 = ' + $code)
    switch ($code) {
        0 { Write-Host '  ✅ 成功（或本来就通、已跳过）' -ForegroundColor Green }
        1 { Write-Host '  ❌ 失败：启动 Edge / 找不到窗口' -ForegroundColor Red }
        2 { Write-Host '  ⚠ Portal 显示已登录但外网仍不通' -ForegroundColor Yellow }
        3 { Write-Host '  ❌ 没识别出页面状态' -ForegroundColor Red }
        4 { Write-Host '  ❌ 账号/密码为空（浏览器没自动填充）' -ForegroundColor Red }
        5 { Write-Host '  ❌ 认证后外网仍不通' -ForegroundColor Red }
        6 { Write-Host '  ❌ 出现验证码，自动登录无法完成' -ForegroundColor Yellow }
        default { Write-Host ('  ? 未定义退出码 ' + $code) -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host ('  日志 / 截图目录: ' + (Join-Path $here 'logs')) -ForegroundColor Gray
    $shots = @(Get-ChildItem (Join-Path $here 'logs') -Filter 'net-*.png' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3)
    foreach ($s in $shots) { Write-Host ('    ' + $s.Name) -ForegroundColor Gray }
    return $code
}

# ---------------- 主流程 ----------------
while ($true) {
    if ($Mode -ne 'menu') { break }

    Clear-Host
    Write-Host ''
    Write-Host '    夜巡 · NightWatch' -ForegroundColor DarkGray
    Write-Host '    校园网自动认证 · 手动测试器' -ForegroundColor Cyan
    $st = Show-State

    Write-Host '  1 = 正常测试（外网不通时才认证，和凌晨自动运行时一致）'
    Write-Host '  2 = 强制测试（不管通不通，完整走一遍：开页面→点联通→点登录→点确认）'
    Write-Host '  3 = 强制 + 不动手（只算出要点的位置，绝不点击）'
    Write-Host '  4 = 只检查状态，什么都不做'
    Write-Host '  5 = 完整演练：先登出校园网，再自动认证回来（会短暂断网，最接近凌晨的真实场景）'
    Write-Host '  Q = 退出'
    Write-Host ''
    $c = (Read-Host '  请选择 (1/2/3/4/Q)').Trim()

    if ($c -eq '' -or $c -match '^[Qq]') { break }

    switch ($c) {
        '1' { [void](Invoke-PortalTest -ArgList @()) }
        '2' {
            if (-not $st.Portal) { Write-Host ''; Write-Host '  提示：门户现在不可达，强制跑也会失败在"打开页面"这一步。' -ForegroundColor Yellow }
            [void](Invoke-PortalTest -ArgList @('-Force'))
        }
        '3' { [void](Invoke-PortalTest -ArgList @('-Force', '-DryRun')) }
        '4' { Write-Host ''; Write-Host '  已看过状态，未做任何操作。' -ForegroundColor Gray }
        '5' {
            Write-Host ''
            Write-Host '  即将调用门户 logoff 登出（会短暂断网），然后自动认证回来...' -ForegroundColor Yellow
            Write-Host '  全程本地执行，断网不影响脚本本身。' -ForegroundColor Gray
            $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
            if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
            & $curl -s -o NUL --max-time 10 'http://202.117.144.205:8601/snnuportal/logoff' 2>&1 | Out-Null
            Start-Sleep -Seconds 5
            $after = (& $curl -s -o NUL -w '%{http_code}' --max-time 8 'https://www.baidu.com' 2>$null | Out-String).Trim()
            Write-Host ('  登出后 baidu HTTPS = ' + $after + '   （000/空 = 已断开，符合预期）') -ForegroundColor Gray
            [void](Invoke-PortalTest -ArgList @('-Force'))
        }
        default { Write-Host '  只能输入 1 / 2 / 3 / 4 / 5 / Q' -ForegroundColor Yellow }
    }
    Write-Host ''
    $null = Read-Host '  按回车回到菜单'
}

# 非菜单模式（带参数直接跑）
if ($Mode -ne 'menu') {
    $st = Show-State
    switch ($Mode) {
        'status' { }
        'normal' { [void](Invoke-PortalTest -ArgList @()) ; $null = Read-Host '  按回车退出' }
        'force' { [void](Invoke-PortalTest -ArgList @('-Force')) ; $null = Read-Host '  按回车退出' }
        'dry' { [void](Invoke-PortalTest -ArgList @('-Force', '-DryRun')) ; $null = Read-Host '  按回车退出' }
        'rehearsal' {
            $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
            & $curl -s -o NUL --max-time 10 'http://202.117.144.205:8601/snnuportal/logoff' 2>&1 | Out-Null
            Start-Sleep -Seconds 5
            [void](Invoke-PortalTest -ArgList @('-Force'))
            $null = Read-Host '  按回车退出'
        }
    }
}

# 收尾：关掉日志记录，并告诉用户日志在哪（断网后可以把这份发给 DSH 复盘）
Write-Host ''
Write-Host ('  本次完整日志: ' + $testLog) -ForegroundColor Cyan
Write-Host '  如果网络测试过程中 DSH 掉线，重新连上后把这份日志的内容发给它即可。' -ForegroundColor Gray
try { Stop-Transcript | Out-Null } catch { }
if ($Mode -eq 'menu') { Write-Host '' ; $null = Read-Host '  按回车关闭窗口' }
