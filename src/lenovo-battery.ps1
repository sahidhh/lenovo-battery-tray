# Lenovo IdeaPad battery charge mode control via \\.\EnergyDrv (AcpiVpc.sys).
# Protocol lifted from LenovoLegionToolkit BatteryFeature.cs; same IOCTL Vantage's IdeaNotebookAddin uses.
#
#   lenovo-battery.ps1 get
#   lenovo-battery.ps1 set  Normal|Conservation|RapidCharge
#   lenovo-battery.ps1 toggle-conservation
#   lenovo-battery.ps1 toggle-rapid
#   lenovo-battery.ps1 caps            -> cons=<bool> rapid=<bool> raw=0x<hex>
#
# Power mode (Fn+Q) via LITSSVC service control codes (OpenLenovoSettings PerformanceModeITS, MIT):
#   lenovo-battery.ps1 power-get       -> powermode=<Auto|Cool|Performance|Unknown(n)> auto=<n> cur=<n> cap=<n>
#   lenovo-battery.ps1 power-set -Mode Auto|Cool|Performance
#   lenovo-battery.ps1 power-step      -> Auto -> Cool -> Performance -> Auto (skips unavailable)
#   LITSSVC key absent -> prints powermode=absent, exit 0.
#
# Exit codes: 0 ok, 2 driver missing (EnergyDrv cannot be opened), 3 firmware ignored the write.
param(
    [Parameter(Position = 0)][ValidateSet('get', 'set', 'toggle-conservation', 'toggle-rapid', 'caps', 'power-get', 'power-set', 'power-step')]
    [string]$Cmd = 'get',
    [Parameter(Position = 1)][ValidateSet('Normal', 'Conservation', 'RapidCharge', 'Auto', 'Cool', 'Performance')]
    [string]$Mode
)

$IOCTL_CHARGE_MODE = [uint32]'0x831020F8'   # literal 0x831020F8 parses as negative int32
$RegPath = 'HKCU:\Software\Lenovo\VantageService\AddinData\IdeaNotebookAddin'
$RegNames = @{ Normal = 'Normal'; RapidCharge = 'Quick'; Conservation = 'Storage' }

# LITSSVC (F3.1/F3.4): registry is read-only for users; writes go through service control codes
$PowerKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\LITSSVC\LNBITS\IC\MMC'
$PowerCodes = @{ Auto = 135; Cool = 146; Performance = 148 }
$PowerOrder = 'Auto', 'Cool', 'Performance'

Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class EnergyDrv {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr sa, uint d, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool DeviceIoControl(SafeFileHandle h, uint c, ref uint inb, uint insz, out uint outb, uint outsz, out uint ret, IntPtr ov);
  static SafeFileHandle Open() {
    return CreateFile(@"\\.\EnergyDrv", 3, 3, IntPtr.Zero, 3, 0x80, IntPtr.Zero);
  }
  // 0 = driver opened, else Win32 error from CreateFile
  public static int TryOpen() {
    using (var h = Open()) { return h.IsInvalid ? Marshal.GetLastWin32Error() : 0; }
  }
  public static uint Send(uint code, uint value) {
    using (var h = Open()) {
      if (h.IsInvalid) throw new Exception("open \\\\.\\EnergyDrv failed, err=" + Marshal.GetLastWin32Error());
      uint outb, ret;
      if (!DeviceIoControl(h, code, ref value, 4, out outb, 4, out ret, IntPtr.Zero))
        throw new Exception("DeviceIoControl failed, err=" + Marshal.GetLastWin32Error());
      return outb;
    }
  }
}
'@

function Get-Raw {
    return [uint32][EnergyDrv]::Send($IOCTL_CHARGE_MODE, 0xFF)
}

function Get-Mode {
    $raw = Get-Raw
    if ($raw -band 0x20) { 'Conservation' } elseif ($raw -band 0x04) { 'RapidCharge' } else { 'Normal' }
}

# conservation = driver opens (no capability bit exists); rapid = bit 17 of the raw word
function Get-Caps {
    $err = [EnergyDrv]::TryOpen()
    $raw = [uint32]0
    if ($err -eq 0) { $raw = Get-Raw }
    return @{
        conservation = ($err -eq 0)
        rapid        = [bool]($raw -band 0x20000)
        raw          = $raw
        driverError  = $err
    }
}

function Write-Mirror([string]$Target) {
    # keep Vantage's mirror in sync so its restore-on-boot logic doesn't undo us
    if (-not (Test-Path $RegPath)) { [void](New-Item -Path $RegPath -Force) }
    Set-ItemProperty -Path $RegPath -Name BatteryChargeMode -Value $RegNames[$Target]
}

# Returns $true on verified success, $false if the firmware ignored the write.
# Throws only when EnergyDrv cannot be opened.
function Set-Mode {
    param([Parameter(Mandatory = $true)][ValidateSet('Normal', 'Conservation', 'RapidCharge')][string]$Mode)
    $err = [EnergyDrv]::TryOpen()
    if ($err -ne 0) { throw "cannot open \\.\EnergyDrv (Win32 error $err)" }
    $cur = Get-Mode
    if ($cur -eq $Mode) { Write-Mirror $Mode; return $true }
    # firmware state machine: Conservation and RapidCharge are mutually exclusive, so
    # leave the current special mode (0x5 / 0x8) before entering the other (0x3 / 0x7)
    $codes = switch ($Mode) {
        'Conservation' { if ($cur -eq 'RapidCharge') { 0x8, 0x3 } else { , 0x3 } }
        'Normal'       { if ($cur -eq 'Conservation') { , 0x5 } else { , 0x8 } }
        'RapidCharge'  { if ($cur -eq 'Conservation') { 0x5, 0x7 } else { , 0x7 } }
    }
    try {
        foreach ($c in $codes) { [void][EnergyDrv]::Send($IOCTL_CHARGE_MODE, $c) }
        for ($i = 0; $i -lt 10; $i++) {
            if ((Get-Mode) -eq $Mode) { Write-Mirror $Mode; return $true }
            Start-Sleep -Milliseconds 50
        }
    } catch {
        Write-Warning "set $Mode failed: $($_.Exception.Message)"
    }
    return $false
}

