<#
.SYNOPSIS
    启动 BetterGI（如未运行）并自动执行「一条龙」。

.DESCRIPTION
    BetterGI 本身没有命令行 / 定时接口，因此本脚本用 Windows UI Automation 完成：
      1) 启动或复用 BetterGI 主窗口，并把它切到前台
      2) 点击左侧导航「一条龙」
      3) 点击「任务列表」右侧的蓝色播放按钮（开始按钮）
      4) 通过 BetterGI 自己的日志确认任务确实已启动

    本脚本必须以【管理员权限】且在【用户已登录的交互桌面】中运行，
    否则读不到 BetterGI 的控件（它会以管理员身份运行）也无法注入鼠标点击。

.PARAMETER BetterGIPath
    BetterGI 安装目录，默认 D:\BetterGI

.PARAMETER StartupDelaySeconds
    启动前额外等待秒数，用于唤醒后等显卡/网络就绪，默认 15

.PARAMETER OneDragonConfigName
    可选。指定「一条龙」配置名（下拉框）。留空表示用当前已选中的配置。

.PARAMETER SkipIfRanToday
    今天已经跑完过一条龙（日志中出现结束标记）就直接退出，避免重复执行。

.PARAMETER WaitCompleteMinutes
    大于 0 时，点击开始后继续等待任务结束（分钟），用于配合「跑完自动关机/睡眠」。

.PARAMETER DiagnoseOnly
    只导出一份 UI 结构快照到日志，不点击任何东西。排查用。
#>
[CmdletBinding()]
param(
    [string]$BetterGIPath = 'D:\BetterGI',
    [string]$ExeName = 'BetterGI.exe',
    [int]$StartupDelaySeconds = 15,
    [int]$WindowTimeoutSeconds = 180,
    [string]$OneDragonConfigName = '',
    [int]$ClickVerifySeconds = 60,
    [switch]$SkipIfRanToday,
    [int]$WaitCompleteMinutes = 0,
    [switch]$SleepAfterFinish,
    [int]$SleepDelaySeconds = 60,
    [switch]$KeepDisplayOn = $true,
    [switch]$DiagnoseOnly,
    [switch]$FocusGameAfterStart = $true,
    [int]$GameWaitSeconds = 120,
    [int]$WaitNetworkSeconds = 300,
    [switch]$AutoCampusPortal = $true,
    [int]$PortalRetries = 5,
    [int]$PortalRetryDelaySeconds = 60,
    [switch]$AbortIfNoNetwork = $true,
    [string]$PortalUrl = 'http://<门户主机>:<端口>/<门户路径>/login.jsp',
    [string]$WifiSsid = '<你的WiFi名称>',
    [string]$PlannedStartTime = '06:00',
    [int]$MaxLatenessMinutes = 120,
    [switch]$RequireACPower = $true,
    [switch]$AcceptPrivacyDialog,
    [int]$AcceptDialogSeconds = 180,
    [switch]$DryRun,
    [string]$WindowTitleLike = ''
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 日志
$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:LogDir = Join-Path $script:ScriptDir 'logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogFile = Join-Path $script:LogDir ("run-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))

function Log {
    param([string]$Message, [string]$Level = 'INF')
    $line = '[{0}] [{1}] {2}' -f (Get-Date).ToString('HH:mm:ss.fff'), $Level, $Message
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Log-Exception {
    param([string]$Where, $ErrorRecord)
    Log ("$Where 失败: " + $ErrorRecord.Exception.Message) 'ERR'
    if ($ErrorRecord.ScriptStackTrace) { Log ("  at " + ($ErrorRecord.ScriptStackTrace -replace "`r?`n", ' | ')) 'ERR' }
}

function Enable-Display {
    # 定时唤醒后 Windows 常只叫醒系统、显示器保持关闭。
    # 关键教训（10-19 实测）：SetCursorPos 只是"挪指针"，不算用户输入，不会重置输入空闲计时器，
    # 所以屏幕亮了又灭。必须用 mouse_event(MOUSEEVENTF_MOVE) 产生真实输入。
    try {
        $r = [IntPtr]::Zero
        [void][BgiNative]::SendMessageTimeout([IntPtr]0xffff, 0x0112, [IntPtr]0xF170, [IntPtr](-1), 2, 2000, [ref]$r)
    } catch { }
    try {
        # 真实输入：右移 3 像素再移回（不点击任何东西）
        [BgiNative]::mouse_event(0x0001, 3, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 90
        [BgiNative]::mouse_event(0x0001, [uint32]4294967293, 0, 0, [UIntPtr]::Zero)
    } catch { }
    try {
        $prev = [BgiNative]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED)
        if ($prev -eq 0) { Log 'SetThreadExecutionState 返回 0（调用失败，显示器可能仍会熄灭）' 'WRN' }
    } catch { Log ('SetThreadExecutionState 异常: ' + $_.Exception.Message) 'WRN' }
}

function Get-WifiSsid {
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

function Dismiss-Overlays {
    # 睡眠前如果开始菜单/搜索面板开着，唤醒后会原样留在桌面上，挡住后续所有鼠标点击。
    # （10-19 两次实拍都看到开始菜单盖在 Edge 前面）
    try {
        $fg = [BgiNative]::GetForegroundWindow()
        $sb = New-Object System.Text.StringBuilder 256
        [void][BgiNative]::GetClassName($fg, $sb, 256)
        $cls = $sb.ToString()
        if ($cls) { Log ('唤醒后前台窗口类名: ' + $cls) }
        $overlay = ($cls -match 'CoreWindow|Start|Search|Shell_TrayWnd|XamlExplorer|Windows\.UI\.Composition')
        for ($k = 0; $k -lt 2; $k++) {
            [BgiNative]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
            [BgiNative]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 250
        }
        if ($overlay) { Log '已关闭残留的开始菜单/搜索面板（ESC ×2）' }
    } catch { Log ('关闭浮层失败: ' + $_.Exception.Message) 'WRN' }
}

function Test-NetworkUp {
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

function Test-PortalReachable {
    # 门户可达 = WiFi 已连上、只差认证
    # 主机/端口从 $PortalUrl 解析（换学校只需改 -PortalUrl，不用改代码）
    $h = $null; $pt = 0
    try {
        $u = [System.Uri]$PortalUrl
        if ($u.Host) { $h = $u.Host }
        if ($u.Port -gt 0) { $pt = $u.Port }
        if (-not $h -or $pt -le 0) { Log '（提示）-PortalUrl 还没配置成你自己的门户地址，无法判断门户可达性' 'WRN'; return $false }
    } catch { }
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect($h, $pt, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(2000)) { $c.EndConnect($ar); $c.Close(); return $true }
        $c.Close()
        return $false
    } catch { return $false }
}

function Invoke-CampusPortalAuth {
    # 带重试的校园网认证：网络常常十几分钟后才真正就绪，只试一次太容易失败
    param([int]$MaxAttempts = 3, [int]$DelaySeconds = 60)
    $portalScript = Join-Path $script:ScriptDir "Connect-CampusNetwork.ps1"
    if (-not (Test-Path $portalScript)) { Log ("找不到 " + $portalScript) "WRN"; return $false }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Log ("校园网认证：第 " + $attempt + "/" + $MaxAttempts + " 次尝试")
        try {
            $portalArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $portalScript, '-Force', '-CloseBrowserAll')
            if ($PortalUrl) { $portalArgs += @('-PortalUrl', $PortalUrl) }
            if ($WifiSsid) { $portalArgs += @('-WifiSsid', $WifiSsid) }
            $out = & powershell.exe @portalArgs 2>&1
            foreach ($pl in @($out)) { Log ("  [portal] " + $pl) }
        } catch { Log ("Portal 认证脚本异常: " + $_.Exception.Message) "WRN" }
        Start-Sleep -Seconds 2
        if (Test-NetworkUp) { Log ("认证成功（第 " + $attempt + " 次尝试）"); return $true }
        if ($attempt -lt $MaxAttempts) {
            Log ("第 " + $attempt + " 次认证没成功，" + $DelaySeconds + " 秒后重试") "WRN"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    return $false
}

# ---------------------------------------------------------------- 环境检查
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$ns = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class BgiNative
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT Point);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}

public static class PinkFinder
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);

    // 在截图里找 bilibili 登录页那个粉色的「同意」按钮；找不到返回 null
    public static int[] FindPinkAgreeButton(System.Drawing.Bitmap bmp)
    {
        if (bmp == null) return null;
        int w = bmp.Width, h = bmp.Height;
        if (w < 200 || h < 200) return null;
        System.Drawing.Rectangle full = new System.Drawing.Rectangle(0, 0, w, h);
        System.Drawing.Imaging.BitmapData bd = bmp.LockBits(full, System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format24bppRgb);
        int stride = bd.Stride;
        byte[] buf = new byte[stride * h];
        Marshal.Copy(bd.Scan0, buf, 0, buf.Length);
        bmp.UnlockBits(bd);

        int[] rowCount = new int[h];
        for (int y = 0; y < h; y++)
        {
            int off = y * stride, c = 0;
            for (int x = 0; x < w; x++)
            {
                int i = off + x * 3;
                int b0 = buf[i], g0 = buf[i + 1], r0 = buf[i + 2];
                if (r0 > 190 && g0 > 55 && g0 < 160 && b0 > 100 && b0 < 210 && (r0 - g0) > 70 && (b0 - g0) > 15) c++;
            }
            rowCount[y] = c;
        }

        int th = (int)(w * 0.03); if (th < 40) th = 40;
        int bestStart = -1, bestEnd = -1, curStart = -1;
        for (int y = 0; y < h; y++)
        {
            if (rowCount[y] >= th) { if (curStart < 0) curStart = y; }
            else if (curStart >= 0)
            {
                if (bestStart < 0 || (y - curStart) > (bestEnd - bestStart + 1)) { bestStart = curStart; bestEnd = y - 1; }
                curStart = -1;
            }
        }
        if (curStart >= 0 && (bestStart < 0 || (h - curStart) > (bestEnd - bestStart + 1))) { bestStart = curStart; bestEnd = h - 1; }
        if (bestStart < 0) return null;
        int bandH = bestEnd - bestStart + 1;
        if (bandH < h * 0.006 || bandH > h * 0.2) return null;

        int[] colCount = new int[w];
        for (int y = bestStart; y <= bestEnd; y++)
        {
            int off = y * stride;
            for (int x = 0; x < w; x++)
            {
                int i = off + x * 3;
                int b0 = buf[i], g0 = buf[i + 1], r0 = buf[i + 2];
                if (r0 > 190 && g0 > 55 && g0 < 160 && b0 > 100 && b0 < 210 && (r0 - g0) > 70 && (b0 - g0) > 15) colCount[x]++;
            }
        }
        int colTh = (int)(bandH * 0.5); if (colTh < 8) colTh = 8;
        int bx0 = -1, bx1 = -1, bW = 0, curS = -1;
        for (int x = 0; x < w; x++)
        {
            if (colCount[x] >= colTh) { if (curS < 0) curS = x; }
            else if (curS >= 0)
            {
                if ((x - curS) > bW) { bW = x - curS; bx0 = curS; bx1 = x - 1; }
                curS = -1;
            }
        }
        if (curS >= 0 && (w - curS) > bW) { bW = w - curS; bx0 = curS; bx1 = w - 1; }
        if (bx0 < 0) return null;

        int bw = bx1 - bx0 + 1;
        double aspect = (double)bw / bandH;
        if (bw < w * 0.02 || bw > w * 0.45) return null;
        if (aspect < 1.4 || aspect > 7.0) return null;
        double cxr = ((bx0 + bx1) / 2.0) / w, cyr = ((bestStart + bestEnd) / 2.0) / h;
        if (cxr < 0.25 || cxr > 0.80) return null;
        if (cyr < 0.30 || cyr > 0.90) return null;
        return new int[] { bx0, bestStart, bw, bandH };
    }
}
'@

