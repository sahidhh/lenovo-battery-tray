# System tray indicator + hotkeys for Lenovo battery charge mode, with Lenovo ITS power mode (Fn+Q).
#   Conservation = green seedling (taskbar), RapidCharge = yellow bolt (taskbar), Normal = grey heart (overflow).
#   Power mode  = gauge icon (needle = ITS mode), also in tooltip and menu. Menu items set it; hotkey cycles it (F3.9).
# Left-click: toggle Conservation. Right-click: Win11-styled menu (re-reads state on open). Hover: tooltip w/ keycaps.
#
#   lenovo-battery-tray.ps1 [-Config <path>] [-Preview] [-SelfTest [-InvokePowerStep]] [-FakeNoPowerMode]
#     -Config          config.json path (default %LOCALAPPDATA%\lenovo-battery-tray\config.json, SPEC §8)
#     -Preview         renders the glyphs to a PNG and opens it.
#     -SelfTest        build UI + run detection, print one "selftest ok ..." line, exit 0 (no message loop).
#     -InvokePowerStep with -SelfTest: run one power-step through the tray handler, print "stepped=<from>-><to>".
#     -FakeNoPowerMode test only: pretend the LITSSVC key is absent (power-mode UI hidden).
#
# Push-driven: RegisterHotKey for hotkeys, RegNotifyChangeKeyValue on the ITS registry key for Fn+Q,
# menu Opening for Vantage-side battery changes. No polling unless pollSeconds > 0.
param([switch]$Preview, [switch]$MenuShot, [switch]$SelfTest, [switch]$InvokePowerStep, [switch]$FakeNoPowerMode, [string]$Config)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

. "$PSScriptRoot\lenovo-battery.ps1"

# SPEC §10: driver missing -> one message box, exit 1 (error number is informational only, F2.5)
$drvErr = [EnergyDrv]::TryOpen()
if ($drvErr -ne 0) {
    [void][System.Windows.Forms.MessageBox]::Show("Lenovo Energy driver not found (error $drvErr). This tool needs a Lenovo consumer laptop with the ACPI\VPC2004 driver.", 'Lenovo battery tray', 'OK', 'Error')
    exit 1
}

# ---------------------------------------------------------------- config (F4.5) + detection
$CfgResult = if ($Config) { Get-Config -Path $Config } else { Get-Config }
$Cfg = $CfgResult.config
$Hotkeys           = $Cfg.hotkeys
$PollSeconds       = [int]$Cfg.pollSeconds     # 0 = off. Safety-net poll for battery changes made inside Vantage.
$ShowPowerModeIcon = [bool]$Cfg.showPowerModeIcon   # gauge tray icon. Windows groups tray icons by process, so it
                              # can't sit in overflow while the battery icon stays in the taskbar - they move
                              # together. Off by default; power mode still shows in the tooltip and menu.
$PowerLabels = $Cfg.powerMode.labels   # keyed Auto/Cool/Performance
$PowerGlyphs = $Cfg.powerMode.glyphs
$GaugeKinds  = 'GaugeEff', 'GaugeBal', 'GaugePerf'
$HotkeyActions = 'toggle-conservation', 'toggle-rapid', 'power-step'

$Caps = Get-Caps                                                              # F2.4
$HasPowerMode = (-not $FakeNoPowerMode) -and ($null -ne (Get-PowerMode))      # F3.8: key absent -> no power UI
$PowerCaps = if ($HasPowerMode) { Get-PowerCaps } else { $null }
$ItsKey = $PowerKey -replace '^HKLM:\\', ''                                   # F3.1, for RegNotifyChangeKeyValue
$VantageAppId = $null                                                         # F4.4: resolve at runtime
$vantagePkg = Get-AppxPackage -Name E046963F.LenovoCompanion -ErrorAction SilentlyContinue
if ($vantagePkg) { $VantageAppId = $vantagePkg.PackageFamilyName + '!App' }

