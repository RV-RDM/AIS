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

$helperNames = @(
    "Confirm-CgmAlbisStopped"
    "Get-CgmLocalIniDirectory"
    "Send-CgmFolderToRecycleBin"
    "Remove-CgmTemporaryFolders"
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
    throw "Could not load the CGM permission helper functions from AIS.ps1."
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

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
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

$pauseState = @{ Count = 0 }
$emptyProcessProvider = { @() }
$pauseAction = {
    $pauseState.Count++
}.GetNewClosure()
Assert-Equal `
    $true `
    (Confirm-CgmAlbisStopped -GetProcesses $emptyProcessProvider -Pause $pauseAction) `
    "The process guard rejected a closed ALBIS."
Assert-Equal 0 $pauseState.Count "The process guard paused when ALBIS was not running."

$processQueue = New-Object 'System.Collections.Generic.Queue[object[]]'
$processQueue.Enqueue(@([pscustomobject]@{ ProcessName = "albis" }))
$processQueue.Enqueue(@())
$processProvider = { $processQueue.Dequeue() }.GetNewClosure()
Assert-Equal `
    $true `
    (Confirm-CgmAlbisStopped -GetProcesses $processProvider -Pause $pauseAction) `
    "The process guard did not continue after ALBIS closed."
Assert-Equal 1 $pauseState.Count "The process guard did not pause exactly once."

$processQueue = New-Object 'System.Collections.Generic.Queue[object[]]'
$processQueue.Enqueue(@([pscustomobject]@{ ProcessName = "albiscs" }))
$processQueue.Enqueue(@([pscustomobject]@{ ProcessName = "albiscs" }))
$processProvider = { $processQueue.Dequeue() }.GetNewClosure()
Assert-Equal `
    $false `
    (Confirm-CgmAlbisStopped -GetProcesses $processProvider -Pause $pauseAction) `
    "The process guard did not fail when ALBIS remained active."
Assert-Equal 2 $pauseState.Count "The process guard did not pause and recheck."

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "CgmPermissionsTest-{0}" -f [Guid]::NewGuid().ToString("N")
)
New-Item -Path $testRoot -ItemType Directory -ErrorAction Stop | Out-Null
try {
    $firstIni = Join-Path $testRoot "install-a\local.ini"
    $secondIni = Join-Path $testRoot "install-b\local.ini"
    New-Item -Path (Split-Path -Parent $firstIni) -ItemType Directory |
        Out-Null
    New-Item -Path $firstIni -ItemType File | Out-Null

    $location = Get-CgmLocalIniDirectory -LocalIniPaths @(
        $firstIni
        $secondIni
    )
    Assert-Equal `
        ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($firstIni))) `
        $location.Directory `
        "The local.ini containing directory was not selected."
    Assert-Throws {
        Get-CgmLocalIniDirectory -LocalIniPaths @($secondIni)
    } "A missing local.ini was accepted."

    New-Item -Path (Split-Path -Parent $secondIni) -ItemType Directory |
        Out-Null
    New-Item -Path $secondIni -ItemType File | Out-Null
    Assert-Throws {
        Get-CgmLocalIniDirectory -LocalIniPaths @($firstIni, $secondIni)
    } "Ambiguous local.ini files were accepted."
    Remove-Item -LiteralPath $secondIni -Force

    $baseDirectory = $location.Directory
    $relativePaths = @(
        "cefwrapper"
        "Connect"
        "DB\wkflwapi"
        "Listen"
        "wkflwapi"
        "logs"
    )
    foreach ($relativePath in $relativePaths) {
        $targetPath = $baseDirectory
        foreach ($segment in ($relativePath -split '[\\/]')) {
            $targetPath = Join-Path $targetPath $segment
        }
        New-Item -Path $targetPath -ItemType Directory -Force | Out-Null
    }
    $testFile = Join-Path $baseDirectory "logs\keep-for-test.txt"
    New-Item -Path $testFile -ItemType File | Out-Null

    $recycleBinCalls = New-Object 'System.Collections.Generic.List[string]'
    $recordRecycleBinCall = {
        param($Path)
        $recycleBinCalls.Add($Path)
    }.GetNewClosure()
    $results = @(
        Remove-CgmTemporaryFolders `
            -BaseDirectory $baseDirectory `
            -RecycleBinAction $recordRecycleBinCall
    )
    Assert-Equal 6 $recycleBinCalls.Count "Not all expected directories were targeted."
    Assert-Equal 6 $results.Count "Not all cleanup results were reported."
    foreach ($relativePath in $relativePaths) {
        $expectedPath = $baseDirectory
        foreach ($segment in ($relativePath -split '[\\/]')) {
            $expectedPath = Join-Path $expectedPath $segment
        }
        Assert-True `
            ($recycleBinCalls.Contains($expectedPath)) `
            "The expected cleanup path was not sent to the Recycle Bin action: $relativePath"
        Assert-True `
            (Test-Path -LiteralPath $expectedPath -PathType Container) `
            "A test directory was actually deleted: $relativePath"
    }
    Assert-True `
        (Test-Path -LiteralPath $testFile -PathType Leaf) `
        "A test file was actually deleted."

    $recycleFunction = $helperDefinitions |
        Where-Object { $_.Name -eq "Send-CgmFolderToRecycleBin" } |
        Select-Object -First 1
    Assert-True `
        ($recycleFunction.Extent.Text.Contains("[Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin")) `
        "The production deletion function does not explicitly use the Recycle Bin."
    Assert-True `
        ($recycleFunction.Extent.Text.Contains("[Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs")) `
        "The production deletion function does not use the expected non-confirming UI option."

    $taskBlock = $scriptAst.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -match '\$script:SelectedTaskIds\s+-contains\s+"cgm-permissions"'
        },
        $true
    ) | Select-Object -First 1
    $cleanupGuard = $taskBlock.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text.Trim() -eq '$albisStopped'
        },
        $true
    ) | Select-Object -First 1
    if (-not $cleanupGuard) {
        throw "The cleanup is not gated by the ALBIS-closed check."
    }
    $guardCommandNames = @(
        $cleanupGuard.FindAll(
            {
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst]
            },
            $true
        ) | ForEach-Object { $_.GetCommandName() }
    )
    Assert-True `
        ($guardCommandNames -contains "Remove-CgmTemporaryFolders") `
        "The ALBIS process guard does not protect the directory cleanup."
    Assert-True `
        ($taskBlock.Extent.Text.Contains("icacls.exe")) `
        "The existing permission-setting behavior is missing."
    Assert-True `
        (-not $cleanupGuard.Extent.Text.Contains("icacls.exe")) `
        "Permission setting is incorrectly blocked when ALBIS remains active."
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}

Write-Output "CGM permission safety tests passed."