if (-not ('BgiNative' -as [type])) { Add-Type -TypeDefinition $ns -Language CSharp -ReferencedAssemblies 'System.Drawing' }

# DPI 感知：保证 UIA 返回的坐标与 SetCursorPos 使用的是同一套物理像素
try { [void][BgiNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { try { [void][BgiNative]::SetProcessDPIAware() } catch { } }

$SW_RESTORE = 9
$GA_ROOT = 2
$WS_EX_TOOLWINDOW = 0x00000080
$MOUSEEVENTF_LEFTDOWN = 0x0002
$MOUSEEVENTF_LEFTUP = 0x0004
$VK_MENU = 0x12
$KEYEVENTF_KEYUP = 0x0002
$ES_CONTINUOUS = [uint32]2147483648
$ES_SYSTEM_REQUIRED = [uint32]0x00000001
$ES_DISPLAY_REQUIRED = [uint32]0x00000002

Log ("===== 开始 =====")
Log ("脚本目录: " + $script:ScriptDir)
Log ("BetterGI 目录: " + $BetterGIPath)
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log ("当前是否管理员: " + $isAdmin + " ；用户: " + $identity.Name)
if (-not $isAdmin) {
    Log '警告：未以管理员身份运行。BetterGI 以管理员运行时，普通权限进程无法读取它的界面、也无法点击它。' 'WRN'
}

$exePath = Join-Path $BetterGIPath $ExeName
if (-not (Test-Path $exePath)) { Log ("找不到 BetterGI.exe: " + $exePath) 'ERR'; exit 2 }

# ---------------------------------------------------------------- 供电检查
# 笔记本用电池时不跑：一条龙动辄几分钟到几十分钟，电池跑既费电又可能中途断
if ($RequireACPower) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $pwr = [System.Windows.Forms.SystemInformation]::PowerStatus
        if ($pwr.PowerLineStatus -ne [System.Windows.Forms.PowerLineStatus]::Online) {
            Log ("当前使用电池供电（电量 " + [int]($pwr.BatteryLifePercent * 100) + "%），按 -RequireACPower 不执行。") "ERR"
            Log "接上电源后再运行，或加 -RequireACPower:`$false 强制运行。" "ERR"
            exit 11
        }
        Log ("供电状态: 接电源 ✅（电池 " + [int]($pwr.BatteryLifePercent * 100) + "%）")
    } catch { Log ("读取供电状态失败，继续执行: " + $_.Exception.Message) "WRN" }
}

