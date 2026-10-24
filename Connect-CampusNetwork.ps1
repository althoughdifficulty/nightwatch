# 校园网 Portal 自动认证（陕西师范大学）
#
# 设计原则：
#   1) 先用 TCP 探测判断"到底能不能上网"。能上就直接跳过，什么都不动。
#   2) 需要认证时，打开 Portal 页 → 最大化窗口 → 检查账号密码是否已填 →
#      点「联通」→ 点「登录」→ 若弹出推广弹窗点「确认」→ 最后用 TCP 探测验收。
#   3) 点击优先走 UI Automation（按元素名找），找不到才退回"窗口比例坐标"。
#      比例坐标来自实测截图（2560×1599 最大化窗口），见下面的 $RATIO。
#   4) -DryRun 只算不点，并把点击位置画到截图上，便于人工复核。
[CmdletBinding()]
param(
    [string]$PortalUrl = 'http://202.117.144.205:8601/snnuportal/login.jsp',
    [string]$WifiSsid = 'SNNU',
    [int]$WifiConnectTimeoutSeconds = 90,
    [int]$LoadTimeoutSeconds = 30,
    [int]$VerifySeconds = 90,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$KeepBrowser,
    [switch]$CloseBrowserAll = $true,
    [string]$ShotDir = ''
)

$ErrorActionPreference = 'Continue'
$baseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $ShotDir) { $ShotDir = Join-Path $baseDir 'logs' }

# 实测比例（相对 Edge 最大化窗口）：联通单选框 / 登录按钮 / 确认按钮
# 基准：窗口最大化 2560x1599 时的实测像素
#   联通单选框 (1587, 778) / 登录按钮 (1690, 915) / 确认按钮 (1377, 1337)
$RATIO = @{
    联通 = @(0.6199, 0.4866)
    登录 = @(0.6602, 0.5722)
    确认 = @(0.5379, 0.8361)
    断开 = @(0.4891, 0.6129)
}

function Get-CurrentSsid {
    # 必须解析 SSID 本身。注意：不能用 Get-NetConnectionProfile.Name —— 那是"网络配置文件名称"，
    # 可能叫 "SNNU 3" 之类，和真实 SSID 不一致（踩过，会误判成"没连上"）。
    # netsh 的中文输出是 UTF-8，而 PowerShell 5.1 默认按 GBK 解码 → 乱码，所以这里临时切 UTF-8。
    $oldEnc = $null
    $out = @()
    try {
        $oldEnc = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $out = & netsh wlan show interfaces 2>&1
    } catch { } finally {
        if ($oldEnc) { try { [Console]::OutputEncoding = $oldEnc } catch { } }
    }
    foreach ($ln in @($out)) {
        $s = [string]$ln
        if ($s -match '^\s*SSID\s*:\s*(.+?)\s*$') { return $matches[1].Trim() }
    }
    return ''
}

