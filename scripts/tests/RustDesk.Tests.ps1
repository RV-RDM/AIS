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

$taskListAssignment = $scriptAst.FindAll(
    {
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq "script:AISTasks"
    },
    $true
) | Select-Object -First 1
if (-not $taskListAssignment) {
    throw "Could not load the AIS task list."
}
$tasks = @(Invoke-Expression $taskListAssignment.Right.Extent.Text)
$startupTask = $tasks | Where-Object { $_.Id -eq "startup-checks" } |
    Select-Object -First 1
$rustDeskTask = $tasks | Where-Object { $_.Id -eq "rustdesk-check-download" } |
    Select-Object -First 1
if (-not $startupTask -or -not $rustDeskTask -or $rustDeskTask.TaskIds) {
    throw "RustDesk check and download must be a standalone selectable task."
}
if ($startupTask.TaskIds -contains $rustDeskTask.Id) {
    throw "RustDesk check and download must not run with the automatic startup checks."
}
if ($rustDeskTask.Title -ne "RustDesk pruefen und bei Bedarf herunterladen") {
    throw "The RustDesk menu item must describe both checking and downloading."
}

$helperNames = @(
    "Get-RustDeskWindowsX64Asset"
    "Get-RustDeskDesktopPath"
    "Test-RustDeskDesktopItem"
)
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

$desktopPath = Join-Path ([System.IO.Path]::GetTempPath()) (
    "RustDeskTestDesktop-{0}" -f [Guid]::NewGuid().ToString("N")
)
New-Item -Path $desktopPath -ItemType Directory -ErrorAction Stop | Out-Null
try {
    Assert-Equal `
        $false `
        (Test-RustDeskDesktopItem -DesktopPath $desktopPath) `
        "An empty Desktop was reported to contain RustDesk."

    New-Item -Path (Join-Path $desktopPath "RustDesk.lnk") -ItemType File |
        Out-Null
    Assert-Equal `
        $true `
        (Test-RustDeskDesktopItem -DesktopPath $desktopPath) `
        "A RustDesk shortcut was not detected."

    Remove-Item -LiteralPath (Join-Path $desktopPath "RustDesk.lnk")
    New-Item -Path (Join-Path $desktopPath "RUSTDESK-1.4.4-X86_64.EXE") `
        -ItemType File | Out-Null
    Assert-Equal `
        $true `
        (Test-RustDeskDesktopItem -DesktopPath $desktopPath) `
        "A case-insensitive RustDesk executable was not detected."

    Remove-Item -LiteralPath (
        Join-Path $desktopPath "RUSTDESK-1.4.4-X86_64.EXE"
    )
    New-Item -Path (Join-Path $desktopPath "notes.txt") -ItemType File |
        Out-Null
    Assert-Equal `
        $false `
        (Test-RustDeskDesktopItem -DesktopPath $desktopPath) `
        "An unrelated Desktop file was reported as RustDesk."
}
finally {
    Remove-Item -LiteralPath $desktopPath -Recurse -Force
}

Write-Output "RustDesk helper tests passed."