# ---------------------------------------------------------------- 迟到保护
# 06:00 的任务如果因为机器没醒而错过，StartWhenAvailable 会在用户早上唤醒机器时补跑——
# 那时用户正在用电脑，突然冒出 BetterGI 是灾难。迟到超过 MaxLatenessMinutes 就直接放弃。
if ($MaxLatenessMinutes -gt 0 -and $PlannedStartTime) {
    try {
        $planned = [datetime]::ParseExact($PlannedStartTime, 'HH:mm', $null)
        $plannedToday = (Get-Date).Date.AddHours($planned.Hour).AddMinutes($planned.Minute)
        $lateMin = [int]((Get-Date) - $plannedToday).TotalMinutes
        if ($lateMin -gt $MaxLatenessMinutes) {
            Log ("本次启动比预定时间 " + $PlannedStartTime + " 晚了 " + $lateMin + " 分钟，超过 " + $MaxLatenessMinutes + " 分钟上限，直接放弃（避免打扰正在用电脑的人）。") "ERR"
            Log "如需立即补跑，手动执行: Run-BetterGI-OneDragon.ps1 -MaxLatenessMinutes 0" "ERR"
            exit 13
        }
        Log ("相对预定时间 " + $PlannedStartTime + " 的偏差: " + $lateMin + " 分钟")
    } catch { Log ("迟到检查失败（继续执行）: " + $_.Exception.Message) "WRN" }
}

# ---------------------------------------------------------------- 锁屏检测
# 锁屏/登录界面下 Windows 不接受任何鼠标注入，与其后面莫名其妙失败，不如这里直接说清楚
$lockedBy = @()
    foreach ($procName in @('LogonUI', 'LockApp')) {
        if (Get-Process -Name $procName -ErrorAction SilentlyContinue) { $lockedBy += $procName }
    }
if ($lockedBy.Count -gt 0) {
    Log ("当前桌面处于锁屏/登录界面（检测到进程: " + ($lockedBy -join ",") + "），无法操作 BetterGI，本次退出。") "ERR"
    Log "解决办法：设置 → 账户 → 登录选项 → 「如果你离开了，Windows 何时要求你重新登录」→ 从不" "ERR"
    exit 10
}

# ---------------------------------------------------------------- 保持屏幕/系统不休眠
if ($KeepDisplayOn) {
    try {
        [void][BgiNative]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED)
        Log '已请求运行期间保持系统与显示器唤醒'
        for ($di = 1; $di -le 3; $di++) {
            Enable-Display
            if ($di -eq 1) { Log '已主动打开显示器（定时唤醒后它常常是关着的，连试 3 次）' }
            Start-Sleep -Milliseconds 2500
        }
        Dismiss-Overlays
    } catch { Log ('SetThreadExecutionState 失败: ' + $_.Exception.Message) 'WRN' }
}

# ---------------------------------------------------------------- 工具函数
function Get-TodayLogPath {
    $dir = Join-Path $BetterGIPath 'log'
    if (-not (Test-Path $dir)) { return $null }
    $stamp = (Get-Date).ToString('yyyyMMdd')
    $f = Get-ChildItem -Path $dir -File -Filter ("*{0}.log" -f $stamp) -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { return $f.FullName }
    $f = Get-ChildItem -Path $dir -File -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

function Read-LogText {
    param([string]$Path, [long]$FromOffset = 0)
    $r = @{ Text = ''; Offset = $FromOffset; Length = 0 }
    if (-not $Path -or -not (Test-Path $Path)) { return $r }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            $r.Length = $len
            $start = $FromOffset
            if ($start -lt 0 -or $start -gt $len) { $start = 0 }
            [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $r.Text = $sr.ReadToEnd()
            $sr.Dispose()
            $r.Offset = $len
        } finally { $fs.Dispose() }
    } catch {
        Log ('读取日志失败: ' + $_.Exception.Message) 'WRN'
    }
    return $r
}

function Get-BetterGIWindows {
    param([int[]]$ProcessIds)
    $script:foundWindows = @()
    $script:targetPids = $ProcessIds
    $cb = [BgiNative+EnumWindowsProc] {
        param($hWnd, $lParam)
        try {
            $procId = [uint32]0
            [void][BgiNative]::GetWindowThreadProcessId($hWnd, [ref]$procId)
            if ($script:targetPids -contains [int]$procId) {
                if ([BgiNative]::IsWindowVisible($hWnd)) {
                    $sb = New-Object System.Text.StringBuilder 512
                    [void][BgiNative]::GetWindowText($hWnd, $sb, 512)
                    $cb2 = New-Object System.Text.StringBuilder 256
                    [void][BgiNative]::GetClassName($hWnd, $cb2, 256)
                    $title = $sb.ToString()
                    $cls = $cb2.ToString()
                    if ($title.Length -gt 0 -and $cls -notlike '*Shell_TrayWnd*') {
                        $script:foundWindows += , @{ Hwnd = $hWnd; Title = $title; Class = $cls; Pid = [int]$procId }
                    }
                }
            }
        } catch { }
        return $true
    }
    [void][BgiNative]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:foundWindows
}