function Ensure-WifiConnected {
    # 前提：没连上校园网时，认证页面根本打不开（用户实测确认）
    # 三种"连不上"的原因要分别处理：
    #   1) 网卡被禁用        -> Enable-NetAdapter
    #   2) 无线电被关(WLAN开关) -> 重启网卡（实测有效，但恢复要 30~60 秒）
    #   3) 连的是别的网        -> netsh wlan connect
    param([string]$Ssid, [int]$TimeoutSec = 90)

    $ad = $null
    try {
        $ad = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'WLAN' -or $_.InterfaceDescription -match 'Wireless|Wi-?Fi|无线' } | Select-Object -First 1
    } catch { }

    $cur = Get-CurrentSsid
    if ($cur -eq $Ssid) { Log ('WiFi 已连接: ' + $Ssid); return $true }

    # ---- 情况 1：网卡被禁用
    if ($ad -and $ad.AdminStatus -eq 'Disabled') {
        Log ('WLAN 网卡被禁用，启用中: ' + $ad.Name) 'WRN'
        try { Enable-NetAdapter -Name $ad.Name -Confirm:$false -ErrorAction Stop; Start-Sleep -Seconds 8 } catch { Log ('启用网卡失败: ' + $_.Exception.Message) 'WRN' }
    }

    # ---- 情况 2：无线电被关（设置里的 WLAN 开关）
    $cur = Get-CurrentSsid
    if (-not $cur -and $ad) {
        # 先试 WLAN API 直接打开 radio
        $radioOk = $false
        try {
            $rc = [NetUI]::SetWlanRadioOn([Guid]$ad.InterfaceGuid)
            if ($rc -eq 0) { $radioOk = $true; Log '已通过 WLAN API 打开无线电' }
            else { Log ('WlanSetInterface 返回 0x{0:X}' -f $rc) 'WRN' }
        } catch { Log ('调用 WLAN API 失败: ' + $_.Exception.Message) 'WRN' }

        if (-not $radioOk) {
            Log '尝试重启 WLAN 网卡（实测能让无线电恢复，约需 30~60 秒）' 'WRN'
            try {
                Disable-NetAdapter -Name $ad.Name -Confirm:$false -ErrorAction Stop
                Start-Sleep -Seconds 4
                Enable-NetAdapter -Name $ad.Name -Confirm:$false -ErrorAction Stop
                Log '网卡已重启，等待无线电和自动连接就绪...'
                Start-Sleep -Seconds 15
            } catch { Log ('重启网卡失败: ' + $_.Exception.Message) 'WRN' }
        }
        $cur = Get-CurrentSsid
        if ($cur -eq $Ssid) { Log ('WiFi 已连接: ' + $Ssid + ' ✅'); return $true }
    }

    # ---- 情况 3：还没连到目标 SSID -> netsh 连接（可重试）
    if (-not $cur) { }
    $profiles = (& netsh wlan show profiles 2>&1) -join "`n"
    if ($profiles -notmatch [regex]::Escape($Ssid)) {
        Log ("系统里没有 '" + $Ssid + "' 的无线配置文件，无法自动连接。请先在设置里手动连一次。") "ERR"
        return $false
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $attempt = 0
    while ((Get-Date) -lt $deadline) {
        $cur = Get-CurrentSsid
        if ($cur -eq $Ssid) { Log ('WiFi 已连接: ' + $Ssid + ' ✅'); return $true }

        # 每 20 秒发起一次连接请求（重启网卡后要给它时间）
        if (($attempt % 20) -eq 0) {
            Log ('执行 netsh wlan connect name=' + $Ssid)
            $oldEnc = $null
            try {
                $oldEnc = [Console]::OutputEncoding
                [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                $r = & netsh wlan connect name="$Ssid" 2>&1
            } catch { $r = @() } finally {
                if ($oldEnc) { try { [Console]::OutputEncoding = $oldEnc } catch { } }
            }
            foreach ($ln in @($r)) { if ("$ln".Trim()) { Log ('  [netsh] ' + $ln) } }
        }
        Start-Sleep -Seconds 2
        $attempt += 2
    }
    Log ("等了 " + $TimeoutSec + " 秒仍未连上 '" + $Ssid + "'（当前: '" + (Get-CurrentSsid) + "'）") "ERR"
    return $false
}

function Log {
    param([string]$m, [string]$lv = 'INF')
    Write-Host ('[{0}] [{1}] {2}' -f (Get-Date).ToString('HH:mm:ss.fff'), $lv, $m)
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$ns = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class NetUI
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    // Windows 11 设置里的"WLAN 开关"关的是无线电(radio)，不是网卡，Enable-NetAdapter 无效
    [DllImport("wlanapi.dll")] public static extern int WlanOpenHandle(uint dwClientVersion, IntPtr pReserved, out uint pdwNegotiatedVersion, out IntPtr phClientHandle);
    [DllImport("wlanapi.dll")] public static extern int WlanCloseHandle(IntPtr hClientHandle, IntPtr pReserved);
    [DllImport("wlanapi.dll")] public static extern int WlanSetInterface(IntPtr hClientHandle, ref Guid pInterfaceGuid, uint OpCode, uint dwDataSize, IntPtr pData, IntPtr pReserved);

    public static int SetWlanRadioOn(Guid intfGuid) {
        // 关键：pData 要传 12 字节的 WLAN_PHY_RADIO_STATE（传 772 字节的 WLAN_RADIO_STATE 会返回 0x57）
        IntPtr h = IntPtr.Zero;
        uint ver = 0;
        int rc = WlanOpenHandle(2, IntPtr.Zero, out ver, out h);
        if (rc != 0) return rc;
        try {
            int size = 12;
            IntPtr p = Marshal.AllocHGlobal(size);
            try {
                for (int i = 0; i < size; i++) Marshal.WriteByte(p, i, 0);
                Marshal.WriteInt32(p, 0, 0);   // dwPhyIndex
                Marshal.WriteInt32(p, 4, 1);   // dot11SoftwareRadioState = ON
                Marshal.WriteInt32(p, 8, 1);   // dot11HardwareRadioState = ON
                return WlanSetInterface(h, ref intfGuid, 4u, (uint)size, p, IntPtr.Zero);
            } finally { Marshal.FreeHGlobal(p); }
        } finally { WlanCloseHandle(h, IntPtr.Zero); }
    }
}
'@
if (-not ('NetUI' -as [type])) { Add-Type -TypeDefinition $ns -Language CSharp }
try { [void][NetUI]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { try { [void][NetUI]::SetProcessDPIAware() } catch { } }

$MOUSEDOWN = 0x0002
$MOUSEUP = 0x0004

function Test-Internet {
    # 只认 HTTPS 且用 curl.exe：PowerShell 的 Invoke-WebRequest 在这台机器上不可靠
    # （.NET 栈会先试 IPv6 然后长时间挂住，连强设 TLS1.2 都救不回来；curl 0.4 秒就 200）
    # 校园网关常见"放行 HTTP、劫持 HTTPS"，所以 HTTP 能通不算数
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

function Get-EdgeWindows {
    $script:ew = @()
    $script:epids = @(Get-Process msedge -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if ($script:epids.Count -eq 0) { return @() }
    $cb = [NetUI+EnumProc] {
        param($h, $l)
        try {
            $p = [uint32]0
            [void][NetUI]::GetWindowThreadProcessId($h, [ref]$p)
            if ($script:epids -contains [int]$p -and [NetUI]::IsWindowVisible($h)) {
                $sb = New-Object System.Text.StringBuilder 512
                [void][NetUI]::GetWindowText($h, $sb, 512)
                $r = New-Object NetUI+RECT
                [void][NetUI]::GetWindowRect($h, [ref]$r)
                $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
                if ($sb.Length -gt 0 -and $w -gt 300 -and $hh -gt 200) {
                    $script:ew += , @{ H = $h; T = $sb.ToString(); X = $r.Left; Y = $r.Top; W = $w; Hh = $hh }
                }
            }
        } catch { }
        return $true
    }
    [void][NetUI]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:ew
}

function Save-Shot {
    param([string]$Name)
    try {
        if (-not (Test-Path $ShotDir)) { New-Item -ItemType Directory -Path $ShotDir -Force | Out-Null }
        $path = Join-Path $ShotDir ('net-' + $Name + '-' + (Get-Date).ToString('HHmmss') + '.png')
        $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
        $g.Dispose(); $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        Log ('截图已保存: ' + $path)
        return $path
    } catch { Log ('截图失败: ' + $_.Exception.Message) 'WRN'; return $null }
}

function Get-All {
    param($Root)
    return $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
}

function Find-ByName {
    param($Root, [string[]]$Patterns, [string[]]$Types = @())
    foreach ($e in (Get-All -Root $Root)) {
        try { $c = $e.Current } catch { continue }
        if ($c.IsOffscreen) { continue }
        $ct = $c.ControlType.ProgrammaticName.Replace('ControlType.', '')
        if ($Types.Count -gt 0 -and ($Types -notcontains $ct)) { continue }
        foreach ($p in $Patterns) {
            if ($c.Name -and $c.Name -match $p) { return $e }
        }
    }
    return $null
}

function Find-ElementRect {
    # 按控件类型 + 名字正则找元素，返回中心点。
    # 注意：Chromium 常把页面上可见的控件标成 IsOffscreen=True（实测「联通」单选框就是这样），
    # 所以这里不能用 IsOffscreen 过滤，只能用「矩形是否有效」判定。
    param($Root, [string]$Type, [string]$Pattern, [int]$MinY = 300)
    foreach ($e in (Get-All -Root $Root)) {
        try {
            $c = $e.Current
            if ($c.ControlType.ProgrammaticName -ne ('ControlType.' + $Type)) { continue }
            $r = $c.BoundingRectangle
            if ($r.Width -lt 8 -or $r.Height -lt 8) { continue }
            if ($r.Y -lt $MinY) { continue }
            if ($Pattern -and ($c.Name -notmatch $Pattern)) { continue }
            return @{ Has = $true; E = $e; L = [int]$r.X; X = [int]($r.X + $r.Width / 2); Y = [int]($r.Y + $r.Height / 2); W = [int]$r.Width; H = [int]$r.Height; N = [string]$c.Name }
        } catch { }
    }
    return @{ Has = $false }
}

function Find-LoginButtonRect {
    # 登录按钮是 <input type=image>，UIA 里呈现为 Hyperlink/Image 且没有名字。
    # 取「在指定 Y 之下、尺寸最大」的候选（实测是 230x65 的 Hyperlink）。
    param($Root, [int]$BelowY = 780)
    $best = $null; $area = 0
    foreach ($e in (Get-All -Root $Root)) {
        try {
            $c = $e.Current
            $tn = $c.ControlType.ProgrammaticName
            if ($tn -ne 'ControlType.Hyperlink' -and $tn -ne 'ControlType.Image' -and $tn -ne 'ControlType.Button') { continue }
            $r = $c.BoundingRectangle
            if ($r.Width -lt 120 -or $r.Width -gt 420) { continue }
            if ($r.Height -lt 40 -or $r.Height -gt 110) { continue }
            if ($r.Y -lt $BelowY) { continue }
            $a = $r.Width * $r.Height
            if ($a -gt $area) { $area = $a; $best = @{ Has = $true; L = [int]$r.X; X = [int]($r.X + $r.Width / 2); Y = [int]($r.Y + $r.Height / 2); W = [int]$r.Width; H = [int]$r.Height; N = [string]$c.Name } }
        } catch { }
    }
    if ($best) { return $best }
    return @{ Has = $false }
}

function Invoke-SafeClick {
    param([int]$X, [int]$Y, [string]$What)
    if ($DryRun) {
        Log ('[DryRun] 将点击 ' + $What + ' @ (' + $X + ',' + $Y + ')')
        return $true
    }
    Log ('点击 ' + $What + ' @ (' + $X + ',' + $Y + ')')
    [void][NetUI]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 120
    [NetUI]::mouse_event($MOUSEDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 70
    [NetUI]::mouse_event($MOUSEUP, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 350
    return $true
}

function Get-AddressBarValue {
    param($Root)
    $bar = Find-ByName -Root $Root -Patterns @('地址和搜索栏') -Types @('Edit')
    if (-not $bar) { return '' }
    try { return $bar.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { return '' }
}

function Navigate-Edge {
    param($Root, [string]$Url)
    $bar = Find-ByName -Root $Root -Patterns @('地址和搜索栏') -Types @('Edit')
    if (-not $bar) { Log '找不到 Edge 地址栏，无法主动导航' 'WRN'; return $false }
    try {
        $bar.SetFocus()
        Start-Sleep -Milliseconds 250
        $bar.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Url)
        Start-Sleep -Milliseconds 300
        [NetUI]::keybd_event(0x0D, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 100
        [NetUI]::keybd_event(0x0D, 0, 2, [UIntPtr]::Zero)
        Log ('已在地址栏输入并回车: ' + $Url)
        return $true
    } catch { Log ('地址栏导航失败: ' + $_.Exception.Message) 'WRN'; return $false }
}

function Close-OneTab {
    # 给当前前台窗口发一次 Ctrl+W（关掉一个标签）
    param([IntPtr]$Handle)
    [void](Set-EdgeForeground -H $Handle)
    Start-Sleep -Milliseconds 400
    [NetUI]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    [NetUI]::keybd_event(0x57, 0, 0, [UIntPtr]::Zero)
    [NetUI]::keybd_event(0x57, 0, 2, [UIntPtr]::Zero)
    [NetUI]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 700
}

function Close-BrowserAfterAuth {
    param($Win, $Root)
    if ($DryRun) { Log '-DryRun 模式下不关闭浏览器'; return }
    if ($KeepBrowser) { Log '按 -KeepBrowser 保留浏览器'; return }
    if (-not $Win) { return }

    try {
        Close-OneTab -Handle $Win.H
        Log '已关闭 Portal 标签'
    } catch { Log ('关闭 Portal 标签失败: ' + $_.Exception.Message) 'WRN' }

    # Edge 的 UIA 只暴露"当前激活"的标签，按名字找后台标签行不通，
    # 所以用窗口标题判断：如果关完门户后剩下的是 Windows 的网络探测页，把那个标签也关掉。
    Start-Sleep -Milliseconds 800
    $still = @(Get-EdgeWindows) | Where-Object { $_.H -eq $Win.H } | Select-Object -First 1
    if ($still -and ($still.T -match 'msftconnecttest|msftncsi|你似乎未连接|尚未连接|Internet')) {
        try {
            Close-OneTab -Handle $Win.H
            Log ('已关闭网络探测页: ' + $still.T)
        } catch { }
    }

    if ($CloseBrowserAll) {
        Start-Sleep -Milliseconds 500
        $n = 0
        foreach ($proc in @(Get-Process msedge -ErrorAction SilentlyContinue)) {
            try { $proc.Kill(); $n++ } catch { }
        }
        if ($n -gt 0) { Log ('已关闭 Edge 浏览器（' + $n + ' 个进程）') }
        else { Log 'Edge 已经不在运行' }
    }
}

function Set-EdgeForeground {
    param([IntPtr]$H)
    # 先按两下 ESC：定时唤醒后桌面上可能残留开始菜单/搜索面板，会挡住点击
    for ($e = 0; $e -lt 2; $e++) {
        try {
            [NetUI]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
            [NetUI]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 120
        } catch { }
    }
    try { [void][NetUI]::ShowWindow($H, 9) } catch { }
    Start-Sleep -Milliseconds 200
    try { [void][NetUI]::SetForegroundWindow($H) } catch { }
    Start-Sleep -Milliseconds 200
    if ([NetUI]::GetForegroundWindow() -eq $H) { return $true }
    try {
        $fg = [NetUI]::GetForegroundWindow(); $fp = [uint32]0
        $ft = [NetUI]::GetWindowThreadProcessId($fg, [ref]$fp)
        $ct = [NetUI]::GetCurrentThreadId()
        [void][NetUI]::AttachThreadInput($ct, $ft, $true)
        [void][NetUI]::BringWindowToTop($H)
        [void][NetUI]::SetForegroundWindow($H)
        [void][NetUI]::AttachThreadInput($ct, $ft, $false)
    } catch { }
    for ($i = 0; $i -lt 12; $i++) {
        if ([NetUI]::GetForegroundWindow() -eq $H) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

# ------------------------------------------------------------------ 主流程
Log '===== 校园网认证开始 ====='

# 第一步永远是：确认连在校园网上（否则认证页打不开）
$wifiOk = Ensure-WifiConnected -Ssid $WifiSsid -TimeoutSec $WifiConnectTimeoutSeconds
if (-not $wifiOk) {
    Log 'WiFi 未就绪，认证页很可能打不开，本次放弃。' 'ERR'
    exit 7
}

if (-not $Force) {
    if (Test-Internet) { Log '网络已能上网，不需要认证，直接跳过。'; exit 0 }
    Log '探测不到外网，准备走 Portal 认证。'
} else {
    Log 'Force 模式：跳过"是否已联网"的判断。'
}

# ---------------- 获取可用的 Edge 窗口（含 UIA 根）----------------
function Get-EdgeRoot {
    param($Win)
    try {
        $r = [System.Windows.Automation.AutomationElement]::FromHandle($Win.H)
        if (-not $r) { return $null }
        return $r
    } catch { return $null }
}

function Find-PortalWindow {
    # 只认"真窗口"：必须能读到地址栏，避免抓到启动瞬间的临时窗口
    foreach ($w in @(Get-EdgeWindows)) {
        $r = Get-EdgeRoot -Win $w
        if (-not $r) { continue }
        if (-not (Find-ByName -Root $r -Patterns @('地址和搜索栏') -Types @('Edit'))) { continue }
        $tab = Find-ByName -Root $r -Patterns @('陕西师范大学|网络Portal|snnuportal') -Types @('TabItem')
        if ($tab) { return @{ Win = $w; Root = $r; Tab = $tab } }
    }
    return $null
}

function Find-AnyEdgeWindow {
    foreach ($w in @(Get-EdgeWindows)) {
        $r = Get-EdgeRoot -Win $w
        if (-not $r) { continue }
        if (Find-ByName -Root $r -Patterns @('地址和搜索栏') -Types @('Edit')) { return @{ Win = $w; Root = $r; Tab = $null } }
    }
    return $null
}

$found = Find-PortalWindow
if ($found) {
    if ($found.Tab) {
        try { $found.Tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() } catch { }
    }
    Log ('复用已打开的 Portal 标签: ' + $found.Win.T)
} else {
    try {
        Start-Process 'msedge.exe' -ArgumentList $PortalUrl
        Log '已新开 Portal 标签，等待窗口出现...'
    } catch {
        Log ('启动 Edge 失败: ' + $_.Exception.Message) 'ERR'; exit 1
    }
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not $found) {
        Start-Sleep -Milliseconds 900
        $found = Find-PortalWindow
    }
    if (-not $found) {
        Log '没等到 Portal 标签，退而找一个可用的 Edge 窗口。' 'WRN'
        $found = Find-AnyEdgeWindow
    }
}

if (-not $found) { Log '找不到可用的 Edge 窗口（启动失败或被拦截）' 'ERR'; exit 1 }

# 关键：不管窗口是怎么来的，都要把"门户标签"切到激活状态（否则可能停在 about:blank）
if ($found.Tab) {
    try {
        $found.Tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Log '已激活 Portal 标签'
        Start-Sleep -Milliseconds 600
    } catch { Log ('激活 Portal 标签失败: ' + $_.Exception.Message) 'WRN' }
}
$win = $found.Win
Log ('Edge 窗口: hwnd=' + $win.H + ' "' + $win.T + '" ' + $win.W + 'x' + $win.Hh)

# 最大化（DryRun 也要最大化，否则比例坐标对不上）
[void][NetUI]::ShowWindow($win.H, 3)
Start-Sleep -Seconds 2
$after = @(Get-EdgeWindows) | Where-Object { $_.H -eq $win.H } | Select-Object -First 1
if ($after) { $win = $after; Log ('最大化后: ' + $win.X + ',' + $win.Y + ' ' + $win.W + 'x' + $win.Hh) }

# 比例坐标只在"窗口最大化"时成立：页面是固定宽度布局，窗口一变，按比例算出来的点就会偏。
# 所以这里强制校验：窗口宽度必须接近屏幕宽度，否则再最大化一次，仍不行就放弃（宁可不点，也不能点错）。
$screenW = 0
try { $screenW = [NetUI]::GetSystemMetrics(0) } catch { }
if ($screenW -gt 0) {
    $needW = [int]($screenW * 0.95)
    for ($mz = 1; $mz -le 2; $mz++) {
        if ($win.W -ge $needW) { break }
        Log ("窗口宽度 " + $win.W + " < 屏幕 " + $screenW + "，第 " + $mz + " 次重新最大化") 'WRN'
        [void][NetUI]::ShowWindow($win.H, 3)
        Start-Sleep -Seconds 2
        $again = @(Get-EdgeWindows) | Where-Object { $_.H -eq $win.H } | Select-Object -First 1
        if ($again) { $win = $again }
    }
    if ($win.W -lt $needW) {
        Log ("窗口无法最大化（当前宽 " + $win.W + "，屏幕 " + $screenW + "），比例坐标会失准，放弃本次认证。") 'ERR'
        Save-Shot -Name 'not-maximized' | Out-Null
        exit 8
    }
    Log ("窗口尺寸校验通过: " + $win.W + "x" + $win.Hh + "（屏幕 " + $screenW + "）")
}

$ok = Set-EdgeForeground -H $win.H
if (-not $ok) { Log '警告：没能把 Edge 切到前台，点击可能落空。' 'WRN' }
Start-Sleep -Milliseconds 600

# 最大化/激活后重新取一次根元素，取不到就重试
$root = $null
for ($i = 0; $i -lt 10; $i++) {
    $root = Get-EdgeRoot -Win $win
    if ($root) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $root) { Log '拿到了窗口句柄，但读不到 UI Automation 根元素' 'ERR'; exit 1 }

# 校验地址栏：如果当前页不是门户（常见：停在 about:blank），主动导航过去
$urlNow = Get-AddressBarValue -Root $root
if ($urlNow -notmatch 'snnuportal') {
    Log ('当前页面不是门户（地址栏: "' + $urlNow + '"），主动导航') 'WRN'
    [void](Navigate-Edge -Root $root -Url $PortalUrl)
    Start-Sleep -Seconds 5
} else {
    Log ('地址栏确认: ' + $urlNow)
}

function Get-PageState {
    param($Root, [int]$WaitSeconds = 0)
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ($true) {
        if (Find-ByName -Root $Root -Patterns @('当前登录账号|断开连接|在线状态')) { return 'loggedin' }
        if (Find-ByName -Root $Root -Patterns @('账\s*号|代\s*拨|登\s*录')) { return 'loginform' }
        if ((Get-Date) -ge $deadline) { return 'unknown' }
        Start-Sleep -Milliseconds 800
    }
}

# 等页面：识别"已登录"或"登录表单"
$state = Get-PageState -Root $root -WaitSeconds $LoadTimeoutSeconds
Log ('页面状态: ' + $state)

if ($state -eq 'loggedin') {
    if (Test-Internet) {
        Log '页面显示已登录，且外网已通 ✅'
        Close-BrowserAfterAuth -Win $win -Root $root 
        exit 0
    }
    # 页面说已登录但外网不通：会话是失效的（换 IP/超时都会这样），必须先断开再重新登录
    Log '页面显示已登录，但外网不通（会话已失效）→ 先断开再重新登录' 'WRN'
    $dx = [int]($win.X + $win.W * $RATIO['断开'][0])
    $dy = [int]($win.Y + $win.Hh * $RATIO['断开'][1])
    [void](Invoke-SafeClick -X $dx -Y $dy -What '断开连接(坐标)')
    Start-Sleep -Seconds 5
    [void](Navigate-Edge -Root $root -Url $PortalUrl)
    Start-Sleep -Seconds 5
    $state = Get-PageState -Root $root -WaitSeconds 20
    Log ('断开后的页面状态: ' + $state)
    if ($state -eq 'loggedin') {
        Log '断开后仍显示已登录，无法继续自动处理。' 'ERR'
        Save-Shot -Name 'still-loggedin' | Out-Null
        exit 2
    }
}

if ($state -eq 'unknown') {
    Log '第一次没识别出页面，重新导航后再等 15 秒。' 'WRN'
    [void](Navigate-Edge -Root $root -Url $PortalUrl)
    Start-Sleep -Seconds 5
    $deadline2 = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline2) {
        Start-Sleep -Milliseconds 800
        if (Find-ByName -Root $root -Patterns @('当前登录账号|断开连接|在线状态')) { $state = 'loggedin'; break }
        if (Find-ByName -Root $root -Patterns @('账\s*号|代\s*拨|登\s*录')) { $state = 'loginform'; break }
    }
    Log ('重试后页面状态: ' + $state)
}

if ($state -eq 'unknown') {
    Log '仍然没有识别出页面状态（加载慢、结构变化或网络异常）。' 'ERR'
    Save-Shot -Name 'unknown-state' | Out-Null
    exit 3
}

# 验证码是偶发的：遇到先刷新页面重试（通常和过期会话绑定，刷新即消失），连试几次仍有才放弃
$captchaTry = 0
while ($true) {
    # 只认页面上的「验证码」元素本身。
    # 教训（10-20 22:24）：原来按「编辑框数量>=3」判断，该页实际有 4 个 Edit 但屏幕上没有验证码，
    # 结果白刷新两次后放弃登录，把一次正常认证挡在门外。
    $captchaEl = Find-ByName -Root $root -Patterns @('验\s*证\s*码')
    $needCaptcha = [bool]$captchaEl
    $editCount = 0
    foreach ($e0 in (Get-All -Root $root)) {
        try { $c0 = $e0.Current } catch { continue }
        $isChrome = ($c0.Name -match '地址和搜索栏|搜索框|Address|Search')
        if (-not $isChrome -and $c0.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and -not $c0.IsOffscreen -and $c0.BoundingRectangle.Y -gt 250 -and $c0.BoundingRectangle.Width -gt 50) { $editCount++ }
    }
    Log ('  编辑框: ' + $editCount + ' 个；验证码元素: ' + $(if ($needCaptcha) { '有' } else { '无' }))
    if (-not $needCaptcha) { break }
    $captchaTry++
    if ($captchaTry -gt 2) {
        Log '刷新 2 次后仍有验证码，放弃自动登录（需要人工识别）。' 'ERR'
        Save-Shot -Name 'captcha-required' | Out-Null
        exit 6
    }
    Log ('检测到验证码，刷新页面重试（第 ' + $captchaTry + ' 次）') 'WRN'
    $refresh = Find-ByName -Root $root -Patterns @('^刷\s*新$') -Types @('Button')
    if ($refresh) {
        try { $refresh.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } catch { }
    } else {
        try { Start-Process 'msedge.exe' -ArgumentList $PortalUrl } catch { }
    }
    Start-Sleep -Seconds 5
}

# 检查账号/密码是否已填（记住密码）
$edits = @()
foreach ($e in (Get-All -Root $root)) {
    try { $c = $e.Current } catch { continue }
    if ($c.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and -not $c.IsOffscreen) {
        $r = $c.BoundingRectangle
          # 排除浏览器自己的输入框（地址栏/搜索框），否则会被当成"账号已填"，让空账号检查永远不触发
          $isBrowserChrome = ($c.Name -match '地址和搜索栏|搜索框|Address|Search')
          if (-not $isBrowserChrome -and $r.Y -gt 250 -and $r.Width -gt 50) { $edits += @{ E = $e; Name = $c.Name; Y = $r.Y; X = $r.X } }
    }
}
$filled = 0
foreach ($ed in ($edits | Sort-Object { $_.Y })) {
    $v = ''
    try {
        $vp = $ed.E.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        $v = $vp.Current.Value
    } catch { }
    Log ('  输入框 "' + $ed.Name + '" 值长度=' + $v.Length)
    if ($v.Length -gt 0) { $filled++ }
}
if ($edits.Count -ge 2 -and $filled -eq 0) {
    Log '账号和密码都是空的（浏览器没有自动填充）。' 'ERR'
    Log '请手动登录一次并勾选「记住密码」，之后脚本才能自动完成。' 'ERR'
    Save-Shot -Name 'empty-credentials' | Out-Null
    exit 4
}

# 计算三个点击点
function Get-RatioPoint {
    param($Win, [double[]]$Ratio)
    return @([int]($Win.X + $Win.W * $Ratio[0]), [int]($Win.Y + $Win.Hh * $Ratio[1]))
}
$pRadio = Get-RatioPoint -Win $win -Ratio $RATIO['联通']
$pLogin = Get-RatioPoint -Win $win -Ratio $RATIO['登录']
$pOk = Get-RatioPoint -Win $win -Ratio $RATIO['确认']
Log ('比例坐标: 联通=(' + $pRadio -join ',' + ') 登录=(' + $pLogin -join ',' + ') 确认=(' + $pOk -join ',' + ')')

# 点击前先截一张图，万一坐标偏了可以回溯
if (-not $DryRun) { $null = Save-Shot -Name 'before-click' }

# 1) 联通
# 0) 先关掉 Edge 的「保存的密码」下拉：它会盖住单选框右侧和登录按钮
#    （实测会压住「联通」的第二个字、「移动」，以及登录按钮右半部分）
try {
    for ($ek = 0; $ek -lt 2; $ek++) {
        [NetUI]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
        [NetUI]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 250
    }
    Log '已按 ESC 关闭可能的自动填充下拉'
} catch { }

# 1) 联通：优先按元素定位（不受页面整体位移影响）
$rEl = Find-ElementRect -Root $root -Type 'RadioButton' -Pattern '联\s*通' -MinY 300
if ($rEl.Has) {
    Log ('按元素定位「联通」: ' + $rEl.X + ',' + $rEl.Y + ' （' + $rEl.W + 'x' + $rEl.H + '）')
    # 点「圆圈」那一侧（左缘 +12px），而不是正中：密码下拉出现时会盖住右侧文字
    [void](Invoke-SafeClick -X ($rEl.L + 12) -Y $rEl.Y -What '联通(圆圈)')
    Start-Sleep -Milliseconds 400
    $isSel = $false
    try { $isSel = $rEl.E.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } catch { }
    if (-not $isSel) {
        Log '「联通」点圆圈后未选中，改点中心重试' 'WRN'
        [void](Invoke-SafeClick -X $rEl.X -Y $rEl.Y -What '联通(中心)')
        Start-Sleep -Milliseconds 300
        try { $isSel = $rEl.E.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } catch { }
    }
    if ($isSel) { Log '「联通」已选中 ✅' } else { Log '「联通」仍未选中（继续，最后验收会兜底）' 'WRN' }
} else {
    $rb = Find-ByName -Root $root -Patterns @('联\s*通') -Types @('RadioButton')
    if ($rb) {
        try {
            $tp = $rb.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            $tp.Select()
            Log '已通过 UIA 选中「联通」单选框'
        } catch { Log ('UIA 选中失败，改用坐标点击: ' + $_.Exception.Message) 'WRN'; [void](Invoke-SafeClick -X $pRadio[0] -Y $pRadio[1] -What '联通(坐标)') }
    } else {
        Log 'UIA 找不到「联通」单选框，用比例坐标点击。'
        [void](Invoke-SafeClick -X $pRadio[0] -Y $pRadio[1] -What '联通(坐标)')
    }
}

# 2) 登录：优先按元素定位
$bEl = Find-LoginButtonRect -Root $root -BelowY 780
if ($bEl.Has) {
    Log ('按元素定位「登录」: ' + $bEl.X + ',' + $bEl.Y + ' （' + $bEl.W + 'x' + $bEl.H + '）')
    # 同样点左侧（+20px），避开可能覆盖的密码下拉
    [void](Invoke-SafeClick -X ($bEl.L + 20) -Y $bEl.Y -What '登录(元素左侧)')
} else {
    $btn = Find-ByName -Root $root -Patterns @('^登\s*录$|登\s*录') -Types @('Button')
    if ($btn) {
        try {
            $ip = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            $ip.Invoke()
            Log '已通过 UIA 点击「登录」'
        } catch { Log 'UIA 点击登录失败，改坐标。' 'WRN'; [void](Invoke-SafeClick -X $pLogin[0] -Y $pLogin[1] -What '登录(坐标)') }
    } else {
        Log 'UIA 找不到「登录」按钮，用比例坐标点击。'
        [void](Invoke-SafeClick -X $pLogin[0] -Y $pLogin[1] -What '登录(坐标)')
    }
}

Start-Sleep -Seconds 3

# 3) 推广弹窗的「确认」
$okBtn = Find-ByName -Root $root -Patterns @('^确\s*认$') -Types @('Button')
if ($okBtn) {
    try {
        $ip2 = $okBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $ip2.Invoke()
        Log '已通过 UIA 点击弹窗「确认」'
    } catch {
        [void](Invoke-SafeClick -X $pOk[0] -Y $pOk[1] -What '确认(坐标)')
    }
} else {
        # 弹窗可能晚一点才出现：轮询等 8 秒，只有真的出现才点。
        # （以前是「没检测到也盲点一下」，万一布局不同就会点到别的东西）
        Log '暂未检测到「确认」弹窗，等待最多 8 秒...'
        $okBtn2 = $null
        $dlgDeadline = (Get-Date).AddSeconds(8)
        while ((Get-Date) -lt $dlgDeadline) {
            Start-Sleep -Milliseconds 700
            $okBtn2 = Find-ByName -Root $root -Patterns @('^确\s*认$') -Types @('Button')
            if ($okBtn2) { break }
        }
        if ($okBtn2) {
            try {
                $okBtn2.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                Log '弹窗出现后已点击「确认」'
            } catch {
                try {
                    $r2 = $okBtn2.Current.BoundingRectangle
                    [void](Invoke-SafeClick -X ([int]($r2.X + $r2.Width/2)) -Y ([int]($r2.Y + $r2.Height/2)) -What '确认(元素坐标)')
                } catch { }
            }
        } else {
            Log '确认没有弹窗，跳过（直接验收）。'
        }
}

# 4) 验收：TCP 探测
$deadline = (Get-Date).AddSeconds($VerifySeconds)
$up = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if (Test-Internet) { $up = $true; break }
}
if ($up) {
    Log '外网已通 ✅ 认证成功'
    Close-BrowserAfterAuth -Win $win -Root $root 
    if ($DryRun) { Save-Shot -Name 'dryrun' | Out-Null }
    exit 0
}

Log '认证后外网仍不通。' 'ERR'
$shot = Save-Shot -Name 'failed'
if ($DryRun) { Log '[DryRun] 未真正点击，上面的"不通"属于预期。' 'WRN'; exit 0 }
exit 5
