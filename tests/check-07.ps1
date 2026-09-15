# check-07: launcher + install/uninstall (task 07). Idempotent, no admin, does not touch the user's
# pre-existing "Lenovo Battery Tray.lnk" (~/scripts install).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fails = 0

function Assert([bool]$Cond, [string]$Msg) {
    if ($Cond) { Write-Host "PASS  $Msg" } else { Write-Host "FAIL  $Msg"; $script:fails++ }
}

$startupDir = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startupDir 'lenovo-battery-tray.lnk'
$userLnkPath = Join-Path $startupDir 'Lenovo Battery Tray.lnk'
$vbsPath = Join-Path $root 'src\lenovo-battery-tray.vbs'
$trayScript = Join-Path $root 'src\lenovo-battery-tray.ps1'

$userLnkExistedBefore = Test-Path $userLnkPath
Write-Host "user lnk exists before: $userLnkExistedBefore"

try {
    # --- install -NoStart, twice (idempotent) ---
    $out1 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install.ps1') -NoStart 2>&1
    $exit1 = $LASTEXITCODE
    Assert ($exit1 -eq 0) "install.ps1 -NoStart exit 0 (out: $out1)"
    Assert (Test-Path $lnkPath) 'lnk exists after install'

    $out2 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install.ps1') -NoStart 2>&1
    $exit2 = $LASTEXITCODE
    Assert ($exit2 -eq 0) "install.ps1 -NoStart run 2 exit 0 (out: $out2)"

    $lnkCount = @(Get-ChildItem $startupDir -Filter 'lenovo-battery-tray.lnk').Count
    Assert ($lnkCount -eq 1) "still exactly one lnk (got $lnkCount)"

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($lnkPath)
    Assert ($shortcut.TargetPath -like '*wscript.exe') "TargetPath ends wscript.exe (got $($shortcut.TargetPath))"
    Assert ($shortcut.Arguments -like "*$vbsPath*") "Arguments contains abs vbs path (got $($shortcut.Arguments))"

    Assert (Test-Path $userLnkPath) "user's original lnk exists after install"

    # --- uninstall -KeepRunning ---
    $out3 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'uninstall.ps1') -KeepRunning 2>&1
    $exit3 = $LASTEXITCODE
    Assert ($exit3 -eq 0) "uninstall.ps1 -KeepRunning exit 0 (out: $out3)"
    Assert (-not (Test-Path $lnkPath)) 'lnk gone after uninstall'
    Assert (Test-Path $userLnkPath) "user's original lnk exists after uninstall"

    # --- vbs launches the tray script ---
    Push-Location (Join-Path $root 'tests')
    try {
        $proc = Start-Process -FilePath 'wscript.exe' -ArgumentList '//nologo', '..\src\lenovo-battery-tray.vbs' -PassThru
        try {
            $found = $false
            $deadline = (Get-Date).AddSeconds(4)
            while ((Get-Date) -lt $deadline -and -not $found) {
                Start-Sleep -Milliseconds 300
                $matches = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
                    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($trayScript) }
                if ($matches) { $found = $true }
            }
            Assert $found 'powershell process running tray script found within 4s'
            if ($matches) {
                foreach ($m in $matches) { Stop-Process -Id $m.ProcessId -Force -ErrorAction SilentlyContinue }
            }
        } finally {
            if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        }
    } finally {
        Pop-Location
    }
} finally {
    # restore original state: remove our lnk if left behind, leave user's lnk untouched
    if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force -ErrorAction SilentlyContinue }
    $userLnkExistsAfter = Test-Path $userLnkPath
    Write-Host "user lnk exists after: $userLnkExistsAfter"
    if ($userLnkExistedBefore -ne $userLnkExistsAfter) {
        Write-Host "FAIL  user's lnk presence changed by this check"
        $fails++
    }
}

if ($fails -eq 0) { Write-Host 'check-07: exit 0'; exit 0 }
Write-Host "check-07: $fails failure(s), exit 1"; exit 1