function Get-GameWindow {
    # 原神的 Process.MainWindowHandle 常常是 0，必须自己枚举该进程的可见窗口，取面积最大的那个
    param([string[]]$Names = @("YuanShen", "GenshinImpact"))
    $pids = @(Get-Process -Name $Names -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if ($pids.Count -eq 0) { return $null }
    $script:gameWindows = @()
    $script:gamePids = $pids
    $cb = [BgiNative+EnumWindowsProc] {
        param($hWnd, $lParam)
        try {
            $procId = [uint32]0
            [void][BgiNative]::GetWindowThreadProcessId($hWnd, [ref]$procId)
            if ($script:gamePids -contains [int]$procId) {
                if ([BgiNative]::IsWindowVisible($hWnd)) {
                    $r = New-Object BgiNative+RECT
                    if ([BgiNative]::GetWindowRect($hWnd, [ref]$r)) {
                        $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
                        if ($w -gt 300 -and $hh -gt 200) {
                            $script:gameWindows += , @{ Hwnd = $hWnd; Area = ($w * $hh); Pid = [int]$procId; W = $w; H = $hh }
                        }
                    }
                }
            }
        } catch { }
        return $true
    }
    [void][BgiNative]::EnumWindows($cb, [IntPtr]::Zero)
    if ($script:gameWindows.Count -eq 0) { return $null }
    return ($script:gameWindows | Sort-Object { $_.Area } -Descending | Select-Object -First 1)
}

function Get-GameClientRect {
    param([IntPtr]$Hwnd)
    try {
        $rc = New-Object PinkFinder+RECT
        if (-not [PinkFinder]::GetClientRect($Hwnd, [ref]$rc)) { return $null }
        $pt = New-Object PinkFinder+POINT
        $pt.X = 0; $pt.Y = 0
        if (-not [PinkFinder]::ClientToScreen($Hwnd, [ref]$pt)) { return $null }
        return @{ X = $pt.X; Y = $pt.Y; W = ($rc.Right - $rc.Left); H = ($rc.Bottom - $rc.Top) }
    } catch { return $null }
}

function Start-BetterGIProcess {
    Log ('启动 BetterGI: ' + $exePath)
    $p = Start-Process -FilePath $exePath -WorkingDirectory $BetterGIPath -PassThru
    Log ('已启动进程 PID=' + $p.Id)
}

function Wait-BetterGIWindow {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastLog = Get-Date
    while ((Get-Date) -lt $deadline) {
        $procs = Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($ExeName)) -ErrorAction SilentlyContinue
        if ($procs) {
            $wins = @(Get-BetterGIWindows -ProcessIds @($procs | ForEach-Object { $_.Id }))
            if ($WindowTitleLike) { $wins = @($wins | Where-Object { $_.Title -like $WindowTitleLike }) }
            if ($wins -and $wins.Count -gt 0) {
                $w = $wins | Sort-Object { $_.Title.Length } -Descending | Select-Object -First 1
                Log ("找到窗口: hwnd=" + $w.Hwnd + " title='" + $w.Title + "' class='" + $w.Class + "'")
                return $w
            }
        }
        if (((Get-Date) - $lastLog).TotalSeconds -ge 15) {
            Log '  仍在等待 BetterGI 主窗口...'
            $lastLog = Get-Date
        }
        Start-Sleep -Milliseconds 800
    }
    return $null
}

