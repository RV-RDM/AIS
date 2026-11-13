$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "..\AIS.ps1"
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

$helperNames = @("Get-RustDeskWindowsX64Asset", "Get-RustDeskDesktopPath")
$helperDefinitions = $scriptAst.FindAll(
    {
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in $helperNames
    },
    $true
)
if ($helperDefinitions.Count -ne $helperNames.Count) {
    throw "Could not load the RustDesk helper functions from AIS.ps1."
}
Invoke-Expression ($helperDefinitions.Extent.Text -join "`n")

function Assert-Equal {
    param(
        [object]$Expected,
        [object]$Actual,
        [string]$Message
    )
    if ($Expected -cne $Actual) {
        throw "$Message (expected '$Expected', got '$Actual')."
    }
}

function Assert-Throws {
    param(
        [scriptblock]$Action,
        [string]$Message
    )
    try {
        & $Action
    }
    catch {
        return
    }
    throw $Message
}

$release = [pscustomobject]@{
    tag_name = "1.4.4"
    assets = @(
        [pscustomobject]@{
            name = "rustdesk-1.4.4-x86_64.exe"
            browser_download_url = "https://github.com/rustdesk/rustdesk/releases/download/1.4.4/rustdesk-1.4.4-x86_64.exe"
        }
        [pscustomobject]@{
            name = "rustdesk-1.4.4-aarch64.exe"
            browser_download_url = "https://github.com/rustdesk/rustdesk/releases/download/1.4.4/rustdesk-1.4.4-aarch64.exe"
        }
        [pscustomobject]@{
            name = "rustdesk-1.4.4-x86_64.msi"
            browser_download_url = "https://github.com/rustdesk/rustdesk/releases/download/1.4.4/rustdesk-1.4.4-x86_64.msi"
        }
    )
}
$asset = Get-RustDeskWindowsX64Asset -Release $release
Assert-Equal "1.4.4" $asset.Version "Release version was not selected"
Assert-Equal "rustdesk-1.4.4-x86_64.exe" $asset.Name "Windows x64 EXE asset was not selected"
Assert-Throws {
    Get-RustDeskWindowsX64Asset -Release ([pscustomobject]@{
        tag_name = "1.4.4"
        assets = @(
            [pscustomobject]@{
                name = "rustdesk-1.4.4-x86_64.exe"
                browser_download_url = "https://example.com/rustdesk-1.4.4-x86_64.exe"
            }
        )
    })
} "An unofficial download URL was accepted."

$desktopPath = Join-Path ([System.IO.Path]::GetTempPath()) "RustDeskTestDesktop"
$baseFileName = "RustDesk-1.4.4-x86_64.exe"
$existingPaths = @(
    (Join-Path $desktopPath $baseFileName)
    (Join-Path $desktopPath "RustDesk-1.4.4-x86_64-1.exe")
)
$path = Get-RustDeskDesktopPath `
    -DesktopPath $desktopPath `
    -Version "1.4.4" `
    -PathExists { param($Candidate) $Candidate -in $existingPaths }
Assert-Equal `
    (Join-Path $desktopPath "RustDesk-1.4.4-x86_64-2.exe") `
    $path `
    "An existing Desktop file would be overwritten."

Write-Output "RustDesk helper tests passed."
