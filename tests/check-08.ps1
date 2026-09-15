# check-08: README/outreach claims + release.ps1 (task 08).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fails = 0

function Assert([bool]$Cond, [string]$Msg) {
    if ($Cond) { Write-Host "PASS  $Msg" } else { Write-Host "FAIL  $Msg"; $script:fails++ }
}

$readme = Get-Content (Join-Path $root 'README.md') -Raw

foreach ($needle in @('82D2', 'unverified', 'firmware', 'MIT', 'diag', 'OpenLenovoSettings')) {
    Assert ($readme -match [regex]::Escape($needle)) "README contains '$needle'"
}

foreach ($bad in @('all Lenovo', 'every model', 'guaranteed', 'ThinkPad supported')) {
    Assert ($readme -notmatch [regex]::Escape($bad)) "README does NOT contain '$bad' (case-insensitive)"
}

foreach ($badRam in @('60 MB', '60MB')) {
    Assert ($readme -notmatch [regex]::Escape($badRam)) "README does NOT contain '$badRam'"
}

# --- release.ps1 ---
$distDir = Join-Path $root 'dist'
$zipPath = Join-Path $distDir 'lenovo-battery-tray-v0.0.0-test.zip'
try {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'release.ps1') -Version '0.0.0-test' 2>&1
    $exit = $LASTEXITCODE
    Assert ($exit -eq 0) "release.ps1 exit 0 (out: $out)"
    Assert (Test-Path $zipPath) "zip exists at $zipPath"

    if (Test-Path $zipPath) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $hasEntry = $null -ne ($zip.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq 'src/lenovo-battery.ps1' })
            Assert $hasEntry 'zip contains src/lenovo-battery.ps1'
        } finally {
            $zip.Dispose()
        }
    }
} finally {
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }
}

# --- outreach files ---
$outreachFiles = 'ideapadtoolkit-33.md', 'ideapadtoolkit-34.md', 'ideapadtoolkit-35.md', 'llt-1390.md', 'reddit.md'
foreach ($f in $outreachFiles) {
    $p = Join-Path $root "docs\outreach\$f"
    $exists = Test-Path $p
    Assert $exists "outreach file exists: $f"
    if ($exists) {
        $len = (Get-Item $p).Length
        Assert ($len -lt 1500) "outreach file $f < 1500 chars (got $len bytes)"

        $content = Get-Content $p -Raw
        foreach ($badRam in @('60 MB', '60MB')) {
            Assert ($content -notmatch [regex]::Escape($badRam)) "outreach file $f does NOT contain '$badRam'"
        }
    }
}

if ($fails -eq 0) { Write-Host 'check-08: exit 0'; exit 0 }
Write-Host "check-08: $fails failure(s), exit 1"; exit 1