function Set-WindowForeground {
    param([IntPtr]$Hwnd)
    try { [void][BgiNative]::ShowWindow($Hwnd, $SW_RESTORE) } catch { }
    Start-Sleep -Milliseconds 250
    $fg = [BgiNative]::GetForegroundWindow()
    if ($fg -eq $Hwnd) { return $true }
    try { [void][BgiNative]::SetForegroundWindow($Hwnd) } catch { }
    Start-Sleep -Milliseconds 250
    if ([BgiNative]::GetForegroundWindow() -eq $Hwnd) { return $true }

    # 前台锁定时用 ALT 键解锁，再试一次
    try {
        [BgiNative]::keybd_event($VK_MENU, 0, 0, [UIntPtr]::Zero)
        [BgiNative]::keybd_event($VK_MENU, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 120
        [void][BgiNative]::SetForegroundWindow($Hwnd)
        Start-Sleep -Milliseconds 250
    } catch { }
    if ([BgiNative]::GetForegroundWindow() -eq $Hwnd) { return $true }

    # 附加输入队列，强制切换
    try {
        $fg2 = [BgiNative]::GetForegroundWindow()
        $fgPid = [uint32]0
        $fgThread = [BgiNative]::GetWindowThreadProcessId($fg2, [ref]$fgPid)
        $curThread = [BgiNative]::GetCurrentThreadId()
        [void][BgiNative]::AttachThreadInput($curThread, $fgThread, $true)
        [void][BgiNative]::ShowWindow($Hwnd, $SW_RESTORE)
        [void][BgiNative]::BringWindowToTop($Hwnd)
        [void][BgiNative]::SetForegroundWindow($Hwnd)
        Start-Sleep -Milliseconds 200
        [void][BgiNative]::AttachThreadInput($curThread, $fgThread, $false)
    } catch { }

    for ($i = 0; $i -lt 20; $i++) {
        if ([BgiNative]::GetForegroundWindow() -eq $Hwnd) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

function Get-Descendants {
    param($Root)
    return $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
}

function Get-RectOf {
    param($Element)
    try {
        $r = $Element.Current.BoundingRectangle
        return @{ X = [double]$r.X; Y = [double]$r.Y; W = [double]$r.Width; H = [double]$r.Height; CX = [double]($r.X + $r.Width / 2); CY = [double]($r.Y + $r.Height / 2); R = [double]($r.X + $r.Width); B = [double]($r.Y + $r.Height) }
    } catch { return $null }
}

function Invoke-ClickAt {
    param([int]$X, [int]$Y, [string]$What = '')
    $pt = New-Object BgiNative+POINT
    $pt.X = $X; $pt.Y = $Y
    # 被遮挡时不要立刻放弃：其他窗口（比如聊天窗口）可能刚好抢了前台，
    # 重新把 BetterGI 置前台后再试，最多 3 次。
    $root = [BgiNative]::GetAncestor([BgiNative]::WindowFromPoint($pt), $GA_ROOT)
    $retry = 0
    while ($root -ne $script:BgiHwnd -and $retry -lt 3) {
        $retry++
        Log ("点击(" + $X + "," + $Y + ") 被 hwnd=" + $root + " 遮挡，第 " + $retry + " 次重新置前台重试") 'WRN'
        try { [void](Set-WindowForeground -Hwnd $script:BgiHwnd) } catch { }
        Start-Sleep -Milliseconds 800
        $root = [BgiNative]::GetAncestor([BgiNative]::WindowFromPoint($pt), $GA_ROOT)
    }
    if ($root -ne $script:BgiHwnd) {
        Log ("点击目标被其他窗口遮挡，放弃。点(" + $X + "," + $Y + ") 命中 hwnd=" + $root + " 期望 hwnd=" + $script:BgiHwnd) 'ERR'
        return $false
    }
    Log ("点击 " + $What + " @ (" + $X + "," + $Y + ")")
    [void][BgiNative]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 120
    [BgiNative]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [BgiNative]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 300
    return $true
}

function Save-WindowScreenshot {
    param([IntPtr]$Hwnd, [string]$Name = 'shot')
    try {
        $r = New-Object BgiNative+RECT
        if (-not [BgiNative]::GetWindowRect($Hwnd, [ref]$r)) { return $null }
        $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
        if ($w -le 0 -or $h -le 0) { return $null }
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $g.GetHdc()
        $ok = $false
        try { $ok = [BgiNative]::PrintWindow($Hwnd, $hdc, 2) } catch { }
        $g.ReleaseHdc($hdc)
        if (-not $ok) { try { $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size) } catch { } }
        $g.Dispose()
        $path = Join-Path $script:LogDir ($Name + '-' + (Get-Date).ToString('HHmmss') + '.png')
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Log ('已保存截图: ' + $path)
        return $path
    } catch {
        Log ('截图失败: ' + $_.Exception.Message) 'WRN'
        return $null
    }
}

function Write-UiaSnapshot {
    param($Root, [string]$Name = 'uia')
    try {
        $sb = New-Object System.Text.StringBuilder
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $fn = $null
        $fn = {
            param($el, $depth)
            if ($depth -gt 10) { return }
            try {
                $c = $el.Current
                $r = $c.BoundingRectangle
                [void]$sb.AppendLine(('{0}{1} | "{2}" | AutoId="{3}" | {4},{5},{6},{7}' -f ('  ' * $depth),
                    $c.ControlType.ProgrammaticName.Replace('ControlType.', ''), $c.Name, $c.AutomationId,
                    [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height))
            } catch { return }
            $child = $walker.GetFirstChild($el)
            while ($null -ne $child) { & $fn $child ($depth + 1); $child = $walker.GetNextSibling($child) }
        }
        & $fn $Root 0
        $path = Join-Path $script:LogDir ('uia-' + $Name + '-' + (Get-Date).ToString('HHmmss') + '.txt')
        $sb.ToString() | Out-File -FilePath $path -Encoding UTF8
        Log ('已保存 UI 结构快照: ' + $path)
    } catch { Log ('UI 快照失败: ' + $_.Exception.Message) 'WRN' }
}

# ---------------------------------------------------------------- 0. 今天是否已经跑过
$todayLog = Get-TodayLogPath
Log ('BetterGI 日志: ' + $todayLog)
if ($SkipIfRanToday -and $todayLog) {
    $all = Read-LogText -Path $todayLog -FromOffset 0
    if ($all.Text -match '一条龙和配置组任务结束|一条龙结束汇总') {
        Log '今天已经执行过一条龙（日志中有结束标记），按 SkipIfRanToday 直接退出。'
        exit 0
    }
}

# ---------------------------------------------------------------- 等网络就绪
# 长时间休眠后 WiFi 可能比系统晚起来，BetterGI 登录游戏需要网络，所以先探一下
if ($WaitNetworkSeconds -gt 0) {
    $netUp = Test-NetworkUp
    if (-not $netUp) {
        Log ("外网不通，等待网络就绪（最多 " + $WaitNetworkSeconds + " 秒；一旦门户可达就立刻认证，不等满）")
        $netDeadline = (Get-Date).AddSeconds($WaitNetworkSeconds)
        $portalReady = $false
        $keepN = 0
        $noSsid = 0
        # 适配器被"设置里的 WLAN 开关"关掉时，等再久也不会通，直接交给认证脚本去启用
        $wifiDisabled = $false
        try {
            $wad = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'WLAN' -or $_.InterfaceDescription -match 'Wireless|Wi-?Fi|无线' } | Select-Object -First 1
            if ($wad -and $wad.AdminStatus -eq 'Disabled') {
                $wifiDisabled = $true
                Log 'WLAN 适配器处于禁用状态 → 跳过等待，直接启用并认证' 'WRN'
            }
        } catch { }
        while ((Get-Date) -lt $netDeadline -and -not $wifiDisabled) {
            if (Test-PortalReachable) { $portalReady = $true; break }
            Start-Sleep -Seconds 5
            if (Test-NetworkUp) { $netUp = $true; break }
            # 长时间等待时每 30 秒重新点亮一次，否则屏幕会自己灭
            $keepN++
            if (($keepN % 6) -eq 0) { Enable-Display }
            # 一直没有 SSID（无线电/网卡有问题）时，别傻等满 5 分钟，早点交给认证脚本去开无线电
            if (-not (Get-WifiSsid)) { $noSsid += 5 } else { $noSsid = 0 }
            if ($noSsid -ge 40) {
                Log ("WiFi 已经 " + $noSsid + " 秒没有任何 SSID（无线电可能是关的），交给认证脚本处理") "WRN"
                break
            }
        }
        if ($netUp) {
            Log "网络已连通"
        } elseif ($portalReady) {
            Log "门户可达但外网不通 → 走校园网自动认证"
            if ($AutoCampusPortal) {
                $netUp = Invoke-CampusPortalAuth -MaxAttempts $PortalRetries -DelaySeconds $PortalRetryDelaySeconds
            }
        } else {
            # 等超时了还是不通：交给认证脚本处理 —— 它会先尝试连接 WiFi，再走 Portal 认证
            Log "等待超时，交给校园网认证脚本（会先尝试连接 WiFi）" "WRN"
            if ($AutoCampusPortal) {
                $netUp = Invoke-CampusPortalAuth -MaxAttempts $PortalRetries -DelaySeconds $PortalRetryDelaySeconds
            }
        }
    }
    if ($netUp) {
        Log "网络已连通 ✅"
    } else {
        Log "网络仍不通（认证重试已用尽）。" "ERR"
        if ($AbortIfNoNetwork) {
            Log "按 -AbortIfNoNetwork 设置，本次不启动 BetterGI：没网就跑等于制造一堆无效操作（10-19 早上白跑 85 分钟）。" "ERR"
            Log "可以手动连上网后再补跑：Run-BetterGI-OneDragon.ps1 -StartupDelaySeconds 0" "ERR"
            exit 12
        }
        Log "继续执行（游戏登录可能会失败）" "WRN"
    }
}

if ($StartupDelaySeconds -gt 0) {
    Log ('启动前等待 ' + $StartupDelaySeconds + ' 秒，让系统/显卡/网络就绪')
    Start-Sleep -Seconds $StartupDelaySeconds
}

# ---------------------------------------------------------------- 1. 启动 / 复用 BetterGI
$procName = [System.IO.Path]::GetFileNameWithoutExtension($ExeName)
$procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
$window = $null
if (-not $procs) {
    Start-BetterGIProcess
    $window = Wait-BetterGIWindow -TimeoutSeconds $WindowTimeoutSeconds
} else {
    Log ('BetterGI 已在运行，PID: ' + (($procs | ForEach-Object { $_.Id }) -join ','))
    $window = Wait-BetterGIWindow -TimeoutSeconds 20
    if (-not $window) {
        Log 'BetterGI 进程在运行但没有可见主窗口（可能已最小化到托盘）。尝试重新启动以唤出窗口。' 'WRN'
        Start-BetterGIProcess
        Start-Sleep -Seconds 5
        $window = Wait-BetterGIWindow -TimeoutSeconds 60
        if (-not $window) {
            # 只有确认没有窗口时才结束旧进程，避免杀掉正在跑的任务
            Log '仍无可见窗口，结束旧的 BetterGI 进程后重新启动。' 'WRN'
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            Start-BetterGIProcess
            $window = Wait-BetterGIWindow -TimeoutSeconds $WindowTimeoutSeconds
        }
    }
}
if (-not $window) { Log '无法获得 BetterGI 主窗口，退出。' 'ERR'; exit 3 }

$script:BgiHwnd = $window.Hwnd
$AE = [System.Windows.Automation.AutomationElement]
$root = $AE::FromHandle([IntPtr]$script:BgiHwnd)
$script:BgiRoot = $root
if (-not $root) { Log '取得主窗口的 UI Automation 根元素失败。' 'ERR'; exit 3 }
Log ("UIA 根元素: '" + $root.Current.Name + "' class='" + $root.Current.ClassName + "'")

$desc = $null
try { $desc = Get-Descendants -Root $root } catch { }
if (-not $desc -or $desc.Count -eq 0) {
    Log '读不到 BetterGI 的界面控件（数量为 0）。最可能原因：本脚本没有以管理员身份运行，而 BetterGI 是管理员权限运行。' 'ERR'
    Save-WindowScreenshot -Hwnd $script:BgiHwnd -Name 'no-uia' | Out-Null
    exit 4
}
Log ('可访问控件数量: ' + $desc.Count)

if ($DiagnoseOnly) {
    Write-UiaSnapshot -Root $root -Name 'window'
    Save-WindowScreenshot -Hwnd $script:BgiHwnd -Name 'diag' | Out-Null
    Log 'DiagnoseOnly 模式结束。'
    exit 0
}

# ---------------------------------------------------------------- 2. 激活窗口
if (-not (Set-WindowForeground -Hwnd $script:BgiHwnd)) {
    Log '警告：无法把 BetterGI 切到前台，鼠标点击可能落到别的窗口上。' 'WRN'
} else {
    Log 'BetterGI 已置于前台'
}
Start-Sleep -Milliseconds 600

# 窗口刚激活时，第一次鼠标点击会被系统用于激活窗口而丢掉，先在标题栏做一次无害的预热点击
try {
    $wr = New-Object BgiNative+RECT
    if ([BgiNative]::GetWindowRect([IntPtr]$script:BgiHwnd, [ref]$wr)) {
        $primerX = [int](($wr.Left + $wr.Right) / 2)
        $primerY = [int]($wr.Top + 12)
        [void](Invoke-ClickAt -X $primerX -Y $primerY -What "标题栏预热点击")
        Start-Sleep -Milliseconds 400
    }
} catch { Log ("预热点击失败: " + $_.Exception.Message) "WRN" }

# 判断「任务列表」是否已存在，用于确认已经处在一条龙页面
function Test-OneDragonPage {
    param($Root)
    try {
        $cond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, '任务列表')
        $hits = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
        foreach ($h in $hits) {
            try {
                if ($h.Current.IsOffscreen) { continue }
                $rr = $h.Current.BoundingRectangle
                if ($rr.Width -gt 0 -and $rr.Height -gt 0) { return $true }
            } catch { }
        }
        return $false
    } catch { return $false }
}


function Wait-OneDragonPage {
    param([int]$Seconds = 8)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        if (Test-OneDragonPage -Root $script:BgiRoot) { return $true }
    }
    return $false
}