# Fluent palette
$Colors = @{
    Conservation = [System.Drawing.Color]::FromArgb(108, 203, 95)
    RapidCharge  = [System.Drawing.Color]::FromArgb(252, 225, 0)
    Normal       = [System.Drawing.Color]::FromArgb(138, 138, 138)
    NormalLight  = [System.Drawing.Color]::FromArgb(106, 106, 106)   # heart on a light taskbar
    Gauge        = [System.Drawing.Color]::FromArgb(76, 194, 255)
    GaugeLight   = [System.Drawing.Color]::FromArgb(0, 103, 192)
}
# ----------------------------------------------------------------

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Runtime.InteropServices; using System.Windows.Forms;
// Message-only window: receives WM_HOTKEY; relays registry-change notifications (worker thread) onto the UI thread.
public class TrayNative : NativeWindow, IDisposable {
    const int WM_HOTKEY = 0x0312, WM_APP_REG = 0x8002;
    public event Action<int> HotKey;
    public event Action RegistryChanged;
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegOpenKeyExW(IntPtr hKey, string sub, int opt, int sam, out IntPtr res);
    [DllImport("advapi32.dll")] static extern int RegNotifyChangeKeyValue(IntPtr hKey, bool subtree, int filter, IntPtr evt, bool async);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    [StructLayout(LayoutKind.Sequential)] struct NOTIFYICONIDENTIFIER { public int cbSize; public IntPtr hWnd; public uint uID; public Guid guidItem; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("shell32.dll")] static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER id, out RECT rc);
    int _ids = 0;
    public TrayNative() { CreateParams cp = new CreateParams(); cp.Parent = (IntPtr)(-3); CreateHandle(cp); }   // HWND_MESSAGE
    public int Register(uint mod, uint vk) { int id = ++_ids; if (!RegisterHotKey(Handle, id, mod | 0x4000, vk)) return -Marshal.GetLastWin32Error(); return id; }
    public void WatchHklm(string subKey) {
        IntPtr hk; if (RegOpenKeyExW(new IntPtr(unchecked((int)0x80000002)), subKey, 0, 0x20019, out hk) != 0) return;   // KEY_READ
        System.Threading.Thread t = new System.Threading.Thread(delegate() {
            while (RegNotifyChangeKeyValue(hk, false, 0x4, IntPtr.Zero, false) == 0) PostMessage(Handle, WM_APP_REG, IntPtr.Zero, IntPtr.Zero);   // REG_NOTIFY_CHANGE_LAST_SET, blocking
        });
        t.IsBackground = true; t.Start();
    }
    public static Rectangle IconRect(IntPtr hwnd, int id) {
        NOTIFYICONIDENTIFIER n = new NOTIFYICONIDENTIFIER(); n.cbSize = Marshal.SizeOf(typeof(NOTIFYICONIDENTIFIER)); n.hWnd = hwnd; n.uID = (uint)id;
        RECT r; if (Shell_NotifyIconGetRect(ref n, out r) != 0) return Rectangle.Empty;
        return Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
    }
    public static void RoundCorners(IntPtr hwnd) { int v = 2; DwmSetWindowAttribute(hwnd, 33, ref v, 4); }   // DWMWA_WINDOW_CORNER_PREFERENCE = ROUND
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY) { Action<int> h = HotKey; if (h != null) h((int)m.WParam); }
        else if (m.Msg == WM_APP_REG) { Action r = RegistryChanged; if (r != null) r(); }
        base.WndProc(ref m);
    }
    public void Dispose() { for (int i = 1; i <= _ids; i++) UnregisterHotKey(Handle, i); DestroyHandle(); }
}
// Borderless popup that never steals focus (native NotifyIcon tooltip can't be styled).
public class TipForm : Form {
    public TipForm() { FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual; }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams { get { CreateParams p = base.CreateParams; p.ExStyle |= 0x08000080; return p; } }  // NOACTIVATE | TOOLWINDOW
}
// Windows 11 style context menu: flat surface, rounded hover, accent pill for the selected item, small grey headers/shortcuts.
public class Win11Renderer : ToolStripProfessionalRenderer {
    public bool Dark = true; public float Scale = 1f; public Color Accent = Color.FromArgb(76, 194, 255);
    Color Bg    { get { return Dark ? Color.FromArgb(44, 44, 44)    : Color.FromArgb(249, 249, 249); } }
    Color Fg    { get { return Dark ? Color.White                   : Color.FromArgb(26, 26, 26); } }
    Color Muted { get { return Dark ? Color.FromArgb(160, 160, 160) : Color.FromArgb(96, 96, 96); } }
    Color Hover { get { return Dark ? Color.FromArgb(58, 58, 58)    : Color.FromArgb(234, 234, 234); } }
    Color Line  { get { return Dark ? Color.FromArgb(64, 64, 64)    : Color.FromArgb(215, 215, 215); } }
    public Win11Renderer() { RoundedEdges = false; }
    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) { using (SolidBrush b = new SolidBrush(Bg)) e.Graphics.FillRectangle(b, e.AffectedBounds); }
    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) { using (Pen p = new Pen(Line)) e.Graphics.DrawRectangle(p, 0, 0, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1); }
    protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) { }
    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
        int y = e.Item.Height / 2, m = (int)(8 * Scale);
        using (Pen p = new Pen(Line)) e.Graphics.DrawLine(p, m, y, e.Item.Width - m, y);
    }
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        Graphics g = e.Graphics; g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        ToolStripMenuItem it = e.Item as ToolStripMenuItem; string tag = e.Item.Tag as string;
        int m = (int)(4 * Scale); Rectangle r = new Rectangle(m, 1, e.Item.Width - 2 * m, e.Item.Height - 2);
        bool hoverable = e.Item.Enabled && tag != "header" && tag != "readonly";
        if (e.Item.Selected && hoverable) using (SolidBrush b = new SolidBrush(Hover)) FillRound(g, b, r, (int)(5 * Scale));
        if (it != null && it.Checked) {
            // Win11 selection indicator: short rounded accent bar in the left gutter, clear of the text column
            int ph = (int)(e.Item.Height * 0.42); Rectangle pill = new Rectangle((int)(7 * Scale), (e.Item.Height - ph) / 2, (int)(3 * Scale), ph);
            using (SolidBrush b = new SolidBrush(Accent)) FillRound(g, b, pill, (int)(1.5 * Scale));
        }
    }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        ToolStripMenuItem it = e.Item as ToolStripMenuItem; string tag = e.Item.Tag as string;
        bool isShortcut = it != null && !string.IsNullOrEmpty(it.ShortcutKeyDisplayString) && e.Text == it.ShortcutKeyDisplayString;
        Font f = e.TextFont; Color c = Fg; string text = e.Text;
        Rectangle tr = e.TextRectangle;
        TextFormatFlags flags = TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix;
        if (isShortcut) {   // right-aligned shortcut column, vertically centered against the label
            f = new Font(f.FontFamily, f.Size * 0.82f); c = Muted; flags |= TextFormatFlags.Right;
            tr = new Rectangle(e.TextRectangle.X, e.Item.ContentRectangle.Top, e.TextRectangle.Width, e.Item.ContentRectangle.Height);
        } else {            // label / header: position text ourselves so it clears the accent gutter (WinForms ignores Padding.Left here)
            int gutter = (int)(20 * Scale);
            tr = new Rectangle(gutter, e.Item.ContentRectangle.Top, e.Item.Width - gutter - (int)(12 * Scale), e.Item.ContentRectangle.Height);
            flags |= TextFormatFlags.Left;
            if (tag == "header") { f = new Font(f.FontFamily, f.Size * 0.76f); c = Muted; text = text.ToUpperInvariant(); }
            else if (!e.Item.Enabled) c = Muted;
        }
        TextRenderer.DrawText(e.Graphics, text, f, tr, c, flags);
    }
    static void FillRound(Graphics g, Brush b, Rectangle r, int rad) {
        if (rad < 1) { g.FillRectangle(b, r); return; }
        using (System.Drawing.Drawing2D.GraphicsPath p = new System.Drawing.Drawing2D.GraphicsPath()) {
            int d = rad * 2; p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90); p.CloseFigure(); g.FillPath(b, p);
        }
    }
}
'@

