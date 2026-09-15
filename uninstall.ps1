# Removes the Startup .lnk created by install.ps1 and (unless -KeepRunning) stops any running tray instance
# launched from this repo. Only touches "lenovo-battery-tray.lnk" - never the user's other Startup shortcuts.
param([switch]$KeepRunning)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$trayScript = Join-Path $root 'src\lenovo-battery-tray.ps1'
$startupDir = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startupDir 'lenovo-battery-tray.lnk'

if (Test-Path $lnkPath) {
    Remove-Item $lnkPath -Force
}

if (-not $KeepRunning) {
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($trayScript) }
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'uninstalled'