function Invoke-NavSelect {
    param($Element, [double]$Cx, [double]$Cy, [string]$Name)
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if (-not (Invoke-ClickAt -X ([int]$Cx) -Y ([int]$Cy) -What ("导航「" + $Name + "」第" + $attempt + "次"))) { return $false }
        if (Wait-OneDragonPage -Seconds 6) { Log "页面已切换到一条龙"; return $true }
    }
    Log "鼠标点击未能切换页面，改用 UI Automation 选中/调用模式。" "WRN"
    try {
        $sel = $Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        $sel.Select()
    } catch {
        try {
            $inv = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            $inv.Invoke()
        } catch { Log ("选中与调用模式均不可用: " + $_.Exception.Message) "WRN" }
    }
    if (Wait-OneDragonPage -Seconds 10) { Log "页面已通过选中模式切换"; return $true }
    return $false
}
# ---------------------------------------------------------------- 3. 选择左侧「一条龙」
if (-not (Test-OneDragonPage -Root $root)) {
    $winRect = Get-RectOf $root
    $navCond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, '一条龙')
    $navs = @()
    try { $navs = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $navCond) } catch { }
    Log ('名为「一条龙」的元素数量: ' + $navs.Count)

    $script:navTarget = $null
    $script:navScore = [double]::MaxValue
    foreach ($n in $navs) {
        try { $c = $n.Current } catch { continue }
        if ($c.IsOffscreen) { continue }
        $r = Get-RectOf $n
        if (-not $r -or $r.W -le 0 -or $r.H -le 0) { continue }
        # 只在左侧导航栏范围内找（窗口宽度的左侧 30%）
        if ($winRect -and $r.CX -gt ($winRect.X + $winRect.W * 0.30)) { continue }
        $score = $r.CX
        if ($c.ControlType -eq [System.Windows.Automation.ControlType]::ListItem) { $score -= 1000 }
        if ($c.ControlType -eq [System.Windows.Automation.ControlType]::TabItem) { $score -= 1000 }
        if ($c.ControlType -eq [System.Windows.Automation.ControlType]::Button) { $score -= 500 }
        if ($score -lt $script:navScore) { $script:navScore = $score; $script:navTarget = $n }
    }

    if (-not $script:navTarget) {
        Log '在左侧导航栏找不到「一条龙」入口。' 'ERR'
        Save-WindowScreenshot -Hwnd $script:BgiHwnd -Name 'nav-not-found' | Out-Null
        Write-UiaSnapshot -Root $root -Name 'nav-not-found'
        exit 5
    }

    $nr = Get-RectOf $script:navTarget
    $navName = ''
    try { $navName = $script:navTarget.Current.Name } catch { }
    # 点击导航并确认页面切换（Invoke-NavSelect 内含重试与选中模式兜底）
    $ok = Invoke-NavSelect -Element $script:navTarget -Cx $nr.CX -Cy $nr.CY -Name $navName
    if (-not $ok) {
        Log '切换不到一条龙页面。' 'ERR'
        Save-WindowScreenshot -Hwnd $script:BgiHwnd -Name 'page-switch-failed' | Out-Null
        Write-UiaSnapshot -Root $root -Name 'page-switch-failed'
        exit 6
    }
}
Log '已在「一条龙」页面'

# ---------------------------------------------------------------- 4. 可选：选择一条龙配置
if ($OneDragonConfigName) {
    try {
        $comboCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::ComboBox)
        $combos = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $comboCond)
        $target = $null
        foreach ($cb in $combos) {
            if ($cb.Current.Name -eq $OneDragonConfigName) { $target = $cb; break }
        }
        if (-not $target -and $combos.Count -gt 0) { $target = $combos[0] }
        if ($target) {
            if ($target.Current.Name -ne $OneDragonConfigName) {
                Log ('切换一条龙配置 -> ' + $OneDragonConfigName)
                $ec = $target.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
                $ec.Expand()
                Start-Sleep -Milliseconds 700
                $itemCond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $OneDragonConfigName)
                $items = $target.FindAll([System.Windows.Automation.TreeScope]::Descendants, $itemCond)
                if (-not $items -or $items.Count -eq 0) {
                    $items = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $itemCond)
                }
                $picked = $false
                foreach ($it in $items) {
                    try {
                        $si = $it.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
                        $si.Select(); $picked = $true; break
                    } catch { continue }
                }
                if (-not $picked) { Log '没能在下拉框里选中该配置（可能只有这一个配置）。' 'WRN' }
                try { $ec.Collapse() } catch { }
                Start-Sleep -Milliseconds 500
            } else {
                Log ('一条龙配置已经是: ' + $OneDragonConfigName)
            }
        } else {
            Log '没找到配置下拉框，继续使用当前配置。' 'WRN'
        }
    } catch { Log-Exception '选择一条龙配置' $_.Exception }
}