# DPI-aware so SmallIconSize reports the real pixel size (16@100%, 48@300%); drawing at exactly that size keeps icons sharp.
Add-Type -Namespace W -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][W.Dpi]::SetProcessDPIAware()
$IconPx = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
$Scale = $IconPx / 16

$PersonalizeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
function Test-LightTaskbar { try { (Get-ItemProperty $PersonalizeKey -ErrorAction Stop).SystemUsesLightTheme -eq 1 } catch { $false } }
function Test-LightApps    { try { (Get-ItemProperty $PersonalizeKey -ErrorAction Stop).AppsUseLightTheme -eq 1 } catch { $false } }

# ---------------------------------------------------------------- glyphs (16x16 design grid, vector)
function Draw-Glyph([string]$Kind, [System.Drawing.Color]$Color, [int]$Px = $IconPx) {
    $bmp = New-Object System.Drawing.Bitmap $Px, $Px
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.ScaleTransform($Px / 16, $Px / 16)
    $brush = New-Object System.Drawing.SolidBrush $Color
    $pen = New-Object System.Drawing.Pen $Color, 1.6; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $P = { param($x, $y) [System.Drawing.PointF]::new($x, $y) }
    switch ($Kind) {
        'Conservation' {
            $g.DrawLine($pen, 8, 15, 8, 8)
            $p = New-Object System.Drawing.Drawing2D.GraphicsPath; $p.AddBezier(8, 8, 8, 3, 4, 1, 1, 2); $p.AddBezier(1, 2, 1, 6, 4, 8, 8, 8); $g.FillPath($brush, $p)
            $p = New-Object System.Drawing.Drawing2D.GraphicsPath; $p.AddBezier(8, 9, 8, 5, 11, 3, 15, 4); $p.AddBezier(15, 4, 14, 8, 11, 9, 8, 9); $g.FillPath($brush, $p)
        }
        'RapidCharge' { $g.FillPolygon($brush, [System.Drawing.PointF[]]@((& $P 9.5 0), (& $P 2.5 9), (& $P 7 9), (& $P 5.5 16), (& $P 13.5 6), (& $P 9 6), (& $P 11 0))) }
        'Normal' { $p = New-Object System.Drawing.Drawing2D.GraphicsPath; $p.AddBezier(8, 14, 1, 9, 1, 2, 8, 5); $p.AddBezier(8, 5, 15, 2, 15, 9, 8, 14); $g.FillPath($brush, $p) }
        { $_ -like 'Gauge*' } {   # GaugeEff / GaugeBal / GaugePerf
            $pen.Width = 1.4; $g.DrawArc($pen, 1.5, 5.5, 13, 13, 180, 180)
            # needle sweeps low(left) -> high(right): GaugeEff=low=left, GaugeBal=mid=up, GaugePerf=high=right
            switch ($Kind) { 'GaugeEff' { $g.DrawLine($pen, 8, 12, 4, 9) } 'GaugeBal' { $g.DrawLine($pen, 8, 12, 8, 7) } 'GaugePerf' { $g.DrawLine($pen, 8, 12, 12, 9) } }
            $g.FillEllipse($brush, 6.6, 10.6, 2.8, 2.8)
        }
    }
    $g.Dispose(); $bmp
}
function New-Icon([string]$Kind, [System.Drawing.Color]$Color) { [System.Drawing.Icon]::FromHandle((Draw-Glyph $Kind $Color).GetHicon()) }

