# Shared test helpers for check-NN.ps1 scripts.

function Assert-True {
    param(
        [Parameter(Mandatory=$true)][bool]$cond,
        [Parameter(Mandatory=$true)][string]$msg
    )
    if (-not $cond) {
        throw $msg
    }
}

function Invoke-Check {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock
    )
    try {
        & $ScriptBlock
        Write-Host "PASS"
        exit 0
    } catch {
        Write-Host "FAIL: $($_.Exception.Message)"
        exit 1
    }
}
