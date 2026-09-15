# check-04: diag command (F4.6, SPEC §9, task 04). Order-fixed key=value lines, never throws.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'src\lenovo-battery.ps1'
$fails = 0

function Assert([bool]$Cond, [string]$Msg) {
    if ($Cond) { Write-Host "PASS  $Msg" } else { Write-Host "FAIL  $Msg"; $script:fails++ }
}

$expectedOrder = 'model', 'mtm', 'bios', 'os', 'admin', 'energydrv', 'raw', 'mode', 'caps', 'powermode', 'powerraw', 'regmirror', 'services'

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script diag 2>&1
$exit = $LASTEXITCODE
$sw.Stop()

Write-Host "CLI exit=$exit elapsed=$($sw.Elapsed.TotalSeconds)s"
Assert ($exit -eq 0) 'diag exit 0'
Assert ($sw.Elapsed.TotalSeconds -lt 5) 'diag runs in < 5s'

$lines = @($out)
Write-Host "lines:`n$($lines -join "`n")"

$keys = @()
foreach ($line in $lines) {
    if ($line -match '^([a-zA-Z]+)=') { $keys += $Matches[1] }
}

Assert (($keys | Sort-Object -Unique).Count -eq $keys.Count) 'every key present exactly once (no dup)'
Assert (($keys -join ',') -eq ($expectedOrder -join ',')) "keys in order (got: $($keys -join ','))"

function Get-Value([string]$Key) {
    foreach ($line in $lines) {
        if ($line -like "$Key=*") { return $line.Substring($Key.Length + 1) }
    }
    return $null
}

$diagMtm = Get-Value 'mtm'
$diagAdmin = Get-Value 'admin'
$diagEnergydrv = Get-Value 'energydrv'
$diagMode = Get-Value 'mode'
$diagPowermode = Get-Value 'powermode'
$diagRaw = Get-Value 'raw'

Assert ($diagMtm -eq '82D2') "mtm == 82D2 (got $diagMtm)"
Assert ($diagAdmin -eq 'False') "admin == False (got $diagAdmin)"
Assert ($diagEnergydrv -eq 'ok') "energydrv == ok (got $diagEnergydrv)"

# dot-sourcing overwrites $Cmd/$Mode params in this scope (they're caller-scope after '.') - use a fresh name
. $script
$diagExpectedMode = Get-Mode
Assert ($diagMode -eq $diagExpectedMode) "mode == Get-Mode ($diagExpectedMode) (got $diagMode)"

Assert ($diagPowermode -in @('Auto', 'Cool', 'Performance')) "powermode in Auto|Cool|Performance (got $diagPowermode)"
Assert ($diagRaw -match '^0x[0-9A-F]{8}$') "raw matches ^0x[0-9A-F]{8}\$ (got $diagRaw)"

if ($fails -eq 0) { Write-Host 'check-04: exit 0'; exit 0 }
Write-Host "check-04: $fails failure(s), exit 1"; exit 1