if ($Preview) {
    $kinds = 'Conservation', 'RapidCharge', 'Normal', 'GaugeEff', 'GaugeBal', 'GaugePerf'
    $cell = 120; $sheet = New-Object System.Drawing.Bitmap ($kinds.Count * $cell), ($cell + 30)
    $g = [System.Drawing.Graphics]::FromImage($sheet); $g.Clear([System.Drawing.Color]::FromArgb(32, 32, 32))
    $f = New-Object System.Drawing.Font 'Segoe UI', ([single]9); $i = 0
    foreach ($k in $kinds) {
        $c = if ($k -like 'Gauge*') { $Colors.Gauge } else { $Colors[$k] }
        $g.DrawString($k, $f, [System.Drawing.Brushes]::White, $i * $cell + 8, 4); $g.DrawImage((Draw-Glyph $k $c 64), $i * $cell + 28, 40); $i++
    }
    $out = "$env:TEMP\lenovo-battery-icons.png"; $sheet.Save($out); Invoke-Item $out; return
}

# ---------------------------------------------------------------- state
$Icons = @{ Conservation = New-Icon Conservation $Colors.Conservation; RapidCharge = New-Icon RapidCharge $Colors.RapidCharge }
function Update-ThemeIcons {
    $light = Test-LightTaskbar
    $Icons.Normal = New-Icon Normal $(if ($light) { $Colors.NormalLight } else { $Colors.Normal })
    $gc = if ($light) { $Colors.GaugeLight } else { $Colors.Gauge }
    $Icons.GaugeEff = New-Icon GaugeEff $gc; $Icons.GaugeBal = New-Icon GaugeBal $gc; $Icons.GaugePerf = New-Icon GaugePerf $gc
}
Update-ThemeIcons
$script:BatMode = $null
$script:PowerName = $null            # Auto | Cool | Performance | Unknown(n) (core name, F3.2)
$script:Its = @('', 'GaugeBal')      # display: label, gauge glyph
# label/glyph from config for known names; anything else -> "Mode N" + GaugeBal
function Get-PowerDisplay([string]$Name) {
    if ($Name -and $PowerLabels.ContainsKey($Name)) {
        $glyph = [string]$PowerGlyphs[$Name]
        if ($glyph -notin $GaugeKinds) { $glyph = 'GaugeBal' }
        return @([string]$PowerLabels[$Name], $glyph)
    }
    $n = if ($Name -match '\((-?\d+)\)') { $Matches[1] } else { '?' }
    return @("Mode $n", 'GaugeBal')
}
function Read-Its {
    if (-not $HasPowerMode) { return }
    $script:PowerName = Get-PowerMode
    $script:Its = Get-PowerDisplay $script:PowerName
}
Read-Its

# ---------------------------------------------------------------- tray icons
# Separate NotifyIcon instances on purpose: Windows remembers taskbar-vs-overflow placement per icon identity
# (HKCU\Control Panel\NotifyIconSettings). Creation order = identity, don't reorder.
$trayActive = New-Object System.Windows.Forms.NotifyIcon     # #1 promoted: seedling / bolt
$trayNormal = New-Object System.Windows.Forms.NotifyIcon     # #2 overflow: heart
$trayPower  = New-Object System.Windows.Forms.NotifyIcon     # #3 gauge
foreach ($t in $trayActive, $trayNormal, $trayPower) { $t.Text = '' }   # empty = no native tooltip (we draw our own)

