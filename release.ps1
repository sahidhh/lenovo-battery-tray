# Builds a release zip: src/, install.ps1, uninstall.ps1, README.md, LICENSE -> dist/lenovo-battery-tray-v<ver>.zip
param(
    [Parameter(Mandatory = $true)][string]$Version
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$distDir = Join-Path $root 'dist'
$zipPath = Join-Path $distDir "lenovo-battery-tray-v$Version.zip"

if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir | Out-Null }
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

$stageDir = Join-Path $distDir "stage-v$Version"
if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir | Out-Null

Copy-Item (Join-Path $root 'src') (Join-Path $stageDir 'src') -Recurse
Copy-Item (Join-Path $root 'install.ps1') $stageDir
Copy-Item (Join-Path $root 'uninstall.ps1') $stageDir
Copy-Item (Join-Path $root 'README.md') $stageDir
Copy-Item (Join-Path $root 'LICENSE') $stageDir

Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $zipPath -Force
Remove-Item $stageDir -Recurse -Force

$hash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash
Write-Host "zip: $zipPath"
Write-Host "SHA256: $hash"
