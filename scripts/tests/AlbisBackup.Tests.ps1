$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "..\AIS.ps1"
$scriptText = Get-Content -LiteralPath $scriptPath -Raw
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -gt 0) {
    throw "AIS.ps1 contains PowerShell syntax errors: $($parseErrors -join '; ')"
}

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Expected,
        [string]$Message
    )
    if (-not $Text.Contains($Expected)) {
        throw $Message
    }
}

Assert-Contains `
    $scriptText `
    '$script:SelectedTaskIds = @($startupTask.TaskIds) + @(
            "registry-backup"
            "albis-backup"
        )' `
    "The automatic startup selection does not include both ALBIS backups."
Assert-Contains `
    $scriptText `
    '[pscustomobject]@{ Id = "registry-backup"; Title = "ALBIS-Registry-Sicherung" }' `
    "The manual ALBIS registry backup menu entry is missing."
Assert-Contains `
    $scriptText `
    '[pscustomobject]@{ Id = "albis-backup"; Title = "ALBIS-Dateien als ZIP sichern" }' `
    "The manual ALBIS ZIP backup menu entry is missing."
Assert-Contains `
    $scriptText `
    '$LogFolder = "C:\EDV-inst\AIS"' `
    "The backup directory is not C:\EDV-inst\AIS."
Assert-Contains `
    $scriptText `
    '("Registry_HKCU_Software_ALBIS_{0}_{1}.reg" -f $env:USERNAME, $Timestamp)' `
    "The registry backup filename does not include the username."
Assert-Contains `
    $scriptText `
    '$backupFolder = $LogFolder' `
    "The ALBIS ZIP backup does not use the configured backup directory."

Write-Output "ALBIS backup tests passed."
