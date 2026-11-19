$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "..\AIS.ps1"
$scriptText = Get-Content -LiteralPath $scriptPath -Raw
$tokens = $null
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "AIS.ps1 contains PowerShell syntax errors: $($parseErrors -join '; ')"
}

$criticalConfirmation = $scriptAst.FindAll(
    {
        param($node)
        ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq "Confirm-Critical") -or
        ($node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq "Confirm-Critical")
    },
    $true
)
if ($criticalConfirmation.Count -gt 0) {
    throw "Critical system-change confirmation prompts must be removed."
}

if ($scriptText -match "KRITISCHE SYSTEMAENDERUNG|Kritische Systemänderung|Aenderung ausfuehren\?") {
    throw "Critical system-change confirmation text remains in AIS.ps1."
}

if (-not $scriptText.Contains('Read-Host "Recovery-Key jetzt in der Konsole anzeigen? (J/N)"')) {
    throw "The separate Recovery-Key display confirmation must remain."
}

Write-Output "Critical system-change prompt tests passed."
