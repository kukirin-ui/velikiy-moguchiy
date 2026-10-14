# Runs the Windows app for real on a Windows desktop (the CI runner) and checks
# it end to end. Needs an app built with the `smoke` feature; see
# .github/workflows/smoke-windows.yml and the "Смоук-тест" section of
# windows/README.md.
#
#   1. Startup: with HOME pointing at a fresh temporary folder and a prepared
#      config.yaml, the app starts, stays alive, adds its tray icon, installs the
#      keyboard hook and reads the settings from that config.
#   2. Dictation: Notepad in front, the dictation key held for a moment; the
#      app's fake microphone (a tone) streams to a local fake DashScope server,
#      which answers with a fixed phrase; the phrase must appear in Notepad.
#   3. Exit: WM_CLOSE to the app's hidden window; it must exit with code 0.
#
# Everything (config, logs, screenshots, the server's summary) goes to -Work.

param(
    [Parameter(Mandatory = $true)] [string] $Exe,
    [Parameter(Mandatory = $true)] [string] $Work,
    [int] $Port = 47321
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace Smoke -Name Win -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr FindWindowW(string cls, string title);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
[DllImport("user32.dll")]
public static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageW(IntPtr hwnd, uint msg, IntPtr w, System.Text.StringBuilder l);
[DllImport("user32.dll")]
public static extern IntPtr SendMessageW(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int GetClassNameW(IntPtr hwnd, System.Text.StringBuilder name, int max);
[DllImport("user32.dll")]
public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(IntPtr hwnd);
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hwnd, int cmd);
[DllImport("user32.dll")]
public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@

$WM_CLOSE = 0x0010
$WM_GETTEXT = 0x000D
$WM_GETTEXTLENGTH = 0x000E
$VK_F9 = 0x78
$VK_MENU = 0x12
$KEYEVENTF_KEYUP = 0x2

$FakeKey = 'smoke-fake-key-not-a-real-one'
$Expected = 'Проверка диктовки на Windows прошла успешно.'

New-Item -ItemType Directory -Force -Path $Work | Out-Null
$Work = (Resolve-Path $Work).Path
$Exe = (Resolve-Path $Exe).Path
$Home_ = Join-Path $Work 'home'
$DataDir = Join-Path $Home_ '.velikiy-moguchiy'
$Config = Join-Path $DataDir 'config.yaml'
$Report = Join-Path $Work 'report.json'
$Summary = Join-Path $Work 'fake_dashscope.json'
$RealDataDir = Join-Path $env:USERPROFILE '.velikiy-moguchiy'
$RealDataDirBefore = Test-Path $RealDataDir

$script:Shot = 0
function Save-Screenshot([string] $Name) {
    try {
        $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
        $script:Shot++
        $bmp.Save((Join-Path $Work ('{0:d2}-{1}.png' -f $script:Shot, $Name)))
        $g.Dispose(); $bmp.Dispose()
    } catch {
        Write-Host "screenshot '$Name' failed: $_"
    }
}

function Fail([string] $Message) {
    Save-Screenshot 'failure'
    Write-Host "::error::$Message"
    throw $Message
}

function Check([bool] $Ok, [string] $What) {
    if (-not $Ok) { Fail "FAILED: $What" }
    Write-Host "ok: $What"
}

function Wait-Until([scriptblock] $Condition, [int] $Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return [bool](& $Condition)
}

function Get-Text([IntPtr] $Hwnd) {
    $len = [Smoke.Win]::SendMessageW($Hwnd, $WM_GETTEXTLENGTH, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()
    $sb = New-Object System.Text.StringBuilder ($len + 1)
    [void][Smoke.Win]::SendMessageW($Hwnd, $WM_GETTEXT, [IntPtr]($len + 1), $sb)
    return $sb.ToString()
}

# The text area of Notepad: classic Notepad has an Edit child, the newer one a
# RichEdit control deeper down, so fall back to UI Automation for that one.
function Get-NotepadText([IntPtr] $Main) {
    $edit = [Smoke.Win]::FindWindowExW($Main, [IntPtr]::Zero, 'Edit', [NullString]::Value)
    if ($edit -ne [IntPtr]::Zero) { return Get-Text $edit }
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($Main)
    $doc = $root.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Document)))
    if ($null -eq $doc) { return '' }
    $pattern = $doc.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
    return $pattern.DocumentRange.GetText(-1)
}

