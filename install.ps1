# Creates (or overwrites) the Startup .lnk that launches the tray via the .vbs launcher. No admin required.
# Distinct name from the user's pre-existing "Lenovo Battery Tray.lnk" (~/scripts install) - that file is
# never touched by this script.
param([switch]$NoStart)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$vbsPath = Join-Path $root 'src\lenovo-battery-tray.vbs'
$startupDir = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startupDir 'lenovo-battery-tray.lnk'

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnkPath)
$shortcut.TargetPath = 'wscript.exe'
$shortcut.Arguments = "`"$vbsPath`""
$shortcut.WorkingDirectory = Join-Path $root 'src'
$shortcut.Save()

if (-not $NoStart) {
    Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$vbsPath`"" -WindowStyle Hidden
}

Write-Host "installed: $lnkPath"