function Update-Tray {
    try { $m = Get-Mode } catch { return }
    $script:BatMode = $m
    if ($m -eq 'Normal') {
        $trayNormal.Icon = $Icons.Normal
        if (-not $trayNormal.Visible) { $trayActive.Visible = $false; $trayNormal.Visible = $true }
    } else {
        $trayActive.Icon = $Icons[$m]
        if (-not $trayActive.Visible) { $trayNormal.Visible = $false; $trayActive.Visible = $true }
    }
    if ($ShowPowerModeIcon -and $HasPowerMode) { $trayPower.Icon = $Icons[$script:Its[1]]; $trayPower.Visible = $true }
}
function Show-Balloon([string]$Text, [int]$Ms = 3000) {
    $ni = if ($trayActive.Visible) { $trayActive } else { $trayNormal }
    if (-not $ni.Visible) { Write-Warning $Text; return }
    $ni.BalloonTipTitle = 'Lenovo battery'; $ni.BalloonTipText = $Text; $ni.ShowBalloonTip($Ms)
}
# SPEC §10: Set-Mode $false -> balloon, icon stays on the real (unchanged) state, mirror untouched (core)
function Invoke-SetMode([string]$Target) {
    $ok = $false
    try { $ok = Set-Mode -Mode $Target } catch { Write-Warning $_.Exception.Message }
    if (-not $ok) { Show-Balloon "Firmware ignored $Target. Run: lenovo-battery.ps1 diag" }
    Update-Tray
}
function Invoke-Toggle([string]$Special) { if ((Get-Mode) -eq $Special) { Invoke-SetMode Normal } else { Invoke-SetMode $Special } }
# Re-read ITS state and sync every power-mode surface (gauge icon, menu checks, tooltip). Called from the registry
# watch (external Fn+Q, F3.6) and after our own writes; it never shows a balloon, so an own write that also fires
# the watch cannot double-balloon.
function Update-PowerUi {
    Read-Its
    if ($ShowPowerModeIcon -and $trayPower.Visible) { $trayPower.Icon = $Icons[$script:Its[1]] }
    foreach ($v in $miIts.Keys) { $miIts[$v].Checked = ($v -eq $script:PowerName) }
    if ($tip.Visible) { $tip.Invalidate() }
}
# SPEC §10: Set-PowerMode $false -> balloon, UI stays on the real (unchanged) state
function Invoke-SetPowerMode([string]$Target) {
    $ok = $false
    try { $ok = Set-PowerMode -Mode $Target } catch { Write-Warning $_.Exception.Message }
    if (-not $ok) { Show-Balloon 'Power mode change ignored. Run: lenovo-battery.ps1 diag' }
    Update-PowerUi
    return $ok
}
# hotkey cycle (F3.9); Fn+Q has no OSD without Vantage, so the balloon is the only feedback. Returns @(from, to).
function Invoke-PowerStep {
    $from = $script:PowerName
    $next = $null
    try { $next = Step-PowerMode } catch { Write-Warning $_.Exception.Message }
    Update-PowerUi
    if ($next) { Show-Balloon "Power mode: $($script:Its[0])" 1500 } else { Show-Balloon 'Power mode change ignored. Run: lenovo-battery.ps1 diag' }
    return @($from, $script:PowerName)
}

