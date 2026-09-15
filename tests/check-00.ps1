# Check for task 00 — repo init.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot '_lib.ps1')

Invoke-Check {
    Push-Location $root
    try {
        $isRepo = (git rev-parse --is-inside-work-tree 2>$null)
        Assert-True ($isRepo -eq 'true') "not inside a git work tree"

        $srcDir = Join-Path $root 'src'
        $origDir = Join-Path $env:USERPROFILE 'scripts'
        $names = @('lenovo-battery.ps1', 'lenovo-battery-tray.ps1', 'lenovo-battery-tray.vbs')
        foreach ($name in $names) {
            $srcFile = Join-Path $srcDir $name
            $origFile = Join-Path $origDir $name
            Assert-True (Test-Path $srcFile) "missing src/$name"
            Assert-True (Test-Path $origFile) "missing original ~/scripts/$name"
            $srcHash = (Get-FileHash -Path $srcFile -Algorithm SHA256).Hash
            $origHash = (Get-FileHash -Path $origFile -Algorithm SHA256).Hash
            Assert-True ($srcHash -eq $origHash) "hash mismatch for $name"
        }

        $licenseFile = Join-Path $root 'LICENSE'
        Assert-True (Test-Path $licenseFile) "missing LICENSE"
        $licenseText = Get-Content -Path $licenseFile -Raw
        Assert-True ($licenseText -match 'MIT License') "LICENSE does not contain 'MIT License'"

        $batteryScript = Join-Path $srcDir 'lenovo-battery.ps1'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $batteryScript get 2>&1
        $exitCode = $LASTEXITCODE
        Write-Host "lenovo-battery.ps1 get output: $output"
        Assert-True ($exitCode -eq 0) "lenovo-battery.ps1 get exited $exitCode"
        Assert-True ($output -match 'Normal|Conservation|RapidCharge') "output did not contain a known mode: $output"
    } finally {
        Pop-Location
    }
}
