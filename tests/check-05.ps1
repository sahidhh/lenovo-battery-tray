# check-05: tray hardening (task 05, SPEC §10). -SelfTest paths + a real launch that must stay alive.
# Old tray from ~/scripts may still own Ctrl+Alt+6/7 -> hotkey 1409 warnings are expected and must not fail this.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tray = Join-Path $root 'src\lenovo-battery-tray.ps1'
$outDir = Join-Path $root 'tests\out'
$fails = 0

function Assert([bool]$Cond, [string]$Msg) {
    if ($Cond) { Write-Host "PASS  $Msg" } else { Write-Host "FAIL  $Msg"; $script:fails++ }
}

# runs the tray in -SelfTest mode, returns @{ exit; line = 'selftest ok ...'; out = all output }
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

[void](New-Item -ItemType Directory -Path $outDir -Force)

# 1. plain -SelfTest on 82D2
$r1 = Invoke-SelfTest @()
Write-Host "1. selftest:`n$($r1.out -join "`n")"
Assert ($r1.exit -eq 0) "selftest exit 0 (got $($r1.exit))"
Assert ($null -ne $r1.line) 'selftest prints "selftest ok" line'
Assert ((Get-Field $r1.line 'powermode') -eq 'True') 'powermode=True on 82D2'
Assert ((Get-Field $r1.line 'vantage') -eq 'True') 'vantage=True on 82D2'
Assert ((Get-Field $r1.line 'hotkeys') -eq '3') 'hotkeys=3 (6/7/8 wired)'
Assert ((Get-Field $r1.line 'warnings') -eq '0') 'warnings=0 with default config'
Assert ([int](Get-Field $r1.line 'items') -ge 10) "items >= 10 (got $(Get-Field $r1.line 'items'))"

# 2. malformed config -> exit 0, warnings=1
$bad = Join-Path $outDir 'bad.json'
Set-Content -Path $bad -Value '{ bad json' -Encoding UTF8
$r2 = Invoke-SelfTest @('-Config', $bad)
Write-Host "2. bad config: $($r2.line)"
Assert ($r2.exit -eq 0) "bad config exit 0 (got $($r2.exit))"
Assert ((Get-Field $r2.line 'warnings') -eq '1') 'bad config warnings=1'
Assert ((Get-Field $r2.line 'hotkeys') -eq '3') 'bad config still hotkeys=3 (defaults)'

# 3. forced no-power-mode -> powermode=False
$r3 = Invoke-SelfTest @('-FakeNoPowerMode')
Write-Host "3. fake no powermode: $($r3.line)"
Assert ($r3.exit -eq 0) "fake no powermode exit 0 (got $($r3.exit))"
Assert ((Get-Field $r3.line 'powermode') -eq 'False') 'FakeNoPowerMode -> powermode=False'
Assert ([int](Get-Field $r3.line 'items') -lt [int](Get-Field $r1.line 'items')) 'power-mode section removed from menu'

# 4. hard-coded values gone
$src = Get-Content -LiteralPath $tray -Raw
Assert ($src -notmatch 'k1h2ywk1493x8') 'no hard-coded Vantage publisher id'
Assert ($src -notmatch '"Mode -1"') 'no literal "Mode -1"'

# 5. real launch: alive after 4 s
$p = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tray`"" -PassThru -WindowStyle Hidden
try {
    Start-Sleep -Seconds 4
    $p.Refresh()
    Write-Host "5. launch pid=$($p.Id) exited=$($p.HasExited)"
    Assert (-not $p.HasExited) 'tray alive after 4 s'
} finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
}

if ($fails -eq 0) { Write-Host 'check-05: exit 0'; exit 0 }
Write-Host "check-05: $fails failure(s), exit 1"; exit 1