# ---- power mode (Fn+Q) ----

# @{auto;cur;cap} or $null when the LITSSVC key is absent (F3.8)
function Get-PowerModeRaw {
    $p = Get-ItemProperty -Path $PowerKey -ErrorAction SilentlyContinue
    if ($null -eq $p -or $null -eq $p.CurrentSetting) { return $null }
    return @{
        auto = [int]$p.AutomaticModeSetting
        cur  = [int]$p.CurrentSetting
        cap  = [int]$p.Capability
    }
}

function ConvertTo-PowerModeName($Raw) {
    if ($Raw.auto -eq 2) { return 'Auto' }
    if ($Raw.auto -eq 1 -and $Raw.cur -eq 1) { return 'Cool' }
    if ($Raw.auto -eq 1 -and $Raw.cur -eq 3) { return 'Performance' }
    return "Unknown($($Raw.cur))"
}

function Get-PowerMode {
    $r = Get-PowerModeRaw
    if ($null -eq $r) { return $null }
    return ConvertTo-PowerModeName $r
}

# capability bitmask (F3.3): bit0 set = Auto NOT available; bit1 = Cool; bit3 = Performance
function Get-PowerCaps {
    $r = Get-PowerModeRaw
    if ($null -eq $r) { return $null }
    return @{
        auto        = (($r.cap -band 1) -eq 0)
        cool        = [bool]($r.cap -band 2)
        performance = [bool]($r.cap -band 8)
    }
}

# $true once the registry reflects the new mode (polled 100 ms up to 2 s), $false otherwise
function Set-PowerMode {
    param([Parameter(Mandatory = $true)][ValidateSet('Auto', 'Cool', 'Performance')][string]$Mode)
    $caps = Get-PowerCaps
    if ($null -eq $caps) { return $null }
    if (-not $caps[$Mode.ToLower()]) { Write-Warning "power mode $Mode not available on this model"; return $false }
    if ((Get-PowerMode) -eq $Mode) { return $true }
    try {
        Add-Type -AssemblyName System.ServiceProcess
        (New-Object System.ServiceProcess.ServiceController 'LITSSVC').ExecuteCommand($PowerCodes[$Mode])
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 100
            if ((Get-PowerMode) -eq $Mode) { return $true }
        }
    } catch {
        Write-Warning "power-set $Mode failed: $($_.Exception.Message)"
    }
    return $false
}

# cycle Auto -> Cool -> Performance -> Auto over available modes; returns the new mode name
function Step-PowerMode {
    $caps = Get-PowerCaps
    if ($null -eq $caps) { return $null }
    $avail = @($PowerOrder | Where-Object { $caps[$_.ToLower()] })
    if ($avail.Count -eq 0) { return $null }
    $idx = [array]::IndexOf($avail, (Get-PowerMode))   # -1 for Unknown(n) -> first available
    $next = $avail[($idx + 1) % $avail.Count]
    if (Set-PowerMode -Mode $next) { return $next }
    return $null
}

# dot-sourced (by lenovo-battery-tray.ps1) → expose functions only, no dispatch
if ($MyInvocation.InvocationName -eq '.') { return }

if ($Cmd -like 'power-*') {
    if ($null -eq (Get-PowerModeRaw)) { Write-Host 'powermode=absent'; exit 0 }
    switch ($Cmd) {
        'power-get'  { $r = Get-PowerModeRaw; 'powermode={0} auto={1} cur={2} cap={3}' -f (ConvertTo-PowerModeName $r), $r.auto, $r.cur, $r.cap }
        'power-set'  {
            if ($Mode -notin $PowerOrder) { throw 'power-set needs -Mode Auto|Cool|Performance' }
            if (-not (Set-PowerMode -Mode $Mode)) { Write-Host "power mode set ignored, state is $(Get-PowerMode)"; exit 3 }
            $Mode
        }
        'power-step' { $n = Step-PowerMode; if ($null -eq $n) { Write-Host "power mode step failed, state is $(Get-PowerMode)"; exit 3 }; $n }
    }
    exit 0
}

$drvErr = [EnergyDrv]::TryOpen()
if ($drvErr -ne 0) { Write-Host "cannot open \\.\EnergyDrv (Win32 error $drvErr)"; exit 2 }

$ok = $true
switch ($Cmd) {
    'get'  { Get-Mode }
    'caps' { $c = Get-Caps; 'cons={0} rapid={1} raw=0x{2:X8}' -f $c.conservation, $c.rapid, $c.raw }
    'set'  { if (-not $Mode) { throw 'set needs a mode' }; $ok = Set-Mode -Mode $Mode; if ($ok) { $Mode } }
    # ponytail: toggle = "on if not already on, else Normal"; overrides the other special mode silently
    'toggle-conservation' {
        $t = if ((Get-Mode) -eq 'Conservation') { 'Normal' } else { 'Conservation' }
        $ok = Set-Mode -Mode $t; if ($ok) { $t }
    }
    'toggle-rapid' {
        $t = if ((Get-Mode) -eq 'RapidCharge') { 'Normal' } else { 'RapidCharge' }
        $ok = Set-Mode -Mode $t; if ($ok) { $t }
    }
}
if (-not $ok) { Write-Host "firmware ignored set, state is $(Get-Mode)"; exit 3 }
exit 0