$server = $null
$app = $null
$notepad = $null
try {
    # ---- Temporary home with a prepared config ---------------------------------
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    @"
# Written by the smoke test. Values differ from the defaults on purpose, so
# the report shows that the app read this file.
asr:
  provider: "qwen"
  qwen:
    url: "ws://127.0.0.1:$Port/api-ws/v1/realtime"
    api_key: "$FakeKey"
    model: "qwen3-asr-flash-realtime"
    language: "ru"
    connect_timeout_ms: 5000
hotkey:
  trigger_mode: "hold"
windows:
  trigger_key: "f9"
"@ | Set-Content -Path $Config -Encoding utf8NoBOM

    # ---- Fake DashScope -----------------------------------------------------------
    $server = Start-Process -FilePath 'python' -PassThru -NoNewWindow `
        -ArgumentList @((Join-Path $PSScriptRoot 'fake_dashscope.py'), '--port', $Port,
            '--key', $FakeKey, '--summary', $Summary) `
        -RedirectStandardOutput (Join-Path $Work 'fake_dashscope.out.log') `
        -RedirectStandardError (Join-Path $Work 'fake_dashscope.err.log')
    $listening = Wait-Until {
        $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
        $null -ne $c
    } 30
    Check $listening "fake DashScope listens on 127.0.0.1:$Port"

    # ---- 1. Startup -------------------------------------------------------------------
    $env:HOME = $Home_
    $env:VM_SMOKE_REPORT = $Report
    $app = Start-Process -FilePath $Exe -PassThru
    $null = $app.Handle  # keeps the exit code readable after the process ends
    Check (Wait-Until { Test-Path $Report } 60) 'the app wrote its startup report'
    $r = Get-Content $Report -Raw | ConvertFrom-Json
    Write-Host ($r | ConvertTo-Json)
    Check ($r.pid -eq $app.Id) 'the report comes from the launched process'
    Check ([bool]$r.core_started) 'the recognition core started'
    Check ([bool]$r.hook_installed) 'the keyboard hook is installed'
    Check ([bool]$r.tray_added) 'the tray icon was added (Shell_NotifyIcon NIM_ADD succeeded)'
    Check ([bool]$r.config_exists -and ((Resolve-Path $r.config_path).Path -eq $Config)) `
        'the config is the one in the temporary home'
    Check ($r.provider -eq 'qwen') 'provider from config: qwen'
    Check ($r.qwen_model -eq 'qwen3-asr-flash-realtime') 'model from config (not the default Omni)'
    Check ($r.qwen_language -eq 'ru') 'language from config'
    Check ($r.trigger_key -eq 'f9') 'dictation key from config: F9 (default is right Ctrl)'
    Check ($r.trigger_mode -eq 'hold') 'trigger mode from config'
    Check ([bool]$r.has_key -and $null -eq $r.setup_problem) 'the key is read, nothing to set up'

    $raw = Get-Content $Config -Raw
    Check (-not $raw.Contains($FakeKey)) 'the key is no longer in config.yaml in the clear'
    Check ($raw -match 'dashscope_keys:\s*["'']?[A-Za-z0-9+/=]{20,}') 'the key is sealed with DPAPI in config.yaml'
    Check ((Test-Path $RealDataDir) -eq $RealDataDirBefore) "the runner's own profile was not touched"

    $alive = -not (Wait-Until { $app.HasExited } 5)
    Check $alive 'the app is still running 5 s after start'
    $shell = [IntPtr]::Zero
    $found = Wait-Until {
        $h = [Smoke.Win]::FindWindowW('VelikiyMoguchiyShell', [NullString]::Value)
        $p = [uint32]0
        if ($h -ne [IntPtr]::Zero) { [void][Smoke.Win]::GetWindowThreadProcessId($h, [ref]$p) }
        $script:shell = $h
        $p -eq $app.Id
    } 10
    $shell = $script:shell
    Check $found 'the hidden window of the app exists'
    Save-Screenshot 'started'

    # ---- 2. Dictation into Notepad ------------------------------------------------
    Start-Process -FilePath 'notepad.exe'
    # The newer Notepad starts through a stub, so look the window up by name.
    $opened = Wait-Until {
        $script:notepad = Get-Process -Name 'notepad' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
        $null -ne $script:notepad
    } 30
    Check $opened 'Notepad opened'
    $notepad = $script:notepad
    $np = $notepad.MainWindowHandle
    $cls = New-Object System.Text.StringBuilder 256
    [void][Smoke.Win]::GetClassNameW($np, $cls, 256)
    Write-Host "Notepad: $($notepad.Path), window class $cls"
    $front = Wait-Until {
        if ([Smoke.Win]::GetForegroundWindow() -eq $np) { return $true }
        # A process may take the foreground only right after input of its own.
        [Smoke.Win]::keybd_event($VK_MENU, 0, 0, [UIntPtr]::Zero)
        [Smoke.Win]::keybd_event($VK_MENU, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
        [void][Smoke.Win]::ShowWindow($np, 9)
        [void][Smoke.Win]::SetForegroundWindow($np)
        Start-Sleep -Milliseconds 300
        [Smoke.Win]::GetForegroundWindow() -eq $np
    } 15
    Check $front 'Notepad is the foreground window'
    # Leave the menu bar if the Alt tap above opened it.
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
    Start-Sleep -Milliseconds 500

    [Smoke.Win]::keybd_event($VK_F9, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 1500
    Save-Screenshot 'recording'
    [Smoke.Win]::keybd_event($VK_F9, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)

    $script:text = ''
    $arrived = Wait-Until {
        $script:text = Get-NotepadText $np
        $script:text.Contains($Expected.TrimEnd('.'))
    } 20
    Save-Screenshot 'dictated'
    Write-Host "Notepad text: '$($script:text)'"
    try { Write-Host "Clipboard: '$(Get-Clipboard -Raw)'" } catch { }
    if (Test-Path $Summary) { Write-Host (Get-Content $Summary -Raw) }
    Check $arrived 'the dictated phrase arrived in Notepad'
    $s = Get-Content $Summary -Raw -Encoding utf8 | ConvertFrom-Json
    $session = @($s.sessions)[-1]
    Check ([bool]$session.auth_ok) 'the app sent the configured key (decrypted from DPAPI)'
    Check ($session.path -like '*model=qwen3-asr-flash-realtime*') 'the app asked for the configured model'
    Check ($session.audio_bytes -gt 16000) "the app streamed audio ($($session.audio_bytes) bytes)"
    Check ([bool]$session.finished) 'the app finished the session'
    Check (-not $app.HasExited) 'the app is still running after dictation'

    # ---- 3. Clean exit ----------------------------------------------------------------
    [void][Smoke.Win]::PostMessageW($shell, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    Check (Wait-Until { $app.HasExited } 20) 'the app exited after WM_CLOSE'
    $app.WaitForExit()
    Check ($app.ExitCode -eq 0) "exit code is 0 (got $($app.ExitCode))"
    Check ($null -eq (Get-Process -Id $app.Id -ErrorAction SilentlyContinue)) 'the process is gone'
    $log = Get-Content (Join-Path $DataDir 'logs\windows.log') -Raw
    Check ($log -match 'stopped') 'the log ends with a clean stop'
    Write-Host 'Smoke test passed.'
} finally {
    if ($null -ne $notepad -and -not $notepad.HasExited) { Stop-Process -Id $notepad.Id -Force }
    if ($null -ne $app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force }
    if ($null -ne $server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    $appLog = Join-Path $DataDir 'logs\windows.log'
    if (Test-Path $appLog) { Copy-Item $appLog (Join-Path $Work 'windows.log') }
}
