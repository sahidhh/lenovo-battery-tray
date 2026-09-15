# Lenovo IdeaPad battery charge mode control via \\.\EnergyDrv (AcpiVpc.sys).
# Protocol lifted from LenovoLegionToolkit BatteryFeature.cs; same IOCTL Vantage's IdeaNotebookAddin uses.
#
#   lenovo-battery.ps1 get
#   lenovo-battery.ps1 set  Normal|Conservation|RapidCharge
#   lenovo-battery.ps1 toggle-conservation
#   lenovo-battery.ps1 toggle-rapid
#   lenovo-battery.ps1 caps            -> cons=<bool> rapid=<bool> raw=0x<hex>
#
# Exit codes: 0 ok, 2 driver missing (EnergyDrv cannot be opened), 3 firmware ignored the write.
param(
    [Parameter(Position = 0)][ValidateSet('get', 'set', 'toggle-conservation', 'toggle-rapid', 'caps')]
    [string]$Cmd = 'get',
    [Parameter(Position = 1)][ValidateSet('Normal', 'Conservation', 'RapidCharge')]
    [string]$Mode
)

$IOCTL_CHARGE_MODE = [uint32]'0x831020F8'   # literal 0x831020F8 parses as negative int32
$RegPath = 'HKCU:\Software\Lenovo\VantageService\AddinData\IdeaNotebookAddin'
$RegNames = @{ Normal = 'Normal'; RapidCharge = 'Quick'; Conservation = 'Storage' }

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

# dot-sourced (by lenovo-battery-tray.ps1) → expose functions only, no dispatch
if ($MyInvocation.InvocationName -eq '.') { return }

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
