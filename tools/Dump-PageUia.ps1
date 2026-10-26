# Dump-PageUia.ps1
#
# 用途：把某个网页（通常是校园网认证页）在 UI Automation 树里的所有控件打印出来，
#       包含 类型 / 名字 / 矩形（物理像素）。适配新门户时用它来定位控件。
#
# 用法：
#   .\tools\Dump-PageUia.ps1 -Url "http://你的门户/login.jsp"
#   .\tools\Dump-PageUia.ps1 -Url "http://..." -OutFile ".\portal-uia.txt" -WindowTitleLike "Portal"
#
# 说明：
#   - 需要 Edge；脚本会用 msedge 打开该 URL。
#   - 不需要管理员权限（除非 Edge 本身以管理员运行）。
#   - 输出行格式：类型  y=.. x=.. w=.. h=..  off=True/False  name='..'
#   - 注意：Chromium 常把可见控件标成 off=True，不要用它判断可见性。

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$OutFile = "",
    [string]$WindowTitleLike = "Portal",
    [int]$WaitSeconds = 10,
    [switch]$NoMaximize
)

$ErrorActionPreference = 'Stop'

if (-not $OutFile) {
    $base = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { (Get-Location).Path }
    $OutFile = Join-Path $base 'portal-uia.txt'
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class DumpUiNative {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
}
'@ -ErrorAction SilentlyContinue

try { [void][DumpUiNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }

function Write-Out {
    param([string]$Text)
    $Text | Out-File -Append -FilePath $OutFile -Encoding utf8
    Write-Host $Text
}

"=== Dump-PageUia ===" | Out-File -FilePath $OutFile -Encoding utf8
Write-Out ('time   = ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Write-Out ('url    = ' + $Url)

Write-Out 'opening Edge ...'
Start-Process 'msedge.exe' -ArgumentList $Url
Start-Sleep -Seconds $WaitSeconds

$pids = @(Get-Process msedge -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
$script:target = $null
$cb = [DumpUiNative+EnumProc] {
    param($h, $l)
    $p = [uint32]0
    [void][DumpUiNative]::GetWindowThreadProcessId($h, [ref]$p)
    if ($pids -contains [int]$p -and [DumpUiNative]::IsWindowVisible($h)) {
        $sb = New-Object System.Text.StringBuilder 512
        [void][DumpUiNative]::GetWindowText($h, $sb, 512)
        $t = $sb.ToString()
        if ($t -and ($WindowTitleLike -eq '' -or $t.Contains($WindowTitleLike))) {
            $script:target = @{ H = $h; T = $t }
        }
    }
    return $true
}
[void][DumpUiNative]::EnumWindows($cb, [IntPtr]::Zero)

if (-not $script:target) {
    Write-Out ('!! 没找到标题包含 ' + $WindowTitleLike + ' 的 Edge 窗口。')
    Write-Out '   请确认页面已经打开，或用 -WindowTitleLike 指定标题关键字。'
    exit 1
}
Write-Out ('window = ' + $script:target.T)

if (-not $NoMaximize) {
    [void][DumpUiNative]::ShowWindow($script:target.H, 9)
    Start-Sleep -Milliseconds 700
    [void][DumpUiNative]::ShowWindow($script:target.H, 3)
    Start-Sleep -Seconds 2
}
[void][DumpUiNative]::SetForegroundWindow($script:target.H)
Start-Sleep -Seconds 2

$root = [System.Windows.Automation.AutomationElement]::FromHandle($script:target.H)
if (-not $root) { Write-Out '!! 读不到 UIA 根元素'; exit 2 }

$all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                     [System.Windows.Automation.Condition]::TrueCondition)
Write-Out ('elements = ' + $all.Count)
Write-Out ''

foreach ($e in $all) {
    try {
        $c = $e.Current
        $r = $c.BoundingRectangle
        if ($r.Width -le 0 -or $r.Height -le 0) { continue }
        $t = $c.ControlType.ProgrammaticName -replace 'ControlType\.', ''
        $line = $t.PadRight(11) + ' y=' + ([int]$r.Y).ToString().PadLeft(5) +
                ' x=' + ([int]$r.X).ToString().PadLeft(5) +
                ' w=' + ([int]$r.Width).ToString().PadLeft(4) +
                ' h=' + ([int]$r.Height).ToString().PadLeft(4) +
                '  off=' + $c.IsOffscreen.ToString().PadRight(6) +
                " name='" + $c.Name + "'"
        Write-Out $line
    } catch { }
}

Write-Out ''
Write-Out '=== done ==='
Write-Host ''
Write-Host ('结果已写入: ' + $OutFile) -ForegroundColor Green
Write-Host '提示：Chromium 常把可见控件标成 off=True，判断可见性请看矩形而不是 off 字段。' -ForegroundColor DarkGray
