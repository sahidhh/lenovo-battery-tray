# check-02: power mode (Fn+Q) read/decode/caps/write/cycle via LITSSVC. Non-admin. Restores original mode.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'src\lenovo-battery.ps1'
$fails = 0

function Assert([bool]$Cond, [string]$Msg) {
    if ($Cond) { Write-Host "PASS  $Msg" } else { Write-Host "FAIL  $Msg"; $script:fails++ }
}

# 1. must run non-elevated (LITSSVC control codes are granted to Interactive Users)
$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Assert (-not $elevated) 'running non-elevated'
if ($elevated) { Write-Host 'check-02: exit 1'; exit 1 }

. $script

$orig = Get-PowerMode
$raw = Get-PowerModeRaw
Write-Host ("orig powermode={0} auto={1} cur={2} cap={3}" -f $orig, $raw.auto, $raw.cur, $raw.cap)
Assert ($null -ne $orig) 'LITSSVC key present'
if ($null -eq $orig) { Write-Host 'check-02: exit 1'; exit 1 }

# 2. capability bitmask (F3.3): 82D2 cap=10 -> Auto+Cool+Performance
Assert ($raw.cap -eq 10) "cap == 10 (got $($raw.cap))"
$caps = Get-PowerCaps
Assert ($caps.auto -and $caps.cool -and $caps.performance) "caps all true (auto=$($caps.auto) cool=$($caps.cool) performance=$($caps.performance))"

# expected raw combos per F3.2
$combo = @{ Cool = @{ auto = 1; cur = 1 }; Performance = @{ auto = 1; cur = 3 }; Auto = @{ auto = 2 } }

try {
    # 3. set each mode, verify decode + raw
    foreach ($m in 'Cool', 'Performance', 'Auto') {
        $ok = Set-PowerMode -Mode $m
        $r = Get-PowerModeRaw
        $got = Get-PowerMode
        Write-Host ("  set {0}: ok={1} -> powermode={2} auto={3} cur={4}" -f $m, $ok, $got, $r.auto, $r.cur)
        Assert ($ok -eq $true) "Set-PowerMode $m returned true"
        Assert ($got -eq $m) "Get-PowerMode == $m"
        $e = $combo[$m]
        $rawOk = ($r.auto -eq $e.auto) -and ((-not $e.ContainsKey('cur')) -or ($r.cur -eq $e.cur))
        Assert $rawOk "raw matches F3.2 for $m"
    }

    # 4. cycle from Auto (F3.9): Auto -> Cool -> Performance -> Auto
    Assert ((Get-PowerMode) -eq 'Auto') 'at Auto before cycling'
    foreach ($want in 'Cool', 'Performance', 'Auto') {
        $got = Step-PowerMode
        Write-Host "  step -> $got"
        Assert ($got -eq $want) "Step-PowerMode -> $want"
    }
} finally {
    # 5. restore
    $rok = Set-PowerMode -Mode $orig
    $now = Get-PowerMode
    Write-Host "restore $orig : ok=$rok now=$now"
    Assert ($rok -and ($now -eq $orig)) "restored original mode $orig"
}

# 6. CLI power-get
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script power-get 2>&1 | Out-String
$out = $out.Trim()
Write-Host "power-get: $out  (exit $LASTEXITCODE)"
Assert ($out -match '^powermode=(Auto|Cool|Performance) auto=\d+ cur=\d+ cap=\d+$') 'power-get output format'
Assert ($LASTEXITCODE -eq 0) 'power-get exit 0'

if ($fails -eq 0) { Write-Host 'check-02: exit 0'; exit 0 }
Write-Host "check-02: $fails failure(s), exit 1"; exit 1