# ---------------------------------------------------------------- tooltip (custom, keycaps, anchored above icon)
$tip = New-Object TipForm
$tipFont = New-Object System.Drawing.Font 'Segoe UI', ([single]9)
$tipKeyFont = New-Object System.Drawing.Font 'Segoe UI', ([single]7.5), ([System.Drawing.FontStyle]::Bold)
$HotkeyLabel = @{}; foreach ($k in $Hotkeys.Keys) { $HotkeyLabel[$Hotkeys[$k]] = $k.Split('+') }
function Get-TipTheme {
    if (Test-LightApps) { @{ Bg = [System.Drawing.Color]::FromArgb(249, 249, 249); Fg = [System.Drawing.Color]::FromArgb(26, 26, 26); Line = [System.Drawing.Color]::FromArgb(215, 215, 215); KcBg = [System.Drawing.Color]::FromArgb(232, 232, 232); KcLine = [System.Drawing.Color]::FromArgb(200, 200, 200); KcFg = [System.Drawing.Color]::FromArgb(70, 70, 70) } }
    else { @{ Bg = [System.Drawing.Color]::FromArgb(44, 44, 44); Fg = [System.Drawing.Color]::White; Line = [System.Drawing.Color]::FromArgb(64, 64, 64); KcBg = [System.Drawing.Color]::FromArgb(58, 58, 58); KcLine = [System.Drawing.Color]::FromArgb(90, 90, 90); KcFg = [System.Drawing.Color]::FromArgb(207, 207, 207) } }
}
function Get-TipLines {
    $bk = switch ($script:BatMode) { 'Conservation' { $HotkeyLabel['toggle-conservation'] } 'RapidCharge' { $HotkeyLabel['toggle-rapid'] } default { $null } }
    $bl = switch ($script:BatMode) { 'RapidCharge' { 'Rapid charge' } default { $script:BatMode } }
    $lines = New-Object System.Collections.ArrayList   # of @(label, keys); ArrayList so PS doesn't unroll a single line
    [void]$lines.Add(@("Battery: $bl", $bk))
    if ($HasPowerMode) { [void]$lines.Add(@("Power: $($script:Its[0])", @('Fn', 'Q'))) }
    return , $lines
}
function Measure-Keycap($g, $k) { [math]::Max($g.MeasureString($k, $tipKeyFont).Width + 4 * $Scale, 16 * $Scale) }
$tip.add_Paint({
    $g = $_.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
    $th = Get-TipTheme; $pad = 10 * $Scale; $gap = 4 * $Scale; $y = $pad
    $text = New-Object System.Drawing.SolidBrush $th.Fg
    $kcFill = New-Object System.Drawing.SolidBrush $th.KcBg; $kcPen = New-Object System.Drawing.Pen $th.KcLine, (1 * $Scale)
    $kcBottom = New-Object System.Drawing.Pen $th.KcLine, (2 * $Scale); $kcText = New-Object System.Drawing.SolidBrush $th.KcFg
    $g.DrawRectangle((New-Object System.Drawing.Pen $th.Line), 0, 0, $tip.Width - 1, $tip.Height - 1)
    foreach ($ln in (Get-TipLines)) {
        $label, $keys = $ln
        $lh = $g.MeasureString($label, $tipFont).Height
        $g.DrawString($label, $tipFont, $text, $pad, $y)
        if ($keys) {
            $kw = @(); foreach ($k in $keys) { $kw += Measure-Keycap $g $k }
            $kh = $g.MeasureString('X', $tipKeyFont).Height + 1 * $Scale
            $x = $tip.Width - $pad - (($kw | Measure-Object -Sum).Sum + ($keys.Count - 1) * 3 * $Scale)
            $ky = $y + ($lh - $kh) / 2
            for ($i = 0; $i -lt $keys.Count; $i++) {
                $r = New-Object System.Drawing.RectangleF $x, $ky, $kw[$i], $kh
                $g.FillRectangle($kcFill, $r); $g.DrawRectangle($kcPen, $r.X, $r.Y, $r.Width, $r.Height); $g.DrawLine($kcBottom, $r.X, $r.Bottom, $r.Right, $r.Bottom)
                $sz = $g.MeasureString($keys[$i], $tipKeyFont)
                $g.DrawString($keys[$i], $tipKeyFont, $kcText, $r.X + ($r.Width - $sz.Width) / 2, $r.Y + ($r.Height - $sz.Height) / 2)
                $x += $kw[$i] + 3 * $Scale
            }
        }
        $y += $lh + $gap
    }
})
$NotifyIconWindow = [System.Windows.Forms.NotifyIcon].GetField('window', 'NonPublic,Instance')
$NotifyIconId     = [System.Windows.Forms.NotifyIcon].GetField('id', 'NonPublic,Instance')
function Get-IconRect($ni) { [TrayNative]::IconRect($NotifyIconWindow.GetValue($ni).Handle, [int]$NotifyIconId.GetValue($ni)) }
function Show-Tip($ni) {
    if ($menu.Visible) { return }                                       # never cover the open context menu
    if ($tip.Visible) { $tipTimer.Stop(); $tipTimer.Start(); return }   # already up: just keep it alive, no re-render
    $tip.BackColor = (Get-TipTheme).Bg
    $g = $tip.CreateGraphics(); $pad = 10 * $Scale; $w = 0; $h = $pad
    foreach ($ln in (Get-TipLines)) {
        $label, $keys = $ln
        $s = $g.MeasureString($label, $tipFont); $lw = $s.Width
        if ($keys) { $lw += 14 * $Scale; foreach ($k in $keys) { $lw += (Measure-Keycap $g $k) + 3 * $Scale } }
        $w = [math]::Max($w, $lw); $h += $s.Height + 4 * $Scale
    }
    $g.Dispose()
    $tip.Size = New-Object System.Drawing.Size ([int]($w + 2 * $pad)), ([int]($h + $pad - 4 * $Scale))
    $rc = Get-IconRect $ni
    if ($rc.IsEmpty) { $c = [System.Windows.Forms.Control]::MousePosition; $rc = New-Object System.Drawing.Rectangle ($c.X - 16), ($c.Y - 16), 32, 32 }
    $wa = [System.Windows.Forms.Screen]::FromRectangle($rc).WorkingArea
    $x = [math]::Min([math]::Max($rc.X + $rc.Width / 2 - $tip.Width / 2, $wa.Left), $wa.Right - $tip.Width)
    $y = $rc.Y - $tip.Height - 6 * $Scale; if ($y -lt $wa.Top) { $y = $rc.Bottom + 6 * $Scale }
    $tip.Location = New-Object System.Drawing.Point ([int]$x), ([int]$y)
    $tip.Show(); [TrayNative]::RoundCorners($tip.Handle); $tip.Invalidate()
    $tipTimer.Stop(); $tipTimer.Start()
}
$tipTimer = New-Object System.Windows.Forms.Timer; $tipTimer.Interval = 700   # no MouseMove for 700ms = mouse left
$tipTimer.add_Tick({ $tipTimer.Stop(); $tip.Hide() })
function Hide-Tip { $tipTimer.Stop(); $tip.Hide() }

