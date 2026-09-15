# Check for task 01 — core charge mode. Flips hardware modes; restores original in finally.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot '_lib.ps1')

$core = Join-Path $root 'src\lenovo-battery.ps1'
$mirrorKey = 'HKCU:\Software\Lenovo\VantageService\AddinData\IdeaNotebookAddin'   # F1.10
$mirrorMap = @{ Normal = 'Normal'; RapidCharge = 'Quick'; Conservation = 'Storage' }  # F1.10
$rawWords = @{ Conservation = [uint32]0x100A0020; Normal = [uint32]0x100A0200; RapidCharge = [uint32]0x100A0204 }  # F1.9

Invoke-Check {
    . $core
    $orig = Get-Mode
    Write-Host "orig=$orig"
    try {
        $caps = Get-Caps
        Write-Host ("caps: cons={0} rapid={1} raw=0x{2:X8} driverError={3}" -f $caps.conservation, $caps.rapid, $caps.raw, $caps.driverError)
        Assert-True ($caps.conservation -eq $true) "caps.conservation not true"
        Assert-True ($caps.rapid -eq $true) "caps.rapid not true"
        Assert-True (($caps.raw -band 0x20000) -ne 0) "bit 17 not set in raw"

        foreach ($target in @('Normal', 'RapidCharge', 'Conservation')) {
            $ok = Set-Mode -Mode $target
            Assert-True ($ok -eq $true) "Set-Mode $target returned $ok"
            $mode = Get-Mode
            $raw = Get-Raw
            $mirror = (Get-ItemProperty -Path $mirrorKey -Name BatteryChargeMode).BatteryChargeMode
            Write-Host ("set {0}: mode={1} raw=0x{2:X8} mirror={3}" -f $target, $mode, $raw, $mirror)
            Assert-True ($mode -eq $target) "Get-Mode after set $target was $mode"
            Assert-True ($mirror -eq $mirrorMap[$target]) "mirror after set $target was $mirror"
            Assert-True ($raw -eq $rawWords[$target]) ("raw after set {0} was 0x{1:X8}" -f $target, $raw)
        }
    } finally {
        $restored = Set-Mode -Mode $orig
        Write-Host "restore $orig -> $restored, now $(Get-Mode)"
    }
    Assert-True ((Get-Mode) -eq $orig) "mode not restored to $orig"

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $core caps 2>&1
    $exitCode = $LASTEXITCODE
    Write-Host "cli caps: exit=$exitCode output=$output"
    Assert-True ($exitCode -eq 0) "cli caps exited $exitCode"
    Assert-True ("$output" -match '^cons=True rapid=True raw=0x[0-9A-F]{8}$') "cli caps output mismatch: $output"
}
