# check-06: tray power-mode write + power-step hotkey (task 06). Flips the ITS power mode once via the tray
# handler and restores it via the CLI in finally. Ctrl+Alt+6/7 1409 warnings from the old tray are expected.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tray = Join-Path $root 'src\lenovo-battery-tray.ps1'
$cli  = Join-Path $root 'src\lenovo-battery.ps1'
$fails = 0

function Assert([bool]$Cond, [string]$Msg) {
    if ($Cond) { Write-Host "PASS  $Msg" } else { Write-Host "FAIL  $Msg"; $script:fails++ }
}
function Invoke-Cli([string[]]$CliArgs) {
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli) + $CliArgs
    $out = @(& powershell.exe @psArgs 2>&1 | ForEach-Object { "$_" })
    return @{ exit = $LASTEXITCODE; out = $out }
}
function Get-PowerName { $r = Invoke-Cli @('power-get'); if (($r.out -join ' ') -match 'powermode=(\S+)') { return $Matches[1] }; return $null }
function Invoke-SelfTest([string[]]$Extra) {
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tray, '-SelfTest') + $Extra
    $out = @(& powershell.exe @psArgs 2>&1 | ForEach-Object { "$_" })
    $line = $out | Where-Object { $_ -like 'selftest ok*' } | Select-Object -First 1
    return @{ exit = $LASTEXITCODE; line = $line; out = $out }
}
function Get-Field([string]$Line, [string]$Key) {
    if ($Line -match "(?:^| )$Key=(\S+)") { return $Matches[1] }
    return $null
}

$orig = Get-PowerName
Write-Host "orig=$orig"
if ($orig -notin 'Auto', 'Cool', 'Performance') { Write-Host "check-06: cannot run, power mode is '$orig'"; exit 1 }

$p = $null
try {
    # 1. -SelfTest -> hotkeys=3 (Ctrl+Alt+8 power-step now a known action)
    $r1 = Invoke-SelfTest @()
    Write-Host "1. selftest:`n$($r1.out -join "`n")"
    Assert ($r1.exit -eq 0) "selftest exit 0 (got $($r1.exit))"
    Assert ((Get-Field $r1.line 'hotkeys') -eq '3') 'hotkeys=3'
    Assert (($r1.out | Where-Object { $_ -match "action 'power-step' unknown" }).Count -eq 0) 'power-step no longer warned as unknown'

    # 2. -SelfTest -InvokePowerStep -> stepped=A->B, A != B, A == orig
    $r2 = Invoke-SelfTest @('-InvokePowerStep')
    Write-Host "2. step:`n$($r2.out -join "`n")"
    $stepLine = $r2.out | Where-Object { $_ -like 'stepped=*' } | Select-Object -First 1
    Assert ($r2.exit -eq 0) "step exit 0 (got $($r2.exit))"
    Assert ($null -ne $stepLine) 'prints stepped= line'
    $from = $null; $to = $null
    if ($stepLine -match '^stepped=(\S+)->(\S+)$') { $from = $Matches[1]; $to = $Matches[2] }
    Assert ($from -eq $orig) "stepped from orig ($from vs $orig)"
    Assert (($null -ne $to) -and ($to -ne $from)) "stepped to a different mode ($from -> $to)"
    Assert ((Get-PowerName) -eq $to) "CLI power-get agrees with tray ($to)"

    # 3. real launch: alive after 4 s
    $p = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tray`"" -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 4
    $p.Refresh()
    Write-Host "3. launch pid=$($p.Id) exited=$($p.HasExited)"
    Assert (-not $p.HasExited) 'tray alive after 4 s'
} finally {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    $rs = Invoke-Cli @('power-set', '-Mode', $orig)
    $now = Get-PowerName
    Write-Host "restore: power-set $orig exit=$($rs.exit) now=$now"
    Assert ($now -eq $orig) "power mode restored to $orig"
}

if ($fails -eq 0) { Write-Host 'check-06: exit 0'; exit 0 }
Write-Host "check-06: $fails failure(s), exit 1"; exit 1
