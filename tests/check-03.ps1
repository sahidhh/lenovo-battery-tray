# check-03: Get-Config loader (F4.5, SPEC §8). Never touches real LOCALAPPDATA.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'src\lenovo-battery.ps1'
$outDir = Join-Path $root 'tests\out'
$fails = 0

function Assert([bool]$Cond, [string]$Msg) {
    if ($Cond) { Write-Host "PASS  $Msg" } else { Write-Host "FAIL  $Msg"; $script:fails++ }
}

. $script

if (Test-Path $outDir) { Remove-Item -Recurse -Force $outDir }
[void](New-Item -ItemType Directory -Path $outDir -Force)

$defaults = Get-DefaultConfig

# 1. no file -> defaults, no warnings
$p1 = Join-Path $outDir 'missing.json'
$r1 = Get-Config -Path $p1
Write-Host "1. no file: pollSeconds=$($r1.config.pollSeconds) warnings=$($r1.warnings.Count)"
Assert ($r1.config.pollSeconds -eq 0) 'no file: pollSeconds default 0'
Assert ($r1.config.hotkeys.'Ctrl+Alt+6' -eq 'toggle-conservation') 'no file: hotkeys default'
Assert ($r1.warnings.Count -eq 0) 'no file: no warnings'

# 2. partial override -> pollSeconds overridden, hotkeys default, no warnings
$p2 = Join-Path $outDir 'partial.json'
Set-Content -Path $p2 -Value '{"pollSeconds": 5}' -Encoding UTF8
$r2 = Get-Config -Path $p2
Write-Host "2. partial: pollSeconds=$($r2.config.pollSeconds) warnings=$($r2.warnings.Count)"
Assert ($r2.config.pollSeconds -eq 5) 'partial: pollSeconds == 5'
Assert ($r2.config.hotkeys.'Ctrl+Alt+7' -eq 'toggle-rapid') 'partial: hotkeys still default'
Assert ($r2.warnings.Count -eq 0) 'partial: no warnings'

# 3. malformed JSON -> defaults, one warning
$p3 = Join-Path $outDir 'bad.json'
Set-Content -Path $p3 -Value '{ bad json' -Encoding UTF8
$r3 = Get-Config -Path $p3
Write-Host "3. malformed: pollSeconds=$($r3.config.pollSeconds) warnings=$($r3.warnings.Count)"
Assert ($r3.config.pollSeconds -eq 0) 'malformed: defaults'
Assert ($r3.warnings.Count -eq 1) 'malformed: warnings.Count == 1'

# 4. unknown top-level key -> ignored, defaults, no warnings
$p4 = Join-Path $outDir 'unknown.json'
Set-Content -Path $p4 -Value '{"zzz":1}' -Encoding UTF8
$r4 = Get-Config -Path $p4
Write-Host "4. unknown key: pollSeconds=$($r4.config.pollSeconds) warnings=$($r4.warnings.Count) hasZzz=$($r4.config.ContainsKey('zzz'))"
Assert ($r4.config.pollSeconds -eq 0) 'unknown key: defaults'
Assert ($r4.warnings.Count -eq 0) 'unknown key: no warnings'
Assert (-not $r4.config.ContainsKey('zzz')) 'unknown key: not copied into config'

# 5. nested partial override -> Cool overridden, Auto default
$p5 = Join-Path $outDir 'nested.json'
Set-Content -Path $p5 -Value '{"powerMode":{"labels":{"Cool":"Eco"}}}' -Encoding UTF8
$r5 = Get-Config -Path $p5
Write-Host "5. nested: Cool=$($r5.config.powerMode.labels.Cool) Auto=$($r5.config.powerMode.labels.Auto)"
Assert ($r5.config.powerMode.labels.Cool -eq 'Eco') 'nested: Cool == Eco'
Assert ($r5.config.powerMode.labels.Auto -eq $defaults.powerMode.labels.Auto) 'nested: Auto still default'

# 6. loader never writes: file mtimes/contents unchanged, no new files created after calls
$before = Get-ChildItem $outDir | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.Length)" }
Get-Config -Path $p1 | Out-Null
Get-Config -Path $p2 | Out-Null
Get-Config -Path $p3 | Out-Null
Get-Config -Path $p4 | Out-Null
Get-Config -Path $p5 | Out-Null
$after = Get-ChildItem $outDir | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.Length)" }
Assert (($before -join ',') -eq ($after -join ',')) 'loader is read-only (no files changed/added)'

Remove-Item -Recurse -Force $outDir

if ($fails -eq 0) { Write-Host 'check-03: exit 0'; exit 0 }
Write-Host "check-03: $fails failure(s), exit 1"; exit 1