# ---------------------------------------------------------------- menu (Win11 look)
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.ShowImageMargin = $false; $menu.ShowCheckMargin = $false
$menu.Font = New-Object System.Drawing.Font 'Segoe UI', ([single]9.5)
$renderer = New-Object Win11Renderer; $renderer.Scale = $Scale; $renderer.Accent = $Colors.Gauge
$menu.Renderer = $renderer
$menu.Padding = New-Object System.Windows.Forms.Padding ([int](4 * $Scale))
# left padding leaves a clear gutter for the accent bar so it never touches text; headers share it so everything left-aligns
$ItemPad = New-Object System.Windows.Forms.Padding ([int](22 * $Scale)), ([int](6 * $Scale)), ([int](22 * $Scale)), ([int](6 * $Scale))
$HeaderPad = New-Object System.Windows.Forms.Padding ([int](22 * $Scale)), ([int](7 * $Scale)), ([int](22 * $Scale)), ([int](1 * $Scale))
function Add-Header([string]$t) { $h = $menu.Items.Add($t); $h.Tag = 'header'; $h.Enabled = $false; $h.Padding = $HeaderPad; $h }
function Add-Item([string]$t, [scriptblock]$on, [string]$shortcut, [string]$tag) {
    $i = $menu.Items.Add($t, $null, $on); $i.Padding = $ItemPad
    if ($shortcut) { $i.ShortcutKeyDisplayString = $shortcut }; if ($tag) { $i.Tag = $tag }; $i
}
[void](Add-Header 'Battery charging')
$miBattery = @{}
foreach ($m in 'Conservation', 'RapidCharge', 'Normal') {
    if ($m -eq 'RapidCharge' -and -not $Caps.rapid) { continue }   # SPEC §10 / F2.2: no rapid support -> no item
    $label = if ($m -eq 'RapidCharge') { 'Rapid charge' } else { $m }
    $sc = switch ($m) { 'Conservation' { ($HotkeyLabel['toggle-conservation'] -join '+') } 'RapidCharge' { ($HotkeyLabel['toggle-rapid'] -join '+') } default { $null } }
    $miBattery[$m] = Add-Item $label { Invoke-SetMode $this.Name } $sc $null
    $miBattery[$m].Name = $m
}
$miIts = @{}
if ($HasPowerMode) {   # F3.8: whole section absent without LITSSVC
    [void]$menu.Items.Add('-')
    [void](Add-Header 'Power mode')
    $first = $true
    foreach ($v in $PowerOrder) {
        if (-not $PowerCaps[$v.ToLower()]) { continue }   # F3.3
        $miIts[$v] = Add-Item (Get-PowerDisplay $v)[0] { [void](Invoke-SetPowerMode $this.Name) } $(if ($first) { 'Fn+Q' } else { $null }) $null
        $miIts[$v].Name = $v
        $first = $false
    }
}
[void]$menu.Items.Add('-')
if ($VantageAppId) { [void](Add-Item 'Open Lenovo Vantage' { Start-Process explorer.exe "shell:AppsFolder\$VantageAppId" } $null $null) }   # F4.4
[void](Add-Item 'Copy diagnostics' { Set-Clipboard -Value ((Get-DiagLines) -join "`r`n") } $null $null)
[void](Add-Item 'Exit' { [System.Windows.Forms.Application]::Exit() } $null $null)
$menu.add_Opening({
    Hide-Tip
    $renderer.Dark = -not (Test-LightApps)
    Update-Tray; Update-PowerUi                                    # free sync point for Vantage-side changes
    foreach ($k in $miBattery.Keys) { $miBattery[$k].Checked = ($k -eq $script:BatMode) }
    [TrayNative]::RoundCorners($menu.Handle)
})