# ---------------------------------------------------------------- 5. 找「任务列表」右侧的播放按钮
$headerText = $null
try {
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, '任务列表')
    $hits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    Log ('「任务列表」元素数量: ' + $hits.Count)
    $bestY = [double]::MaxValue
    foreach ($h in $hits) {
        try { $c = $h.Current } catch { continue }
        if ($c.IsOffscreen) { continue }
        $r = Get-RectOf $h
        if (-not $r -or $r.W -le 0 -or $r.H -le 0) { continue }
        $score = $r.Y
        if ($c.ControlType -eq [System.Windows.Automation.ControlType]::Text) { $score -= 100 }
        if ($score -lt $bestY) { $bestY = $score; $headerText = $h }
    }
} catch { }
if (-not $headerText) { Log '找不到「任务列表」标题文字。' 'ERR'; Save-WindowScreenshot -Hwnd $script:BgiHwnd -Name 'no-header' | Out-Null; exit 7 }

$ht = Get-RectOf $headerText
Log ("「任务列表」位置: 左=" + [int]$ht.X + " 上=" + [int]$ht.Y + " 宽=" + [int]$ht.W + " 高=" + [int]$ht.H)

$buttonCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
$buttons = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCond)
Log ('界面按钮总数: ' + $buttons.Count)

$script:playBtn = $null
$script:playScore = [double]::MaxValue
foreach ($b in $buttons) {
    try { $c = $b.Current } catch { continue }
    if ($c.IsOffscreen) { continue }
    $r = Get-RectOf $b
    if (-not $r -or $r.W -le 8 -or $r.H -le 8 -or $r.W -gt 160 -or $r.H -gt 160) { continue }
    # 与标题同一行（垂直误差在 1 倍字高内），且在标题右侧
    if ([Math]::Abs($r.CY - $ht.CY) -gt [Math]::Max(12, $ht.H * 1.0)) { continue }
    if ($r.X -lt ($ht.R - 24)) { continue }
    if ($r.X -lt $script:playScore) { $script:playScore = $r.X; $script:playBtn = $b }
}

if (-not $script:playBtn) {
    Log '按位置没找到播放按钮，改用名称匹配（开始/启动/运行/播放/Start/Play）。' 'WRN'
    foreach ($b in $buttons) {
        try { $c = $b.Current } catch { continue }
        if ($c.Name -match '开始|启动|运行|播放|Start|Play|Run') {
            $r = Get-RectOf $b
            if (-not $r -or $r.W -le 0 -or $r.H -le 0) { continue }
            if ($r.X -lt $script:playScore) { $script:playScore = $r.X; $script:playBtn = $b }
        }
    }
}

if ($script:playBtn) {
    $pr = Get-RectOf $script:playBtn
    $pname = ''
    try { $pname = $script:playBtn.Current.Name } catch { }
    Log ("播放按钮: 名称='" + $pname + "' 位置=" + [int]$pr.CX + "," + [int]$pr.CY + " 尺寸=" + [int]$pr.W + "x" + [int]$pr.H)
    $clickX = [int]$pr.CX
    $clickY = [int]$pr.CY
} else {
    # 最后兜底：按截图量到的相对比例估算（任务列表标题左缘右侧约 10 倍字高）
    $clickX = [int]($ht.X + $ht.H * 10.4)
    $clickY = [int]$ht.CY
    Log ('未找到按钮元素，使用估算坐标点击: ' + $clickX + ',' + $clickY) 'WRN'
}

if ($DryRun) {
    Log ("DryRun: 已定位开始按钮 (" + $clickX + "," + $clickY + ")，不执行点击。")
    Save-WindowScreenshot -Hwnd $script:BgiHwnd -Name "dryrun" | Out-Null
    Write-UiaSnapshot -Root $root -Name "dryrun"
    exit 0
}

# ---------------------------------------------------------------- 6. 点击开始（带重试）
$started = $false
$attempts = 3
for ($attempt = 1; $attempt -le $attempts -and -not $started; $attempt++) {
    $todayLog = Get-TodayLogPath
    $snap = Read-LogText -Path $todayLog -FromOffset 0
    $beforeLen = $snap.Length
    Log ("第 " + $attempt + " 次点击开始按钮；日志: " + $todayLog + " 长度=" + $beforeLen)

    if (-not (Invoke-ClickAt -X $clickX -Y $clickY -What "一条龙开始按钮")) {
        Save-WindowScreenshot -Hwnd $script:BgiHwnd -Name "play-click-blocked" | Out-Null
        exit 8
    }

    $waitSeconds = [Math]::Max(12, [int]($ClickVerifySeconds / $attempts))
    $deadline = (Get-Date).AddSeconds($waitSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $todayLog = Get-TodayLogPath
        $chunk = Read-LogText -Path $todayLog -FromOffset $beforeLen
        if ($chunk.Text -and ($chunk.Text -match "启用一条龙配置|启用一条龙任务的数量|一条龙任务执行|一条龙和配置组任务结束")) {
            $started = $true
            Log ("日志确认一条龙已启动（新增日志 " + $chunk.Text.Length + " 字符）")
            break
        }
    }
    if (-not $started -and $attempt -lt $attempts) {
        Log "还没看到启动标记，2 秒后再点一次。" "WRN"
        Start-Sleep -Seconds 2
    }
}

if (-not $started) {
    Log "多次点击后日志里仍没有一条龙启动标记，任务可能没跑起来。" "ERR"
    Save-WindowScreenshot -Hwnd $script:BgiHwnd -Name "not-started" | Out-Null
    Write-UiaSnapshot -Root $root -Name "not-started"
    exit 9
}

