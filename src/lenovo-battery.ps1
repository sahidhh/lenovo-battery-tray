# Lenovo IdeaPad battery charge mode control via \\.\EnergyDrv (AcpiVpc.sys).
# Protocol lifted from LenovoLegionToolkit BatteryFeature.cs; same IOCTL Vantage's IdeaNotebookAddin uses.
#
#   lenovo-battery.ps1 get
#   lenovo-battery.ps1 set  Normal|Conservation|RapidCharge
#   lenovo-battery.ps1 toggle-conservation
#   lenovo-battery.ps1 toggle-rapid
param(
    [Parameter(Position = 0)][ValidateSet('get', 'set', 'toggle-conservation', 'toggle-rapid')]
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
  public static uint Send(uint code, uint value) {
    using (var h = CreateFile(@"\\.\EnergyDrv", 3, 3, IntPtr.Zero, 3, 0x80, IntPtr.Zero)) {
      if (h.IsInvalid) throw new Exception("open \\\\.\\EnergyDrv failed, err=" + Marshal.GetLastWin32Error());
      uint outb, ret;
      if (!DeviceIoControl(h, code, ref value, 4, out outb, 4, out ret, IntPtr.Zero))
        throw new Exception("DeviceIoControl failed, err=" + Marshal.GetLastWin32Error());
      return outb;
    }
  }
}
'@

function Get-Mode {
    $raw = [EnergyDrv]::Send($IOCTL_CHARGE_MODE, 0xFF)
    # driver returns big-endian; LLT reverses then reads bits 17/26/29
    $v = [BitConverter]::ToUInt32([BitConverter]::GetBytes($raw)[3..0], 0)
    if (($v -shr 17) -band 1) { if (($v -shr 26) -band 1) { return 'RapidCharge' } else { return 'Normal' } }
    if (($v -shr 29) -band 1) { return 'Conservation' }
    throw "Unknown battery state 0x$($v.ToString('X8'))"
}

function Set-Mode([string]$Target) {
    $cur = Get-Mode
    if ($cur -eq $Target) { return $cur }
    # firmware state machine: Conservation and RapidCharge are mutually exclusive, so
    # leave the current special mode (0x5 / 0x8) before entering the other (0x3 / 0x7)
    $codes = switch ($Target) {
        'Conservation' { if ($cur -eq 'RapidCharge') { 0x8, 0x3 } else { , 0x3 } }
        'Normal'       { if ($cur -eq 'Conservation') { , 0x5 } else { , 0x8 } }
        'RapidCharge'  { if ($cur -eq 'Conservation') { 0x5, 0x7 } else { , 0x7 } }
    }
    foreach ($c in $codes) { [void][EnergyDrv]::Send($IOCTL_CHARGE_MODE, $c) }
    # keep Vantage's mirror in sync so its restore-on-boot logic doesn't undo us
    if (Test-Path $RegPath) { Set-ItemProperty $RegPath BatteryChargeMode $RegNames[$Target] }
    for ($i = 0; $i -lt 10; $i++) { if ((Get-Mode) -eq $Target) { return $Target }; Start-Sleep -Milliseconds 50 }
    throw "Set $Target failed, state is $(Get-Mode)"
}

# dot-sourced (by lenovo-battery-tray.ps1) → expose functions only, no dispatch
if ($MyInvocation.InvocationName -eq '.') { return }

switch ($Cmd) {
    'get' { Get-Mode }
    'set' { if (-not $Mode) { throw 'set needs a mode' }; Set-Mode $Mode }
    # ponytail: toggle = "on if not already on, else Normal"; overrides the other special mode silently
    'toggle-conservation' { if ((Get-Mode) -eq 'Conservation') { Set-Mode Normal } else { Set-Mode Conservation } }
    'toggle-rapid'        { if ((Get-Mode) -eq 'RapidCharge')  { Set-Mode Normal } else { Set-Mode RapidCharge } }
}