if ($MenuShot) {   # dev-only: render the menu to PNG for alignment checks
    foreach ($k in $miBattery.Keys) { $miBattery[$k].Checked = ($k -eq 'Conservation') }
    foreach ($v in $miIts.Keys) { $miIts[$v].Checked = ($v -eq 'Auto') }
    $menu.add_Opened({
        Start-Sleep -Milliseconds 200
        $b = New-Object System.Drawing.Bitmap $menu.Width, $menu.Height
        $g = [System.Drawing.Graphics]::FromImage($b); $g.CopyFromScreen($menu.Location, [System.Drawing.Point]::Empty, $menu.Size); $g.Dispose()
        $b.Save("$env:TEMP\lenovo-menu-shot.png"); $menu.Close(); [System.Windows.Forms.Application]::Exit()
    })
    $menu.Show(400, 400)
    [System.Windows.Forms.Application]::Run(); return
}

$onClick = { if ($_.Button -eq 'Left') { Hide-Tip; Invoke-Toggle Conservation } }
foreach ($t in $trayActive, $trayNormal, $trayPower) { $t.ContextMenuStrip = $menu; $t.add_MouseClick($onClick); $t.add_MouseMove({ Show-Tip $this }) }

# ---------------------------------------------------------------- native: hotkeys + ITS registry push
$native = New-Object TrayNative
$HotkeyAction = @{}
$HotkeysWired = 0   # combos with a known action (registered or 1409-warned); unknown actions are skipped
$ModFlags = @{ Ctrl = 0x2; Alt = 0x1; Shift = 0x4; Win = 0x8 }
foreach ($combo in $Hotkeys.Keys) {
    if ($Hotkeys[$combo] -notin $HotkeyActions) { Write-Warning "hotkey $combo action '$($Hotkeys[$combo])' unknown, skipped"; continue }
    $HotkeysWired++
    $mods = 0; $vk = 0
    foreach ($p in $combo.Split('+')) {
        if ($ModFlags.ContainsKey($p)) { $mods = $mods -bor $ModFlags[$p] }
        elseif ($p -match '^F(\d+)$') { $vk = 0x6F + [int]$matches[1] }
        else { $vk = [int][char]::ToUpper([char]$p) }
    }
    $id = $native.Register($mods, $vk)
    # F4.3 / SPEC §10: 1409 (already registered) or any other failure -> warn, keep running without that hotkey
    if ($id -lt 0) { Write-Warning "hotkey $combo not registered (win32 error $(-$id)); if 1409, another process owns it - close the old tray or change the combo in config.json" }
    else { $HotkeyAction[$id] = $Hotkeys[$combo] }
}
$native.add_HotKey({ param($id)
    switch ($HotkeyAction[$id]) {
        'toggle-conservation' { Invoke-Toggle Conservation }
        'toggle-rapid'        { Invoke-Toggle RapidCharge }
        'power-step'          { [void](Invoke-PowerStep) }
    }
    if ($tip.Visible) { $tip.Invalidate() }
})
if ($HasPowerMode) {
    $native.add_RegistryChanged({ Update-PowerUi })   # F3.6: external Fn+Q (and our own writes) land here
    $native.WatchHklm($ItsKey)
}
[Microsoft.Win32.SystemEvents]::add_UserPreferenceChanged({ Update-ThemeIcons; Update-Tray })   # light/dark switch

if ($PollSeconds -gt 0) { $poll = New-Object System.Windows.Forms.Timer; $poll.Interval = $PollSeconds * 1000; $poll.add_Tick({ Update-Tray }); $poll.Start() }

if ($SelfTest) {
    if ($InvokePowerStep) {
        if (-not $HasPowerMode) { Write-Host 'stepped=absent'; $native.Dispose(); exit 1 }
        $from, $to = Invoke-PowerStep
        Write-Host "stepped=$from->$to"
        if ($from -eq $to) { $native.Dispose(); exit 1 }
    }
    Write-Host "selftest ok items=$($menu.Items.Count) powermode=$HasPowerMode vantage=$($null -ne $VantageAppId) hotkeys=$HotkeysWired warnings=$($CfgResult.warnings.Count)"
    $native.Dispose(); exit 0
}

Update-Tray
if ($CfgResult.warnings.Count -gt 0) { Show-Balloon ($CfgResult.warnings -join "`n") }   # SPEC §10: malformed config -> warn once
try { [System.Windows.Forms.Application]::Run() }
finally { $trayActive.Visible = $false; $trayNormal.Visible = $false; $trayPower.Visible = $false; $native.Dispose() }