# ---------------------------------------------------------------- 7.5 把原神切到前台
# BetterGI 在执行阶段要求「当前焦点窗口是原神」，否则每秒打印一次「不是原神，暂停」。
# 我们的脚本为了点按钮必须把 BetterGI 放前台，点完必须把前台还给游戏。
if ($FocusGameAfterStart) {
    $gameProc = $null
    $gameDeadline = (Get-Date).AddSeconds($GameWaitSeconds)
    while ((Get-Date) -lt $gameDeadline) {
        $gameProc = Get-GameWindow
        if ($gameProc) { break }
        Start-Sleep -Seconds 2
    }
    if ($gameProc) {
        Log ("把原神切到前台: PID " + $gameProc.Pid + " hwnd=" + $gameProc.Hwnd + " 尺寸=" + $gameProc.W + "x" + $gameProc.H)
        if (Set-WindowForeground -Hwnd $gameProc.Hwnd) { Log "原神已置于前台" }
        else { Log "无法把原神切到前台，BetterGI 可能会因焦点不在游戏而暂停。" "WRN" }
    } else {
        Log ("等了 " + $GameWaitSeconds + " 秒也没发现原神窗口（可能还在启动），跳过前台切换。") "WRN"
    }
}

# ---------------------------------------------------------------- 7.6 登录界面兜底：点「同意」
# 仅在 -AcceptPrivacyDialog 打开时生效。不是猜固定坐标：先在游戏画面里找那个粉色按钮，
# 找不到就不点，避免在游戏里乱点。
if ($AcceptPrivacyDialog) {
    Log ("开始检查登录界面的「同意」按钮（最多 " + $AcceptDialogSeconds + " 秒，最多点 3 次）")
    $agreeDeadline = (Get-Date).AddSeconds($AcceptDialogSeconds)
    $agreeClicks = 0
    # 记录日志基线：如果 BetterGI 已经进入「任务执行」阶段，说明游戏早就在主界面，不用再找「同意」按钮
    $agreeLogPath = Get-TodayLogPath
    $agreeLogOff = (Read-LogText -Path $agreeLogPath -FromOffset 0).Length
    while ((Get-Date) -lt $agreeDeadline -and $agreeClicks -lt 3) {
        $lgChunk = Read-LogText -Path $agreeLogPath -FromOffset $agreeLogOff
        if ($lgChunk.Length -lt $agreeLogOff) {
            # 日志被轮转/截断过：重置基线，绝不拿历史记录当新事件
            $agreeLogOff = $lgChunk.Length
        } else {
            $agreeLogOff = $lgChunk.Offset
            if ($lgChunk.Text -match "一条龙任务执行|配置组任务执行") {
                Log "BetterGI 日志显示已进入任务执行阶段，游戏已在主界面，提前结束「同意」检查。"
                break
            }
        }
        $gw = Get-GameWindow
        if (-not $gw) { Log "找不到原神窗口，结束「同意」检查。" "WRN"; break }
        $cr = Get-GameClientRect -Hwnd $gw.Hwnd
        if (-not $cr) { Log "取不到游戏客户区，结束「同意」检查。" "WRN"; break }
        $bmp = $null
        $hit = $null
        try {
            $bmp = New-Object System.Drawing.Bitmap($cr.W, $cr.H)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($cr.X, $cr.Y, 0, 0, $bmp.Size)
            $g.Dispose()
            $hit = [PinkFinder]::FindPinkAgreeButton($bmp)
        } catch {
            Log ("截取游戏画面失败: " + $_.Exception.Message) "WRN"
            $hit = $null
        }

        if ($hit) {
            $lcx = $hit[0] + [int]($hit[2] / 2)
            $lcy = $hit[1] + [int]($hit[3] / 2)
            $cx = $cr.X + $lcx
            $cy = $cr.Y + $lcy
            Log ("发现「同意」按钮: 局部=" + $hit[0] + "," + $hit[1] + " 尺寸=" + $hit[2] + "x" + $hit[3] + " -> 屏幕=" + $cx + "," + $cy)
            if ($bmp) {
                try { $bmp.Save((Join-Path $script:LogDir ("agree-" + (Get-Date).ToString("HHmmss") + ".png")), [System.Drawing.Imaging.ImageFormat]::Png) } catch { }
            }
            [void](Set-WindowForeground -Hwnd $gw.Hwnd)
            Start-Sleep -Milliseconds 300
            [void][BgiNative]::SetCursorPos($cx, $cy)
            Start-Sleep -Milliseconds 150
            [BgiNative]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 70
            [BgiNative]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
            $agreeClicks++
            Start-Sleep -Seconds 4
        } else {
            Start-Sleep -Seconds 6
        }
        if ($bmp) { $bmp.Dispose(); $bmp = $null }
    }

    if ($agreeClicks -gt 0) { Log ("共点击「同意」" + $agreeClicks + " 次") }
    else { Log "没检测到粉色「同意」按钮（游戏可能已进主界面，或不是隐私弹窗页）。" }

    $gw2 = Get-GameWindow
    if ($gw2) { [void](Set-WindowForeground -Hwnd $gw2.Hwnd) }
}
# ---------------------------------------------------------------- 8. 可选：等待任务结束 + 结束后睡眠
$waitMinutes = $WaitCompleteMinutes
if ($SleepAfterFinish -and $waitMinutes -le 0) { $waitMinutes = 240 }
$finished = $false
if ($waitMinutes -gt 0) {
    Log ("等待一条龙结束（最多 " + $waitMinutes + " 分钟）")
    $end = (Get-Date).AddMinutes($waitMinutes)
    $offset = $beforeLen
    while ((Get-Date) -lt $end) {
        Start-Sleep -Seconds 10
        $todayLog = Get-TodayLogPath
        $chunk = Read-LogText -Path $todayLog -FromOffset $offset
        if ($chunk.Text) {
            $offset = $chunk.Offset
            if ($chunk.Text -match "一条龙和配置组任务结束|一条龙结束汇总|一条龙结束|一条龙在启动阶段被取消|任务被取消，退出执行") {
                Log "检测到一条龙已结束。"
                $finished = $true
                break
            }
        }
        if (-not (Get-Process -Name $procName -ErrorAction SilentlyContinue)) {
            Log "BetterGI 进程已退出，视为一条龙结束。"
            $finished = $true
            break
        }
    }
    if (-not $finished) { Log ("等待超时（" + $waitMinutes + " 分钟），没看到结束标记。") "WRN" }
}

if ($SleepAfterFinish) {
    Log ("稍后让电脑进入睡眠（" + $SleepDelaySeconds + " 秒后），等待下一次定时唤醒")
    Start-Sleep -Seconds $SleepDelaySeconds
    # 关键：用一个独立进程发起睡眠，然后本脚本立刻退出。
    # 否则本进程会跟着系统一起挂起，第二天唤醒后它还活着，可能让计划任务「已有实例在运行」而拒绝启动。
    try {
        Start-Process -FilePath "rundll32.exe" -ArgumentList "powrprof.dll,SetSuspendState 0,1,0" -WindowStyle Hidden | Out-Null
        Log "已请求系统进入睡眠，本脚本随即退出"
    } catch { Log ("请求睡眠失败: " + $_.Exception.Message) "WRN" }
}

Log '===== 完成 ====='
if ($KeepDisplayOn) { try { [void][BgiNative]::SetThreadExecutionState($ES_CONTINUOUS) } catch { } }
exit 0
