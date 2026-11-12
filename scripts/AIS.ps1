<#
requires -Version 5.1
requires -RunAsAdministrator

 ALBIS SYSTEMCHECK - WINDOWS 11
 Version: 1.1
 PowerShell: 5.1 oder neuer
 Ausfuehrung: Administrator
#>

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# KONFIGURATION
# ============================================================
# Protokollverzeichnis
$LogFolder = "C:\cgm"

# Ordner automatisch erstellen
if (!(Test-Path -LiteralPath $LogFolder)) {
    New-Item -Path $LogFolder -ItemType Directory -Force |
        Out-Null
}
# Protokolldatei mit Zeitstempel
$script:LogFile = Join-Path $LogFolder (
    "ALBIS_Systemcheck_{0}.txt" -f
    (Get-Date -Format "yyyyMMdd_HHmmss")
)
$script:Success  = 0
$script:Warnings = 0
$script:Errors   = 0
$script:Changes  = 0

$script:LogFile | Out-Null

$startDate = Get-Date

# ============================================================
# PROTOKOLLIERUNG

New-Item -Path $script:LogFile -ItemType File -Force |
    Out-Null
function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("OK","WARN","ERROR","INFO")]
        [string]$Status = "INFO"
    )
    $time = Get-Date -Format "dd.MM.yyyy HH:mm:ss"
    switch ($Status) {
        "OK" {
            $color = "Green"
            $script:Success++
            $prefix = "[ OK ]"
        }
        "WARN" {
            $color = "Yellow"
            $script:Warnings++
            $prefix = "[WARN]"
        }
        "ERROR" {
            $color = "Red"
            $script:Errors++
            $prefix = "[FEHLER]"
        }
        default {
            $color = "Cyan"
            $prefix = "[INFO]"
        }
    }
    $line = "$time $prefix $Message"
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $script:LogFile `
        -Value $line -Encoding UTF8
}
function Write-Section {
    param([string]$Title)

    $line = "`r`n========== $Title =========="

    Write-Host $line -ForegroundColor Cyan

    Add-Content -Path $script:LogFile `
        -Value $line -Encoding UTF8
}
function Confirm-Critical {
    param([string]$Message)
    Write-Host ""
    Write-Host "KRITISCHE SYSTEMAENDERUNG" -ForegroundColor Red
    Write-Host $Message -ForegroundColor Yellow

    if (-not [Environment]::UserInteractive -or -not $Host -or -not $Host.UI -or -not $Host.UI.RawUI) {
        Write-Status "Aenderung abgebrochen: Nicht-interaktive Umgebung" "WARN"
        return $false
    }

    $answer = Read-Host "Aenderung ausfuehren? (J/N)"

    return ($answer -match "^(J|JA|Y|YES)$")
}
function Invoke-Critical {

    param(
        [string]$Description,
        [scriptblock]$Action
    )
    if (Confirm-Critical $Description) {
        try {
            & $Action
            $script:Changes++
            Write-Status "$Description - ausgefuehrt" "OK"
        }
        catch {
            Write-Status (
                "$Description - $($_.Exception.Message)"
            ) "ERROR"
        }
    }
    else {

        Write-Status "$Description - abgelehnt" "WARN"
    }
}
function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [Microsoft.Win32.RegistryValueKind]$Type =
            [Microsoft.Win32.RegistryValueKind]::DWord
    )
    if (!(Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path `
        -Name $Name `
        -Value $Value `
        -PropertyType $Type `
        -Force | Out-Null
}

function Get-AlbisInstallInfo {
    param([object[]]$Installations)

    foreach ($installation in $Installations) {
        $localIniPath = Join-Path $installation.Path "local.ini"
        $localIniExists = Test-Path -LiteralPath $localIniPath -PathType Leaf
        $mainPath = $null
        $mainPathValid = $false
        $serverIniPath = $null
        $serverIniExists = $false
        $readError = $null

        if ($localIniExists) {
            try {
                $mainLine = Get-Content -LiteralPath $localIniPath -ErrorAction Stop |
                    Where-Object { $_ -match '^\s*Main\s*=' } |
                    Select-Object -First 1

                if ($mainLine -match '^\s*Main\s*=\s*(.*?)\s*$') {
                    $mainPath = $Matches[1].Trim().Trim('"').Trim("'")
                }
            }
            catch {
                $readError = $_.Exception.Message
            }

            if (
                -not [string]::IsNullOrWhiteSpace($mainPath) -and
                [System.IO.Path]::IsPathRooted($mainPath)
            ) {
                try {
                    $mainPathValid = Test-Path `
                        -LiteralPath $mainPath `
                        -PathType Container
                    if ($mainPathValid) {
                        $serverIniPath = Join-Path $mainPath "albisglb.ini"
                        $serverIniExists = Test-Path `
                            -LiteralPath $serverIniPath `
                            -PathType Leaf
                    }
                }
                catch {
                    $mainPathValid = $false
                }
            }
        }

        [pscustomobject]@{
            InstallPath     = $installation.Path
            ArchivePrefix   = $installation.ArchivePrefix
            LocalIniPath    = $localIniPath
            LocalIniExists  = $localIniExists
            MainPath        = $mainPath
            MainPathValid   = $mainPathValid
            ServerIniPath   = $serverIniPath
            ServerIniExists = $serverIniExists
            ReadError       = $readError
        }
    }
}

function Get-AlbisBackupEntries {
    param([object[]]$InstallInfos)

    $entries = @()
    $entryNames = @{}

    foreach ($installInfo in $InstallInfos) {
        if ($installInfo.LocalIniExists) {
            $entryName = "$($installInfo.ArchivePrefix)/local.ini"
            if ($entryNames.ContainsKey($entryName)) {
                throw "Doppelter ZIP-Eintragsname: $entryName"
            }
            $entryNames[$entryName] = $true
            $entries += [pscustomobject]@{
                SourcePath = $installInfo.LocalIniPath
                EntryName  = $entryName
            }
        }

        if ($installInfo.ServerIniExists) {
            $entryName = "$($installInfo.ArchivePrefix)/albisglb.ini"
            if ($entryNames.ContainsKey($entryName)) {
                throw "Doppelter ZIP-Eintragsname: $entryName"
            }
            $entryNames[$entryName] = $true
            $entries += [pscustomobject]@{
                SourcePath = $installInfo.ServerIniPath
                EntryName  = $entryName
            }
        }
    }

    return $entries
}

$script:AlbisInstallations = @(
    [pscustomobject]@{
        Path          = "C:\CGM\albiswin"
        ArchivePrefix = "C/CGM/albiswin"
    }
    [pscustomobject]@{
        Path          = "C:\albiswin"
        ArchivePrefix = "C/albiswin"
    }
)
$script:AlbisInstallInfos = @(
    Get-AlbisInstallInfo -Installations $script:AlbisInstallations
)

Write-Host "ALBIS-Installationen beim Start:" -ForegroundColor Cyan
foreach ($installInfo in $script:AlbisInstallInfos) {
    if (-not $installInfo.LocalIniExists) {
        Write-Host "local.ini nicht gefunden: $($installInfo.LocalIniPath)" `
            -ForegroundColor Yellow
        continue
    }

    Write-Host "local.ini: $($installInfo.LocalIniPath)" `
        -ForegroundColor White
    if ($installInfo.ReadError) {
        Write-Host "Main= konnte nicht gelesen werden: $($installInfo.ReadError)" `
            -ForegroundColor Yellow
    }
    elseif ([string]::IsNullOrWhiteSpace($installInfo.MainPath)) {
        Write-Host "Main= ist in local.ini nicht gesetzt." `
            -ForegroundColor Yellow
    }
    else {
        Write-Host "ALBIS-Serverpfad (Main=): $($installInfo.MainPath)" `
            -ForegroundColor White
        if (-not $installInfo.MainPathValid) {
            Write-Host "ALBIS-Serverpfad ist ungueltig oder nicht erreichbar." `
                -ForegroundColor Yellow
        }
        elseif (-not $installInfo.ServerIniExists) {
            Write-Host "albisglb.ini nicht gefunden: $($installInfo.ServerIniPath)" `
                -ForegroundColor Yellow
        }
    }
}
Write-Status "ALBIS-Startpfade wurden angezeigt; local.ini-Inhalte werden nicht protokolliert." "INFO"

$script:AISTasks = @(
    [pscustomobject]@{
        Id      = "startup-checks"
        Title   = "Automatische Startpruefungen (System und Netzwerk)"
        TaskIds = @(
            "windows-version"
            "memory"
            "disk-space"
            "hosts-file"
            "time-sync"
            "defender-exclusions"
            "ipv4-routes"
        )
    }
    [pscustomobject]@{ Id = "system-restore"; Title = "Systemwiederherstellung" }
    [pscustomobject]@{ Id = "registry-backup"; Title = "ALBIS-Registry-Sicherung" }
    [pscustomobject]@{ Id = "albis-backup"; Title = "ALBIS-Dateien als ZIP sichern" }
    [pscustomobject]@{ Id = "smb"; Title = "SMB-Konfiguration und Verbindungen" }
    [pscustomobject]@{ Id = "tcp"; Title = "TCP-Konfiguration und Verbindungen" }
    [pscustomobject]@{ Id = "bitlocker"; Title = "BitLocker-Status und Recovery-Key anzeigen" }
    [pscustomobject]@{ Id = "notepad-settings"; Title = "Notepad-Einstellungen importieren" }
    [pscustomobject]@{ Id = "ipv6-qos"; Title = "IPv6 und QoS-Paketplaner pruefen/aendern" }
    [pscustomobject]@{ Id = "uac"; Title = "Benutzerkontensteuerung pruefen" }
    [pscustomobject]@{ Id = "windows-ui"; Title = "Windows-Oberflaeche optimieren" }
    [pscustomobject]@{ Id = "distributed-links"; Title = "Dienst fuer verteilte Verknuepfungen" }
    [pscustomobject]@{ Id = "power"; Title = "Energieverwaltung und Bildschirmschoner" }
    [pscustomobject]@{ Id = "rdp"; Title = "Remotedesktop aktivieren" }
    [pscustomobject]@{ Id = "linked-connections"; Title = "Linked Connections aktivieren" }
    [pscustomobject]@{ Id = "cgm-permissions"; Title = "CGM-Ordnerberechtigungen pruefen" }
    [pscustomobject]@{ Id = "mtu"; Title = "MTU pruefen und anpassen" }
    [pscustomobject]@{ Id = "network-profile"; Title = "Netzwerkprofil auf Privat setzen" }
    [pscustomobject]@{ Id = "firewall-profile"; Title = "Private Defender-Firewall pruefen" }
    [pscustomobject]@{ Id = "firewall-service"; Title = "Firewall-Dienst pruefen/neustarten" }
    [pscustomobject]@{ Id = "smart-app-control"; Title = "Smart App Control pruefen" }
    [pscustomobject]@{ Id = "storage-sense"; Title = "Windows-Speicheroptimierung pruefen" }
    [pscustomobject]@{ Id = "temp-folders"; Title = "Temp-Ordner pruefen/bereinigen" }
    [pscustomobject]@{ Id = "event-log"; Title = "Systemereignisse pruefen" }
    [pscustomobject]@{ Id = "dns-cache"; Title = "DNS-Cache leeren" }
    [pscustomobject]@{ Id = "rustdesk-check"; Title = "RustDesk-Installation pruefen" }
)

$script:AllTaskIds = @(
    foreach ($task in $script:AISTasks) {
        if ($task.TaskIds) {
            $task.TaskIds
        }
        else {
            $task.Id
        }
    }
)
$script:AISTaskChoices = @{}
$script:ExitRequested = $false
$script:StartupChecksPending = $true

while ($true) {
    if ($script:StartupChecksPending) {
        $startupTask = $script:AISTasks |
            Where-Object { $_.Id -eq "startup-checks" } |
            Select-Object -First 1
        $script:SelectedTaskIds = @($startupTask.TaskIds)
        $script:SelectionDescription = "Automatische Startpruefungen"
        $script:StartupChecksPending = $false
    }
    else {
        $script:AISTaskChoices.Clear()
        Write-Host ""
        Write-Host "AIS SYSTEMCHECK - AUFGABE AUSWAEHLEN" -ForegroundColor Cyan
        Write-Host "0  - Alle Aufgaben ausfuehren"
        for ($index = 0; $index -lt $script:AISTasks.Count; $index++) {
            $choice = [string]($index + 1)
            $script:AISTaskChoices[$choice] = $script:AISTasks[$index]
            Write-Host ("{0,2} - {1}" -f $choice, $script:AISTasks[$index].Title)
        }
        Write-Host "Q  - Beenden"

        while ($true) {
            $selection = (Read-Host "Auswahl").Trim()

            if ($selection -eq "0") {
                $script:SelectedTaskIds = $script:AllTaskIds
                $script:SelectionDescription = "Alle Aufgaben"
                break
            }

            if ($script:AISTaskChoices.ContainsKey($selection)) {
                $selectedTask = $script:AISTaskChoices[$selection]
                if ($selectedTask.TaskIds) {
                    $script:SelectedTaskIds = @($selectedTask.TaskIds)
                }
                else {
                    $script:SelectedTaskIds = @($selectedTask.Id)
                }
                $script:SelectionDescription = $selectedTask.Title
                break
            }

            if ($selection -match "^(Q|QUIT)$") {
                $script:ExitRequested = $true
                break
            }

            Write-Host "Ungueltige Auswahl. Bitte eine Nummer, 0 oder Q eingeben." -ForegroundColor Yellow
        }
    }

if ($script:ExitRequested) {
    break
}

# ============================================================
# STARTINFORMATIONEN

Write-Section "ALBIS SYSTEMCHECK - START"

Write-Status "Auswahl: $script:SelectionDescription"
Write-Status "Computername: $env:COMPUTERNAME"
Write-Status "Benutzer: $env:USERNAME"
Write-Status "PowerShell-Version: $($PSVersionTable.PSVersion)"
Write-Status "Startzeit: $(Get-Date)"
Write-Status "Protokoll: $script:LogFile"
#-------------------------------------------------------------

# ============================================================
# SYSTEMWIEDERHERSTELLUNG auf 9% und einen WP erstellen

if ($script:SelectedTaskIds -contains "system-restore") {
Write-Section "SYSTEMWIEDERHERSTELLUNG"

# Systemwiederherstellung fuer C: aktivieren
try {
    Enable-ComputerRestore -Drive "C:\" -ErrorAction Stop
    Write-Status "Systemschutz fuer Laufwerk C: wurde aktiviert" "OK"
}
catch {
    Write-Status "Systemschutz konnte nicht aktiviert werden: $_" "ERROR"
}

# Schattenkopiespeicher direkt auf 9% einstellen
Invoke-Critical "Schattenkopiespeicher fuer C: auf 9% einstellen" {
    & vssadmin.exe Resize ShadowStorage `
        /For=C: `
        /On=C: `
        /MaxSize=9%
        
    if ($LASTEXITCODE -ne 0) {
        throw "Schattenkopiespeicher konnte nicht auf 9% eingestellt werden."
    }
    Write-Status "Schattenkopiespeicher erfolgreich auf 9% gesetzt" "OK"
}

# Wiederherstellungspunkt mit Name AIS erstellen
Invoke-Critical "Wiederherstellungspunkt AIS erstellen" {
    Checkpoint-Computer `
        -Description "AIS" `
        -RestorePointType MODIFY_SETTINGS `
        -ErrorAction Stop

    Write-Status "Wiederherstellungspunkt AIS wurde erstellt" "OK"
}
}

# ============================================================
# ALBIS-REGISTRY-SICHERUNG HKEY_CURRENT_USER\SOFTWARE\ALBIS

if ($script:SelectedTaskIds -contains "registry-backup") {
Write-Section "REGISTRY-SICHERUNG"

try {
    # Sicherungsverzeichnis
    $BackupFolder = "C:\CGM"

    if (!(Test-Path -LiteralPath $BackupFolder)) {

        New-Item `
            -Path $BackupFolder `
            -ItemType Directory `
            -Force |
            Out-Null
    }

    # Datum und Uhrzeit fuer Dateinamen
    $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    # Dateiname
    $BackupFile = Join-Path `
        $BackupFolder `
        "Registry_HKCU_Software_ALBIS_$Timestamp.reg"

    # Registry exportieren
    $ExportResult = & reg.exe export `
        "HKCU\Software\ALBIS" `
        $BackupFile `
        /y 2>&1
    if ($LASTEXITCODE -ne 0) {

        throw "Registry-Export fehlgeschlagen: $ExportResult"
    }

    # Pruefen, ob Sicherungsdatei existiert
    if (
        !(Test-Path -LiteralPath $BackupFile) -or
        (Get-Item -LiteralPath $BackupFile).Length -eq 0
    ) {

        throw "Sicherungsdatei wurde nicht korrekt erstellt"
    }

    $BackupSize = [math]::Round(
        (Get-Item -LiteralPath $BackupFile).Length / 1KB,
        2
    )

    Write-Status "Registry-Sicherung erfolgreich erstellt" "OK"
    Write-Status "Datei: $BackupFile" "OK"
    Write-Status "Dateigröße: $BackupSize KB" "INFO"

    $script:Changes++
}
catch {

    Write-Status (
        "Registry-Sicherung fehlgeschlagen: $_"
    ) "ERROR"
}
}

# ============================================================
# ALBIS-DATEIEN ALS ZIP SICHERN

if ($script:SelectedTaskIds -contains "albis-backup") {
Write-Section "ALBIS-DATEIEN ALS ZIP SICHERN"

$archivePathCreated = $false
try {
    $backupFolder = "C:\CGM"
    if (-not (Test-Path -LiteralPath $backupFolder -PathType Container)) {
        New-Item -Path $backupFolder -ItemType Directory -Force |
            Out-Null
    }

    $entries = @(Get-AlbisBackupEntries -InstallInfos $script:AlbisInstallInfos)
    if ($entries.Count -eq 0) {
        throw "Keine vorhandenen local.ini- oder albisglb.ini-Dateien zum Sichern gefunden."
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
    $backupFile = Join-Path $backupFolder "ALBIS_Sicherung_$timestamp.zip"
    $suffix = 1
    while ($true) {
        try {
            $archiveStream = [System.IO.File]::Open(
                $backupFile,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            $archivePathCreated = $true
            break
        }
        catch [System.IO.IOException] {
            if (-not (Test-Path -LiteralPath $backupFile)) {
                throw
            }
            $backupFile = Join-Path $backupFolder (
                "ALBIS_Sicherung_{0}_{1:D2}.zip" -f $timestamp, $suffix
            )
            $suffix++
        }
    }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipArchive]::new(
            $archiveStream,
            [System.IO.Compression.ZipArchiveMode]::Create
        )
        try {
            foreach ($entry in $entries) {
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $archive,
                    $entry.SourcePath,
                    $entry.EntryName
                ) | Out-Null
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $archiveStream.Dispose()
    }

    foreach ($installInfo in $script:AlbisInstallInfos) {
        if (-not $installInfo.LocalIniExists) {
            Write-Status "Nicht gesichert, local.ini fehlt: $($installInfo.LocalIniPath)" "WARN"
        }
        elseif (-not $installInfo.MainPathValid) {
            Write-Status "Nur local.ini gesichert; Main=-Pfad ist leer oder ungueltig: $($installInfo.LocalIniPath)" "WARN"
        }
        elseif (-not $installInfo.ServerIniExists) {
            Write-Status "Nur local.ini gesichert; albisglb.ini fehlt: $($installInfo.ServerIniPath)" "WARN"
        }
    }

    Write-Status "ALBIS-Sicherung erstellt: $backupFile" "OK"
    Write-Status "ZIP-Eintraege: $($entries.EntryName -join ', ')" "INFO"
    $script:Changes++
}
catch {
    if ($archivePathCreated -and (Test-Path -LiteralPath $backupFile)) {
        Remove-Item -LiteralPath $backupFile -Force
    }
    Write-Status "ALBIS-Dateisicherung fehlgeschlagen: $_" "ERROR"
}
}

# ============================================================
# SMB KONFIGURATION pruefen

if ($script:SelectedTaskIds -contains "smb") {

Write-Section "SMB KONFIGURATION"

Write-Status "SMB-Serverkonfiguration" "INFO"

try {
    $smbServer = Get-SmbServerConfiguration -ErrorAction Stop

    $serverProperties = @(
        "EnableSMB1Protocol",
        "EnableSMB2Protocol",
        "EnableSecuritySignature",
        "RequireSecuritySignature",
        "EncryptData",
        "RejectUnencryptedAccess",
        "EnableMultiChannel",
        "EnableLeasing",
        "EnableOplocks",
        "DurableHandleV2TimeoutInSeconds",
        "AutoDisconnectTimeout",
        "MaxMpxCount",
        "MaxWorkItems",
        "Smb2CreditsMax",
        "Smb2CreditsMin"
    )
    foreach ($property in $serverProperties) {

        $value = $smbServer.$property

        if ($null -ne $value) {

            Write-Status (
                "SMB Server | $property = $value"
            ) "INFO"
        }
    }
}
catch {

    Write-Status (
        "SMB-Serverkonfiguration nicht lesbar: $_"
    ) "WARN"
}

Write-Status "SMB-Clientkonfiguration" "INFO"

try {
    $smbClient = Get-SmbClientConfiguration -ErrorAction Stop

    $clientProperties = @(
        "EnableSecuritySignature",
        "RequireSecuritySignature",
        "EnableInsecureGuestLogons",
        "EnableLargeMtu",
        "EnableMultiChannel",
        "DirectoryCacheLifetime",
        "FileInfoCacheLifetime",
        "FileNotFoundCacheLifetime",
        "KeepConn",
        "SessionTimeout",
        "OplocksDisabled",
        "RequireEncryption",
        "ConnectionCountPerRssNetworkInterface"
    )
    foreach ($property in $clientProperties) {

        $value = $smbClient.$property

        if ($null -ne $value) {

            Write-Status (
                "SMB Client | $property = $value"
            ) "INFO"
        }
    }
}
catch {
    Write-Status (
        "SMB-Clientkonfiguration nicht lesbar: $_"
    ) "WARN"
}

# ------------------------------------------------------------
# SMB AKTIVE VERBINDUNGEN pruefen

Write-Status "Aktive SMB-Verbindungen" "INFO"

try {
    $smbConnections = @(
        Get-SmbConnection -ErrorAction Stop
    )

    if ($smbConnections.Count -gt 0) {

        foreach ($connection in $smbConnections) {

            Write-Status (
                "SMB Verbindung | Server: $($connection.ServerName) | " +
                "Freigabe: $($connection.ShareName) | " +
                "Benutzer: $($connection.UserName) | " +
                "Dialect: $($connection.Dialect) | " +
                "Signiert: $($connection.Signed) | " +
                "Verschluesselt: $($connection.Encrypted)"
            ) "INFO"
        }
    }
    else {

        Write-Status (
            "Keine aktiven SMB-Verbindungen gefunden"
        ) "INFO"
    }
}
catch {

    Write-Status (
        "SMB-Verbindungen konnten nicht gelesen werden: $_"
    ) "WARN"
}

# ------------------------------------------------------------
# SMB SERVER FREIGABEN pruefen

Write-Status "SMB-Freigaben" "INFO"

try {
    $smbShares = @(
        Get-SmbShare -ErrorAction Stop |
        Where-Object {
            -not $_.Special
        }
    )
    if ($smbShares.Count -gt 0) {

        foreach ($share in $smbShares) {

            Write-Status (
                "Freigabe: $($share.Name) | " +
                "Pfad: $($share.Path) | " +
                "Verschluesselt: $($share.EncryptData)"
            ) "INFO"
        }
    }
    else {

        Write-Status (
            "Keine benutzerdefinierten SMB-Freigaben vorhanden"
        ) "INFO"
    }
}
catch {

    Write-Status (
        "SMB-Freigaben konnten nicht gelesen werden: $_"
    ) "WARN"
}

# ------------------------------------------------------------
# SMB MULTICHANNEL pruefen

Write-Status "SMB Multichannel" "INFO"

try {
    $multiChannel = @(
        Get-SmbMultichannelConnection -ErrorAction Stop
    )
    if ($multiChannel.Count -gt 0) {

        foreach ($channel in $multiChannel) {

            Write-Status (
                "Multichannel | Server: $($channel.ServerName) | " +
                "Client-IP: $($channel.ClientIpAddress) | " +
                "Server-IP: $($channel.ServerIpAddress) | " +
                "RSS: $($channel.ClientRssCapable) | " +
                "RDMA: $($channel.ClientRdmaCapable)"
            ) "INFO"
        }
    }
    else {

        Write-Status (
            "Keine aktiven SMB-Multichannel-Verbindungen"
        ) "INFO"
    }
}
catch {
    Write-Status (
        "SMB-Multichannel-Status nicht verfuegbar: $_"
    ) "WARN"
}
}

# ============================================================
# TCP KONFIGURATION pruefen

if ($script:SelectedTaskIds -contains "tcp") {
Write-Section "TCP KONFIGURATION"

# TCP GLOBALE EINSTELLUNGEN

Write-Status "Globale TCP-Konfiguration" "INFO"

try {
    $tcpGlobal = & netsh.exe int tcp show global 2>&1

    foreach ($line in $tcpGlobal) {

        Write-Status (
            "TCP Global | $line"
        ) "INFO"
    }
}
catch {
    Write-Status (
        "Globale TCP-Einstellungen nicht lesbar: $_"
    ) "WARN"
}

# TCP HEURISTIKEN anzeigen

Write-Status "TCP Heuristiken" "INFO"

try {
    $tcpHeuristics = & netsh.exe int tcp show heuristics 2>&1

    foreach ($line in $tcpHeuristics) {
        Write-Status (
            "TCP Heuristics | $line"
        ) "INFO"
    }
}
catch {

    Write-Status (
        "TCP-Heuristiken nicht lesbar: $_"
    ) "WARN"
}

# TCP SETTINGS PROFILE anzeigen

Write-Status "TCP-Einstellungsprofile" "INFO"

try {
    $tcpSettings = @(
        Get-NetTCPSetting -ErrorAction Stop
    )

    foreach ($setting in $tcpSettings) {

        Write-Status (
            "TCP Profil | $($setting.SettingName) | " +
            "Congestion: $($setting.CongestionProvider) | " +
            "AutoTuning: $($setting.AutoTuningLevelLocal) | " +
            "Scaling: $($setting.WindowScaling) | " +
            "ECN: $($setting.EcnCapability) | " +
            "Timestamps: $($setting.Timestamps) | " +
            "InitialRTO: $($setting.InitialRtoMs)"
        ) "INFO"
    }
}
catch {

    Write-Status (
        "TCP-Einstellungsprofile nicht lesbar: $_"
    ) "WARN"
}

# AKTIVE TCP VERBINDUNGEN

Write-Status "Aktive TCP-Verbindungen" "INFO"

try {
    $tcpConnections = @(
        Get-NetTCPConnection -ErrorAction Stop
    )
    if ($tcpConnections.Count -gt 0) {

        $tcpStates = $tcpConnections |
            Group-Object -Property State

        foreach ($state in $tcpStates) {

            Write-Status (
                "TCP Status | $($state.Name): " +
                "$($state.Count) Verbindungen"
            ) "INFO"
        }
        Write-Status (
            "TCP Gesamtverbindungen: $($tcpConnections.Count)"
        ) "INFO"
    }
    else {
        Write-Status (
            "Keine TCP-Verbindungen gefunden"
        ) "INFO"
    }
}
catch {
    Write-Status (
        "TCP-Verbindungen konnten nicht gelesen werden: $_"
    ) "WARN"
}

# TCP NETZWERKADAPTER anzeigen

Write-Status "TCP Netzwerkadapter" "INFO"

try {
    $tcpInterfaces = @(
        Get-NetIPInterface -ErrorAction Stop |
        Where-Object {
            $_.ConnectionState -eq "Connected"
        }
    )
    foreach ($interface in $tcpInterfaces) {

        Write-Status (
            "Adapter: $($interface.InterfaceAlias) | " +
            "Familie: $($interface.AddressFamily) | " +
            "InterfaceIndex: $($interface.InterfaceIndex) | " +
            "MTU: $($interface.NlMtu) | " +
            "Metrik: $($interface.InterfaceMetric) | " +
            "DHCP: $($interface.Dhcp) | " +
            "Forwarding: $($interface.Forwarding)"
        ) "INFO"
    }
}
catch {

    Write-Status (
        "TCP-Netzwerkadapter konnten nicht gelesen werden: $_"
    ) "WARN"
}

# TCP RSS / RECEIVE SIDE SCALING anzeigen

Write-Status "TCP Receive Side Scaling (RSS)" "INFO"

try {
    $rssAdapters = @(
        Get-NetAdapterRss -ErrorAction Stop
    )
    foreach ($rss in $rssAdapters) {

        Write-Status (
            "RSS | Adapter: $($rss.Name) | " +
            "Enabled: $($rss.Enabled) | " +
            "NumberOfReceiveQueues: $($rss.NumberOfReceiveQueues) | " +
            "Profile: $($rss.Profile)"
        ) "INFO"
    }
}
catch {

    Write-Status (
        "RSS-Einstellungen konnten nicht gelesen werden: $_"
    ) "WARN"
}

# TCP OFFLOAD EINSTELLUNGEN anzeigen

Write-Status "TCP Offload Einstellungen" "INFO"

try {
    $offloadAdapters = @(
        Get-NetAdapterLso -ErrorAction Stop
    )

    foreach ($offload in $offloadAdapters) {

        Write-Status (
            "LSO | Adapter: $($offload.Name) | " +
            "IPv4: $($offload.IPv4Enabled) | " +
            "IPv6: $($offload.IPv6Enabled)"
        ) "INFO"
    }
}
catch {

    Write-Status (
        "LSO-Einstellungen konnten nicht gelesen werden: $_"
    ) "WARN"
}

# TCP CHECKSUM OFFLOAD anzeigen

Write-Status "TCP Checksum Offload" "INFO"

try {
    $checksumAdapters = @(
        Get-NetAdapterChecksumOffload -ErrorAction Stop
    )
    foreach ($checksum in $checksumAdapters) {

        Write-Status (
            "Checksum | Adapter: $($checksum.Name) | " +
            "IPv4 TCP: $($checksum.TcpIPv4) | " +
            "IPv6 TCP: $($checksum.TcpIPv6) | " +
            "IPv4 UDP: $($checksum.UdpIPv4) | " +
            "IPv6 UDP: $($checksum.UdpIPv6)"
        ) "INFO"
    }
}
catch {

    Write-Status (
        "Checksum-Offload-Einstellungen nicht lesbar: $_"
    ) "WARN"
}

if ($script:SelectedTaskIds -contains "smb") {
    Write-Status "SMB- und TCP-Bestandsaufnahme abgeschlossen" "OK"
}
else {
    Write-Status "TCP-Bestandsaufnahme abgeschlossen" "OK"
}
}

# ============================================================
# WINDOWS VERSION PRUEFEN

if ($script:SelectedTaskIds -contains "windows-version") {
Write-Section "WINDOWS VERSION"

$os = Get-CimInstance Win32_OperatingSystem

$reg = Get-ItemProperty `
    "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"

$displayVersion = $reg.DisplayVersion
$build = [int]$reg.CurrentBuildNumber
$ubr = [int]$reg.UBR

Write-Status "Windows: $($os.Caption)"
Write-Status "Version: $displayVersion"
Write-Status "Build: $build.$ubr"
Write-Status "Installationsdatum: $($os.InstallDate)"

if (
    $os.Caption -match "Windows 11" -and
    $build -ge 22000
) {
    Write-Status "Windows 11 erkannt: $displayVersion, Build $build.$ubr" "OK"
}
else {
    Write-Status (
        "Windows 11 wird nicht erkannt! " +
        "Installierte Version: $displayVersion, Build $build.$ubr"
    ) "ERROR"
}
}

# ============================================================
# RUSTDESK INSTALLATION pruefen

if ($script:SelectedTaskIds -contains "rustdesk-check") {
Write-Section "RUSTDESK INSTALLATION"

$rustDeskDownloadUrl = "https://rustdesk.com/download/"
$rustDeskExePaths = @(
    Join-Path ([Environment]::GetFolderPath("ProgramFiles")) "RustDesk\RustDesk.exe"
    Join-Path ([Environment]::GetFolderPath("ProgramFilesX86")) "RustDesk\RustDesk.exe"
    Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Programs\RustDesk\RustDesk.exe"
)
$rustDeskExe = $rustDeskExePaths |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
    Select-Object -First 1

$rustDeskRegistryLocations = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)
$rustDeskRegistryEntries = @()
$rustDeskRegistryCheckFailed = $false
foreach ($registryLocation in $rustDeskRegistryLocations) {
    try {
        if (Test-Path -LiteralPath $registryLocation -ErrorAction Stop) {
            $rustDeskRegistryEntries += Get-ChildItem `
                -LiteralPath $registryLocation `
                -ErrorAction Stop |
                ForEach-Object {
                    Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
                }
        }
    }
    catch {
        $rustDeskRegistryCheckFailed = $true
        Write-Status (
            "RustDesk-Registry konnte nicht vollstaendig geprueft werden: $_"
        ) "ERROR"
    }
}
$rustDeskEntry = $rustDeskRegistryEntries |
    Where-Object { $_.DisplayName -match '^RustDesk(?:\s|$)' } |
    Select-Object -First 1

if ($rustDeskExe) {
    Write-Status "RustDesk ist installiert: $rustDeskExe" "OK"
}
elseif ($rustDeskEntry) {
    Write-Status "RustDesk ist installiert: $($rustDeskEntry.DisplayName)" "OK"
}
elseif ($rustDeskRegistryCheckFailed) {
    Write-Status "RustDesk-Installation konnte nicht sicher festgestellt werden." "ERROR"
}
else {
    Write-Status "RustDesk wurde nicht gefunden. Offizielle Download-Seite: $rustDeskDownloadUrl" "WARN"
    try {
        Start-Process -FilePath $rustDeskDownloadUrl -ErrorAction Stop
    }
    catch {
        Write-Status "Offizielle Download-Seite konnte nicht geoeffnet werden: $_" "ERROR"
    }
}
}

# ============================================================
# ARBEITSSPEICHER MIN 16 GB und Auslastung MAX 75%

if ($script:SelectedTaskIds -contains "memory") {
Write-Section "ARBEITSSPEICHER"

$memory = Get-CimInstance Win32_OperatingSystem

$totalRAM = [math]::Round(
    $memory.TotalVisibleMemorySize / 1MB, 2
)

$freeRAM = [math]::Round(
    $memory.FreePhysicalMemory / 1MB, 2
)

$freePercent = [math]::Round(
    ($memory.FreePhysicalMemory /
    $memory.TotalVisibleMemorySize) * 100, 1
)

Write-Status "Gesamter RAM: $totalRAM GB"
Write-Status "Freier RAM: $freeRAM GB"
Write-Status "Frei: $freePercent %"

if ($totalRAM -ge 16 -and $freePercent -ge 35) {

    Write-Status "RAM-Anforderungen erfuellt" "OK"
}
else {
    Write-Status (
        "RAM-Anforderungen nicht erfuellt. " +
        "Mindestens 16 GB und 35% frei erforderlich."
    ) "ERROR"
}
}

# ============================================================
# FREIER HDD-SPEICHERPLATZ MIND 10 GB pruefen

if ($script:SelectedTaskIds -contains "disk-space") {

Write-Section "FREIER SPEICHERPLATZ"

$disks = @(
    Get-CimInstance Win32_LogicalDisk |
    Where-Object {
        $_.DriveType -in @(3,4)
    }
)
if ($disks.Count -eq 0) {
    Write-Status "Keine Laufwerke gefunden" "WARN"
}
foreach ($disk in $disks) {
    $freeGB = [math]::Round(
        $disk.FreeSpace / 1GB, 2
    )
    $totalGB = [math]::Round(
        $disk.Size / 1GB, 2
    )
    if ($freeGB -ge 10) {
        Write-Status (
            "$($disk.DeviceID): $freeGB GB frei von $totalGB GB"
        ) "OK"
    }
    else {
        Write-Status (
            "$($disk.DeviceID): Nur $freeGB GB frei von $totalGB GB"
        ) "ERROR"
    }
}
}

# ============================================================
# BITLOCKER-STATUS UND RECOVERY-KEY

if ($script:SelectedTaskIds -contains "bitlocker") {

Write-Section "BITLOCKER-STATUS"

$bitLockerCommand = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
if (-not $bitLockerCommand) {
    try {
        Import-Module BitLocker -ErrorAction Stop
        $bitLockerCommand = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
    }
    catch {
        $bitLockerCommand = $null
    }
}

if (-not $bitLockerCommand) {
    Write-Status "BitLocker kann nicht geprueft werden: BitLocker-Modul oder Cmdlet nicht verfuegbar" "WARN"
}
else {
    try {
        $bitLockerVolumes = @(Get-BitLockerVolume -ErrorAction Stop)
        $encryptedVolumes = @(
            $bitLockerVolumes | Where-Object {
                ([string]$_.VolumeStatus) -in @(
                    "FullyEncrypted",
                    "EncryptionInProgress",
                    "EncryptionPaused",
                    "DecryptionInProgress",
                    "DecryptionPaused"
                )
            }
        )

        if ($encryptedVolumes.Count -eq 0) {
            Write-Status "BitLocker ist auf keinem Laufwerk aktiv" "OK"
        }
        else {
            foreach ($volume in $encryptedVolumes) {
                if ([string]$volume.ProtectionStatus -ne "On") {
                    Write-Status (
                        "BitLocker auf $($volume.MountPoint): Verschluesselung vorhanden, Schutz ist nicht aktiv"
                    ) "WARN"
                    continue
                }

                Write-Status "BitLocker auf $($volume.MountPoint) ist aktiv" "OK"
                $recoveryProtectors = @(
                    $volume.KeyProtector | Where-Object {
                        [string]$_.KeyProtectorType -eq "RecoveryPassword" -and
                        -not [string]::IsNullOrWhiteSpace($_.RecoveryPassword)
                    }
                )

                if ($recoveryProtectors.Count -eq 0) {
                    Write-Status (
                        "Kein Recovery-Passwort-Protector auf $($volume.MountPoint) gefunden"
                    ) "WARN"
                    continue
                }

                if (-not [Environment]::UserInteractive -or -not $Host -or -not $Host.UI -or -not $Host.UI.RawUI) {
                    Write-Status "Recovery-Keys werden nur nach Bestaetigung in einer interaktiven Konsole angezeigt" "WARN"
                    continue
                }

                foreach ($protector in $recoveryProtectors) {
                    Write-Host ""
                    Write-Host (
                        "Der Recovery-Key fuer $($volume.MountPoint) ist ein sensibles Geheimnis."
                    ) -ForegroundColor Yellow
                    Write-Host "Er wird nicht in die Protokolldatei geschrieben." -ForegroundColor Yellow
                    $showRecoveryKey = Read-Host "Recovery-Key jetzt in der Konsole anzeigen? (J/N)"

                    if ($showRecoveryKey -match "^(J|JA|Y|YES)$") {
                        $recoveryKey = $protector.RecoveryPassword
                        Write-Host "Recovery-Key fuer $($volume.MountPoint):" -ForegroundColor Red
                        Write-Host $recoveryKey -ForegroundColor Red
                        $recoveryKey = $null
                    }
                    else {
                        Write-Host "Recovery-Key wurde nicht angezeigt." -ForegroundColor Cyan
                    }
                }
            }
        }
    }
    catch {
        Write-Status "BitLocker-Status konnte nicht gelesen werden; Details wurden aus Sicherheitsgruenden nicht protokolliert" "ERROR"
    }
    finally {
        $bitLockerVolumes = $null
        $encryptedVolumes = $null
        $recoveryProtectors = $null
        $volume = $null
        $protector = $null
        $recoveryKey = $null
    }
}
}

# ============================================================
# HOSTS DATEI pruefen auf manuelle Werte

if ($script:SelectedTaskIds -contains "hosts-file") {
Write-Section "HOSTS DATEI"

$hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"

if (Test-Path $hostsFile) {

    $hostsEntries = @(
        Get-Content -LiteralPath $hostsFile |
        Where-Object {
            $_.Trim() -and $_.Trim() -notmatch "^#"
        }
    )
    $customHosts = @(
        $hostsEntries | Where-Object {
            $_ -notmatch (
                "^\s*(127\.0\.0\.1|::1)\s+" +
                "localhost(\s|$)"
            )
        }
    )
    if ($customHosts.Count -gt 0) {

        Write-Status (
            "$($customHosts.Count) zusaetzliche Hosts-Eintraege gefunden"
        ) "INFO"
        foreach ($entry in $customHosts) {
            $parts = $entry.Trim() -split "\s+"
            $ip = $null
            if (
                $parts.Count -ge 2 -and
                [System.Net.IPAddress]::TryParse(
                    $parts[0], [ref]$ip
                )
            ) {

                Write-Status "Hosts-Eintrag: $entry" "OK"
            }
            else {

                Write-Status (
                    "Ungueltiger Hosts-Eintrag: $entry"
                ) "ERROR"
            }
        }
    }
    else {
    Write-Status (
        "Keine zusaetzlichen Hosts-Eintraege gefunden"
    ) "WARN"
}
}
else {
    Write-Status "Hosts-Datei nicht gefunden" "ERROR"
}
# Pause und auf beliebige Taste warten
Write-Host ""
if ([Environment]::UserInteractive -and $Host -and $Host.UI -and $Host.UI.RawUI) {
    Write-Host "Druecken Sie eine beliebige Taste, um fortzufahren..." -ForegroundColor Cyan
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Host ""
}
else {
    Write-Status "Pause uebersprungen: Nicht-interaktive Umgebung" "WARN"
}
}

# ============================================================
# Win11-EDITOR DATENSCHUTZ UND BENUTZBARKEIT
# Microsoft Notepad - Settings import to PC

if ($script:SelectedTaskIds -contains "notepad-settings") {
$Url = "https://www.rdm-systems.de/ais/editor/settings.dat"


$Target = Join-Path $env:LOCALAPPDATA `
    "Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\Settings\settings.dat"

$TempFile = Join-Path $env:TEMP "Notepad-Settings.dat"

Write-Host ""
Write-Host "Microsoft Notepad - Settings Import" -ForegroundColor Cyan
Write-Host "-----------------------------------"

if (-not (Confirm-Critical "Notepad-Einstellungen importieren?")) {
    Write-Status "Notepad-Settings-Import abgebrochen" "WARN"
}
else {
    if (Get-Process Notepad -ErrorAction SilentlyContinue) {
        Write-Status "Notepad ist noch aktiv. Bitte vor dem Import schließen." "WARN"
    }
    else {
        try {
            # Download settings
            Write-Host ""
            Write-Host "Downloading settings ..."

            Invoke-WebRequest -Uri $Url -OutFile $TempFile `
                -UseBasicParsing -ErrorAction Stop

            if (!(Test-Path $TempFile) -or
                (Get-Item $TempFile).Length -eq 0) {
                throw "Download failed or file is empty."
            }

            # Import settings without backup
            Copy-Item $TempFile $Target -Force

            Write-Host ""
            Write-Host "Import completed successfully!" -ForegroundColor Green
            Write-Host "You can now start Notepad."
        }
        catch {
            Write-Host ("Import error: " + $_.Exception.Message) -ForegroundColor Red
            Write-Status ("Notepad-Import fehlgeschlagen: $_") "ERROR"
        }
        finally {
            Remove-Item $TempFile -Force -ErrorAction SilentlyContinue
        }
    }
}
}


# ============================================================
# DATUM UND UHRZEIT / NTP sync

if ($script:SelectedTaskIds -contains "time-sync") {
$NtpServer = "ptbtime1.ptb.de"

Write-Section "ZEITSYNCHRONISATION"

try {
    Write-Status "NTP-Server: $NtpServer" "INFO"

    # Zeitserver konfigurieren

    & w32tm.exe /config `
        /manualpeerlist:"$NtpServer,0x8" `
        /syncfromflags:manual `
        /update 2>&1 |
        ForEach-Object {
            Write-Status "$_" "INFO"
        }

    if ($LASTEXITCODE -ne 0) {
        throw "NTP-Konfiguration fehlgeschlagen"
    }

    # Windows-Zeitdienst neu starten

    Restart-Service W32Time -Force -ErrorAction Stop

    Start-Sleep -Seconds 3

    # Zeit synchronisieren

    $syncResult = & w32tm.exe /resync /force 2>&1

    foreach ($line in $syncResult) {
        Write-Status "$line" "INFO"
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Zeit-Synchronisierung fehlgeschlagen"
    }

    Write-Status (
        "Zeitsynchronisierung mit $NtpServer erfolgreich"
    ) "OK"

    $script:Changes++
}
catch {

    Write-Status (
        "Zeitsynchronisierung fehlgeschlagen: $_"
    ) "ERROR"
}

# Synchronisierungsstatus kontrollieren

try {

    $timeStatus = & w32tm.exe /query /status 2>&1

    foreach ($line in $timeStatus) {
        Write-Status "$line" "INFO"
    }
}
catch {

    Write-Status (
        "Zeitstatus konnte nicht gelesen werden: $_"
    ) "WARN"
}
}

# ============================================================
# WINDOWS DEFENDER AUSNAHMEN nur PRUEFEN

if ($script:SelectedTaskIds -contains "defender-exclusions") {

Write-Section "WINDOWS DEFENDER AUSNAHMEN"

$required = @(
    "ALBIS.exe",
    "ALBISCS.exe"
)
$defenderQuerySucceeded = $false
try {
    $defender = Get-MpPreference -ErrorAction Stop
    $defenderQuerySucceeded = $true
}
catch {
    Write-Status (
        "Defender-Einstellungen konnten nicht gelesen werden; Ausnahmen sind nicht verifizierbar."
    ) "WARN"
}

foreach ($exe in $required) {
    if (!$defenderQuerySucceeded) {
        Write-Status (
            "Defender-Prozessausnahme nicht verifizierbar: $exe"
        ) "WARN"
        continue
    }

    $found = @(
        $defender.ExclusionProcess |
        Where-Object {
            [System.IO.Path]::GetFileName($_) -ieq $exe
        }
    ).Count -gt 0

    if ($found) {
        Write-Status (
            "Defender-Prozessausnahme vorhanden: $exe"
        ) "OK"
    }
    else {
        Write-Status (
            "Defender-Prozessausnahme FEHLT: $exe"
        ) "ERROR"
    }
}
}

# ============================================================
# IPv6 und QoS-Paketplaner ausschalten (beta)

if ($script:SelectedTaskIds -contains "ipv6-qos") {
$Components = @(
    @{
        Name = "IPv6"
        ComponentID = "ms_tcpip6"
    },
    @{
        Name = "QoS-Paketplaner"
        ComponentID = "ms_pacer"
    }
)

Write-Host "======================================" -ForegroundColor Cyan
Write-Host " Netzwerkadapter - Statuspruefung" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

foreach ($Component in $Components) {

    Write-Host "Pruefe: $($Component.Name)" -ForegroundColor Yellow

    $Bindings = Get-NetAdapterBinding `
        -ComponentID $Component.ComponentID `
        -ErrorAction SilentlyContinue

    if (-not $Bindings) {
        Write-Host "Keine entsprechenden Bindings gefunden." -ForegroundColor Gray
        continue
    }

    foreach ($Binding in $Bindings) {

        Write-Host "Adapter: $($Binding.Name)"

        if ($Binding.Enabled) {

            Write-Host "Status: AKTIVIERT" -ForegroundColor Green

            if (Confirm-Critical "Soll $($Component.Name) auf diesem Adapter deaktiviert werden?") {

                try {
                    Disable-NetAdapterBinding `
                        -Name $Binding.Name `
                        -ComponentID $Component.ComponentID `
                        -Confirm:$false `
                        -ErrorAction Stop

                    Write-Host "Erfolgreich deaktiviert." -ForegroundColor Green
                }
                catch {
                    Write-Host "Fehler: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
            else {
                Write-Host "Keine Aenderung vorgenommen." -ForegroundColor Gray
            }
        }
        else {
            Write-Host "Status: BEREITS DEAKTIVIERT - keine Aenderung." -ForegroundColor Gray
        }
    }
}

# Abschliessende Statusanzeige IPv6 , QOS

Write-Host "======================================" -ForegroundColor Cyan
Write-Host " Abschliessende Statuskontrolle" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

foreach ($Component in $Components) {
    Write-Host "$($Component.Name)" -ForegroundColor Yellow
    Get-NetAdapterBinding -ComponentID $Component.ComponentID |
        Format-Table Name, DisplayName, Enabled -AutoSize
}
Write-Host "Pruefung abgeschlossen." -ForegroundColor Cyan
}

if ($script:SelectedTaskIds -contains "uac") {
Write-Section "BENUTZERKONTENSTEUERUNG"

try {

    $UACPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"

    $UAC = Get-ItemProperty `
        -Path $UACPath `
        -Name EnableLUA `
        -ErrorAction Stop

    if ($UAC.EnableLUA -eq 1) {

        Write-Status "Benutzerkontensteuerung ist AKTIVIERT" "WARN"

        if (Confirm-Critical "Benutzerkontensteuerung deaktivieren?") {

            Set-ItemProperty `
                -Path $UACPath `
                -Name EnableLUA `
                -Value 0 `
                -Type DWord `
                -ErrorAction Stop

            Write-Status "Benutzerkontensteuerung wurde deaktiviert" "OK"

            Write-Host "Ein Windows-Neustart ist erforderlich!" -ForegroundColor Yellow
        }
        else {

            Write-Status "Benutzerkontensteuerung bleibt aktiviert" "WARN"
        }
    }
    else {
        Write-Status "Benutzerkontensteuerung ist bereits DEAKTIVIERT" "OK"
    }
}
catch {

    Write-Status "UAC-Pruefung fehlgeschlagen: $_" "ERROR"
}
}
# ============================================================
# Animationen, Transparenz, Bildlaufleisten

if ($script:SelectedTaskIds -contains "windows-ui") {
Write-Section "WINDOWS OBERFLAECHE"

Invoke-Critical "Animationen, Transparenz und Bildlaufleisten optimieren" {

# -------------------------------------------------------
# Animationen deaktivieren
 
    Set-RegistryValue `
        "HKCU:\Control Panel\Desktop\WindowMetrics" `
        "MinAnimate" `
        "0" `
        ([Microsoft.Win32.RegistryValueKind]::String)

    Set-RegistryValue `
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" `
        "VisualFXSetting" `
        2

    Set-RegistryValue `
        "HKCU:\Control Panel\Desktop" `
        "UserPreferencesMask" `
        ([byte[]](0x90,0x12,0x03,0x80,0x10,0,0,0)) `
        ([Microsoft.Win32.RegistryValueKind]::Binary)

# --------------------------------------------------------
# Transparenzeffekte deaktivieren


    Set-RegistryValue `
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" `
        "EnableTransparency" `
        0

# --------------------------------------------------------
# Bildlaufleisten immer anzeigen
# --------------------------------------------------------

    Set-RegistryValue `
        "HKCU:\Control Panel\Accessibility" `
        "DynamicScrollbars" `
        0

    Write-Status (
        "Animationen deaktiviert"
    ) "OK"

    Write-Status (
        "Transparenzeffekte deaktiviert"
    ) "OK"

    Write-Status (
        "Bildlaufleisten immer anzeigen aktiviert"
    ) "OK"
}
}

# ============================================================
# DIENST UEBERWACHUNG VERTEILTER VERKNUEPFUNGEN deaktivieren

if ($script:SelectedTaskIds -contains "distributed-links") {
Write-Section "DIENST VERTEILTE VERKNUEPFUNGEN"

$service = Get-Service `
    -Name "TrkWks" `
    -ErrorAction SilentlyContinue

if ($service) {
    try {
        if ($service.Status -ne "Stopped") {
            Stop-Service `
                -Name "TrkWks" `
                -Force `
                -ErrorAction Stop
        }
        Set-Service `
            -Name "TrkWks" `
            -StartupType Disabled `
            -ErrorAction Stop
        $serviceCheck = Get-Service -Name "TrkWks"

        if (
            $serviceCheck.Status -eq "Stopped"
        ) {
            Write-Status (
                "Dienst TrkWks beendet und deaktiviert"
            ) "OK"
        }
        else {

            Write-Status (
                "Dienst TrkWks ist noch aktiv"
            ) "ERROR"
        }
    }
    catch {

        Write-Status (
            "Dienst TrkWks konnte nicht deaktiviert werden: $_"
        ) "ERROR"
    }
}
else {

    Write-Status (
        "Dienst TrkWks nicht gefunden"
    ) "WARN"
}
}

# ============================================================
# ENERGIEVERWALTUNG aus und BILDSCHIRMSCHONER auf 10 Minuten

if ($script:SelectedTaskIds -contains "power") {
Write-Section "ENERGIEVERWALTUNG"

# Aktiven Energieplan ermitteln

$powerSchemeOutput = powercfg.exe /getactivescheme 2>&1

$schemeGuid = [regex]::Match(
    ($powerSchemeOutput -join " "),
    "[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}"
).Value

Write-Status "Aktiver Energieplan: $($powerSchemeOutput -join ' ')"

# Einstellungen anzeigen

$powerStates = powercfg.exe /a 2>&1

foreach ($line in $powerStates) {
    Write-Status "$line"
}

# ------------------------------------------------------------

Invoke-Critical "Standby, Monitorabschaltung und Bildschirmschoner konfigurieren" {

    if (!$schemeGuid) {
        throw "Aktiver Energieplan konnte nicht ermittelt werden"
    }

    # --------------------------------------------------------
    # Monitor niemals automatisch ausschalten
    

    powercfg.exe /change monitor-timeout-ac 0
    if ($LASTEXITCODE -ne 0) {
        throw "Monitorabschaltung Netzbetrieb fehlgeschlagen"
    }

    powercfg.exe /change monitor-timeout-dc 0
    if ($LASTEXITCODE -ne 0) {
        throw "Monitorabschaltung Akkubetrieb fehlgeschlagen"
    }

    # --------------------------------------------------------
    # Automatischen Standby deaktivieren
   

    powercfg.exe /change standby-timeout-ac 0
    if ($LASTEXITCODE -ne 0) {
        throw "Standby Netzbetrieb fehlgeschlagen"
    }

    powercfg.exe /change standby-timeout-dc 0
    if ($LASTEXITCODE -ne 0) {
        throw "Standby Akkubetrieb fehlgeschlagen"
    }

    # --------------------------------------------------------
    # Automatischen Ruhezustand deaktivieren
   

    powercfg.exe /change hibernate-timeout-ac 0
    if ($LASTEXITCODE -ne 0) {
        throw "Ruhezustand Netzbetrieb fehlgeschlagen"
    }

    powercfg.exe /change hibernate-timeout-dc 0
    if ($LASTEXITCODE -ne 0) {
        throw "Ruhezustand Akkubetrieb fehlgeschlagen"
    }

    # --------------------------------------------------------
    # Energieplan direkt konfigurieren
   

    powercfg.exe /setacvalueindex $schemeGuid SUB_VIDEO VIDEOIDLE 0
    if ($LASTEXITCODE -ne 0) {
        throw "Monitorzeitlimit AC fehlgeschlagen"
    }

    powercfg.exe /setdcvalueindex $schemeGuid SUB_VIDEO VIDEOIDLE 0
    if ($LASTEXITCODE -ne 0) {
        throw "Monitorzeitlimit DC fehlgeschlagen"
    }

    powercfg.exe /setacvalueindex $schemeGuid SUB_SLEEP STANDBYIDLE 0
    if ($LASTEXITCODE -ne 0) {
        throw "Standbyzeitlimit AC fehlgeschlagen"
    }

    powercfg.exe /setdcvalueindex $schemeGuid SUB_SLEEP STANDBYIDLE 0
    if ($LASTEXITCODE -ne 0) {
        throw "Standbyzeitlimit DC fehlgeschlagen"
    }

    powercfg.exe /setacvalueindex $schemeGuid SUB_SLEEP HIBERNATEIDLE 0
    if ($LASTEXITCODE -ne 0) {
        throw "Ruhezustand AC fehlgeschlagen"
    }

    powercfg.exe /setdcvalueindex $schemeGuid SUB_SLEEP HIBERNATEIDLE 0
    if ($LASTEXITCODE -ne 0) {
        throw "Ruhezustand DC fehlgeschlagen"
    }

    powercfg.exe /setactive $schemeGuid
    if ($LASTEXITCODE -ne 0) {
        throw "Energieplan konnte nicht aktiviert werden"
    }

    # --------------------------------------------------------
    # BILDSCHIRMSCHONER NACH 10 MINUTEN an
   

    $screenPath = "HKCU:\Control Panel\Desktop"

    # Bildschirmschoner aktivieren

    Set-RegistryValue `
        $screenPath `
        "ScreenSaveActive" `
        "1" `
        ([Microsoft.Win32.RegistryValueKind]::String)

    # Wartezeit: 600 Sekunden = 10 Minuten

    Set-RegistryValue `
        $screenPath `
        "ScreenSaveTimeOut" `
        "600" `
        ([Microsoft.Win32.RegistryValueKind]::String)

    # Bildschirmschoner auswaehlen
    # Windows-Standard-Bildschirmschoner: Leerer Bildschirm

    Set-RegistryValue `
        $screenPath `
        "SCRNSAVE.EXE" `
        "$env:SystemRoot\System32\scrnsave.scr" `
        ([Microsoft.Win32.RegistryValueKind]::String)

    # Kein Kennwortzwang bei Reaktivierung erzwingen
    # Vorhandene Kennworteinstellung bleibt unveraendert.

    Write-Status "Monitorabschaltung deaktiviert" "OK"
    Write-Status "Automatischer Standby deaktiviert" "OK"
    Write-Status "Automatischer Ruhezustand deaktiviert" "OK"
    Write-Status "Bildschirmschoner aktiviert: 10 Minuten" "OK"
}

# KONTROLLE ENERGIE

Write-Section "KONTROLLE ENERGIEVERWALTUNG"

$powerQuery = powercfg.exe /query $schemeGuid 2>&1

foreach ($line in $powerQuery) {
    if ($line -match "VIDEOIDLE|STANDBYIDLE|HIBERNATEIDLE") {
        Write-Status "$line"
    }
}

# Bildschirmschoner kontrollieren

try {
    $screenSettings = Get-ItemProperty `
        -Path "HKCU:\Control Panel\Desktop"

    Write-Status (
        "Bildschirmschoner aktiv: $($screenSettings.ScreenSaveActive)"
    )
    Write-Status (
        "Bildschirmschoner Wartezeit: $($screenSettings.ScreenSaveTimeOut) Sekunden"
    )
    Write-Status (
        "Bildschirmschoner Datei: $($screenSettings.'SCRNSAVE.EXE')"
    )
}
catch {

    Write-Status "Bildschirmschoner-Pruefung fehlgeschlagen: $_" "ERROR"
}
}

# ============================================================
# RDP AKTIVIEREN

if ($script:SelectedTaskIds -contains "rdp") {
Write-Section "REMOTEDESKTOP"

Invoke-Critical "Windows-Remotedesktop aktivieren" {

    $RdpPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"

    # Remotedesktop aktivieren
    Set-ItemProperty `
        -Path $RdpPath `
        -Name "fDenyTSConnections" `
        -Value 0 `
        -Type DWord `
        -ErrorAction Stop

    # RDP-Dienst aktivieren
    Set-Service `
        -Name "TermService" `
        -StartupType Manual `
        -ErrorAction Stop

    Start-Service `
        -Name "TermService" `
        -ErrorAction Stop

    # Windows-Firewallregeln fuer Remotedesktop aktivieren
    Enable-NetFirewallRule `
        -DisplayGroup "Remotedesktop" `
        -ErrorAction Stop

    # Kontrolle
    $rdpStatus = Get-ItemProperty `
        -Path $RdpPath `
        -Name "fDenyTSConnections"

    if ($rdpStatus.fDenyTSConnections -ne 0) {
        throw "Remotedesktop konnte nicht aktiviert werden"
    }

    Write-Status "Remotedesktop erfolgreich aktiviert" "OK"
    Write-Status "RDP-Dienst gestartet" "OK"
    Write-Status "Firewallregeln fuer Remotedesktop aktiviert" "OK"
}
}

# ============================================================
# ENABLE LINKED CONNECTIONS

if ($script:SelectedTaskIds -contains "linked-connections") {
Write-Section "ENABLE LINKED CONNECTIONS"

$LinkedConnectionsPath = `
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"

try {
    $currentValue = (
        Get-ItemProperty `
            -Path $LinkedConnectionsPath `
            -Name EnableLinkedConnections `
            -ErrorAction SilentlyContinue
    ).EnableLinkedConnections

    if ($currentValue -ne 1) {

        Invoke-Critical "EnableLinkedConnections aktivieren" {

            Set-RegistryValue `
                -Path $LinkedConnectionsPath `
                -Name "EnableLinkedConnections" `
                -Value 1 `
                -Type ([Microsoft.Win32.RegistryValueKind]::DWord)

            Write-Status (
                "EnableLinkedConnections wurde aktiviert"
            ) "OK"

            Write-Status (
                "Ein Windows-Neustart ist erforderlich"
            ) "WARN"
        }
    }
    else {

        Write-Status (
            "EnableLinkedConnections ist bereits aktiviert"
        ) "OK"
    }
}
catch {

    Write-Status (
        "EnableLinkedConnections konnte nicht gesetzt werden: $_"
    ) "ERROR"
}
}

# ============================================================
# CGM Ordner BERECHTIGUNGEN pruefen und setzen JEDER

if ($script:SelectedTaskIds -contains "cgm-permissions") {
Write-Section "CGM BERECHTIGUNGEN"

$cgmPath = "C:\CGM"

if (Test-Path -LiteralPath $cgmPath) {

    $acl = Get-Acl -LiteralPath $cgmPath

    $hasFullControl = $false

    foreach ($rule in $acl.Access) {

        try {

            $sid = $rule.IdentityReference.Translate(
                [System.Security.Principal.SecurityIdentifier]
            )

            if (
                $sid.Value -eq "S-1-1-0" -and
                $rule.AccessControlType -eq "Allow" -and
                $rule.FileSystemRights -band
                [System.Security.AccessControl.FileSystemRights]::FullControl
            ) {

                $hasFullControl = $true
                break
            }
        }
        catch {
            continue
        }
    }

    if ($hasFullControl) {

        Write-Status (
            "Jeder besitzt bereits Vollzugriff auf C:\CGM"
        ) "OK"
    }
    else {

        Write-Status (
            "Vollzugriff fuer Jeder fehlt auf C:\CGM"
        ) "WARN"

        Invoke-Critical `
            "C:\CGM und Unterordner fuer Jeder mit Vollzugriff versehen" {

            $result = & icacls.exe "C:\CGM" `
                /grant "*S-1-1-0:(OI)(CI)F" `
                /T /C 2>&1

            foreach ($line in $result) {

                Add-Content -Path $script:LogFile `
                    -Value $line -Encoding UTF8
            }
            if ($LASTEXITCODE -ne 0) {
                throw "icacls meldet Fehler: Exitcode $LASTEXITCODE"
            }
        }
    }
}
else {

    Write-Status "Verzeichnis C:\CGM nicht vorhanden" "ERROR"
}
}

# ============================================================
# MTU 1300 pruefen und fragen

if ($script:SelectedTaskIds -contains "mtu") {
Write-Section "MTU NETZWERK"

$TargetMTU = 1300

try {
    $interfaces = @(
    Get-NetIPInterface |
    Where-Object {
        $_.ConnectionState -eq "Connected" -and
        $_.InterfaceAlias -notmatch "Loopback"
    }
)
    if ($interfaces.Count -gt 0) {

        foreach ($interface in $interfaces) {
            $Adapter = $interface.InterfaceAlias
            $Family  = $interface.AddressFamily
            $CurrentMTU = $interface.NlMtu

            Write-Status (
                "Adapter: $Adapter | " +
                "Familie: $Family | " +
                "MTU: $CurrentMTU Bytes"
            ) "OK"

            if ($CurrentMTU -ne $TargetMTU) {

                Write-Host ""
                Write-Host "MTU-Abweichung festgestellt!" -ForegroundColor Yellow
                Write-Host "Adapter:       $Adapter"
                Write-Host "Adressfamilie: $Family"
                Write-Host "Aktuelle MTU:  $CurrentMTU"
                Write-Host "Ziel-MTU:      $TargetMTU"
                Write-Host ""

                if (Confirm-Critical "MTU auf $TargetMTU setzen?") {

                    try {
                        Set-NetIPInterface `
                            -InterfaceIndex $interface.InterfaceIndex `
                            -AddressFamily $Family `
                            -NlMtuBytes $TargetMTU `
                            -ErrorAction Stop

                        $NewMTU = (
                            Get-NetIPInterface `
                                -InterfaceIndex $interface.InterfaceIndex `
                                -AddressFamily $Family
                        ).NlMtu

                        if ($NewMTU -eq $TargetMTU) {

                            Write-Status (
                                "$Adapter ($Family): MTU erfolgreich auf $NewMTU gesetzt"
                            ) "OK"
                        }
                        else {

                            Write-Status (
                                "$Adapter ($Family): MTU konnte nicht bestaetigt werden. Aktuell: $NewMTU"
                            ) "WARN"
                        }
                    }
                    catch {

                        Write-Status (
                            "MTU-Aenderung fehlgeschlagen: $_"
                        ) "ERROR"
                    }
                }
                else {

                    Write-Status (
                        "$Adapter ($Family): MTU unveraendert"
                    ) "WARN"
                }
            }
            else {

                Write-Status (
                    "$Adapter ($Family): MTU ist bereits korrekt"
                ) "OK"
            }
        }
    }
    else {
        Write-Status (
            "Keine aktiven Netzwerkverbindungen gefunden"
        ) "WARN"
    }
}
catch {
    Write-Status "MTU-Pruefung fehlgeschlagen: $_" "ERROR"
}
}

# ============================================================
# NETZWERKPROFIL auf PRIVAT setzen
# was passiert wenn Domain?

if ($script:SelectedTaskIds -contains "network-profile") {

Write-Section "NETZWERKPROFIL"

try {

    $profiles = @(
        Get-NetConnectionProfile
    )

    foreach ($profile in $profiles) {

        Write-Status (
            "Netzwerk: $($profile.Name) | " +
            "Profil: $($profile.NetworkCategory)"
        )

        if ($profile.NetworkCategory -ne "Private") {

            $networkName = $profile.Name
            $interfaceIndex = $profile.InterfaceIndex

            Invoke-Critical `
                "Netzwerkprofil $networkName auf Privat setzen" {

                Set-NetConnectionProfile `
                    -InterfaceIndex $interfaceIndex `
                    -NetworkCategory Private `
                    -ErrorAction Stop

                $verify = Get-NetConnectionProfile `
                    -InterfaceIndex $interfaceIndex

                if ($verify.NetworkCategory -ne "Private") {

                    throw "Netzwerkprofil wurde nicht auf Privat gesetzt"
                }
            }
        }
        else {

            Write-Status (
                "$($profile.Name) ist bereits Privat"
            ) "OK"
        }
    }
}
catch {

    Write-Status (
        "Netzwerkprofil-Pruefung fehlgeschlagen: $_"
    ) "ERROR"
}
}

# ============================================================
# DEFENDER FIREWALL - PRIVATES PROFIL setzen
# was passiert bei Domain?

if ($script:SelectedTaskIds -contains "firewall-profile") {
Write-Section "WINDOWS DEFENDER FIREWALL"

try {
    $firewall = Get-NetFirewallProfile `
        -Profile Private `
        -ErrorAction Stop

    Write-Status (
        "Private Firewall aktiviert: $($firewall.Enabled)"
    )

    if ($firewall.Enabled) {

        Invoke-Critical `
            "Defender-Firewall fuer privates Netzwerk deaktivieren" {

            Set-NetFirewallProfile `
                -Profile Private `
                -Enabled False `
                -ErrorAction Stop

            $verify = Get-NetFirewallProfile -Profile Private

            if ($verify.Enabled) {

                throw "Firewall ist weiterhin aktiviert"
            }
        }
    }
    else {

        Write-Status (
            "Private Firewall bereits deaktiviert"
        ) "OK"
    }
}
catch {

    Write-Status (
        "Firewall-Einstellung fehlgeschlagen: $_"
    ) "ERROR"
}
}

# ============================================================
# FIREWALL-DIENST Restart, Aenderungen aktivieren/uebernehmen

if ($script:SelectedTaskIds -contains "firewall-service") {
Write-Section "FIREWALL DIENST"

# WICHTIG:
# MpsSvc ist ein geschuetzter Windows-Dienst.
# Ein erzwungener Neustart kann von Windows verweigert werden.
# Deshalb wird hier nur ein kontrollierter Neustart versucht.

try {
    $mpsService = Get-Service -Name "MpsSvc" `
        -ErrorAction Stop

    Write-Status (
        "Aktueller Dienststatus MpsSvc: $($mpsService.Status)"
    )

    if ($mpsService.Status -eq "Running") {

        Restart-Service `
            -Name "MpsSvc" `
            -ErrorAction Stop

        Write-Status (
            "Firewall-Dienst wurde neu gestartet"
        ) "OK"
    }
    else {

        Write-Status (
            "MpsSvc ist nicht gestartet. " +
            "Ein Start wird nicht erzwungen."
        ) "WARN"
    }
}
catch {

    Write-Status (
        "MpsSvc konnte nicht neu gestartet werden: $_"
    ) "WARN"
}
}

# ============================================================
# WINDOWS SMART APP CONTROL aus

if ($script:SelectedTaskIds -contains "smart-app-control") {
Write-Section "WINDOWS SMART APP CONTROL"

try {
    $SmartAppPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy"

    $SmartApp = Get-ItemProperty `
        -Path $SmartAppPath `
        -ErrorAction Stop

    $SmartAppState = $SmartApp.SmartAppControlState

    switch ($SmartAppState) {

        0 {
            Write-Status "Smart App Control: AUS" "OK"
        }

        1 {
            Write-Status "Smart App Control: ERZWUNGEN / AKTIV" "WARN"
        }

        2 {
            Write-Status "Smart App Control: AUSWERTUNGSMODUS" "INFO"
        }

        default {
            Write-Status "Smart App Control: Unbekannter Status ($SmartAppState)" "WARN"
        }
    }

    Write-Status "Smart App Control Statuspruefung abgeschlossen" "OK"
}
catch {

    Write-Status "Smart App Control Status konnte nicht ermittelt werden: $_" "WARN"
}
}


# ============================================================
# WINDOWS SPEICHEROPTIMIERUNG daily

if ($script:SelectedTaskIds -contains "storage-sense") {
Write-Section "WINDOWS SPEICHEROPTIMIERUNG"

# Storage Sense Registry-Konfiguration
# Die Werte werden fuer den angemeldeten Benutzer gesetzt.

$storagePath = `
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"

try {
    if (!(Test-Path $storagePath)) {
        New-Item -Path $storagePath -Force | Out-Null
    }
    $storagePolicy = Get-ItemProperty `
        -Path $storagePath `
        -ErrorAction SilentlyContinue

    Write-Status "Storage-Sense-Konfiguration wird geprueft"

    # Storage Sense aktivieren: 01 = Ein
    if ($storagePolicy."01" -ne 1) {

        Invoke-Critical "Windows-Speicheroptimierung aktivieren" {

            Set-RegistryValue `
                $storagePath `
                "01" `
                1
        }
    }
    else {

        Write-Status "Speicheroptimierung bereits aktiviert" "OK"
    }

    # Automatische Bereinigung temporaerer Dateien
    if ($storagePolicy."2048" -ne 1) {

        Set-RegistryValue `
            $storagePath `
            "2048" `
            1
    }

    # Storage Sense: Ausfuehrung bei geringem Speicherplatz
    # Fuer woechentliche Ausfuehrung ist die Storage-Sense-
    # Benutzeroberflaeche bzw. die entsprechende Richtlinie
    # massgeblich. Registrywerte allein sind kein sicherer
    # Nachweis fuer die eingestellte Frequenz.

    Write-Status (
        "Storage-Sense-Registrywerte wurden kontrolliert"
    ) "OK"
}
catch {
    Write-Status (
        "Speicheroptimierung konnte nicht konfiguriert werden: $_"
    ) "ERROR"
}

# Storage Sense Aufgabenplanung anzeigen
try {
    $storageTasks = Get-ScheduledTask `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.TaskName -match "Storage|Sense"
        }
    foreach ($task in $storageTasks) {
        Write-Status (
            "Aufgabe: $($task.TaskName) | " +
            "Status: $($task.State)"
        )
    }
}
catch {
    Write-Status (
        "Storage-Sense-Aufgaben konnten nicht gelesen werden"
    ) "WARN"
}
}

# ============================================================
# TEMP ORDNER PRUEFEN 2 GB max

if ($script:SelectedTaskIds -contains "temp-folders") {

Write-Section "TEMP ORDNER"

function Get-FolderSizeGB {

    param(
        [string]$Path
    )
    if (!(Test-Path -LiteralPath $Path)) {

        return 0
    }
    try {
        $files = Get-ChildItem `
            -LiteralPath $Path `
            -Force `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue
        $size = (
            $files |
            Measure-Object -Property Length -Sum
        ).Sum

        if ($null -eq $size) {

            $size = 0
        }
        return [math]::Round(
            $size / 1GB, 2
        )
    }
    catch {

        Write-Status (
            "Fehler bei Groessenermittlung $Path : $_"
        ) "WARN"

        return 0
    }
}

function Clean-TempFolder {

    param(
        [string]$Path
    )

    if (!(Test-Path -LiteralPath $Path)) {

        Write-Status (
            "Temp-Ordner nicht vorhanden: $Path"
        ) "WARN"

        return
    }

    $size = Get-FolderSizeGB -Path $Path

    Write-Status (
        "$Path - Gesamtgroesse: $size GB"
    )

    if ($size -gt 2) {

        Write-Status (
            "Temp-Ordner ueberschreitet die Grenze von 2 GB"
        ) "WARN"

        if (
            Confirm-Critical (
                "Temp-Dateien in $Path bereinigen?"
            )
        ) {

            try {

                # Nur Inhalte loeschen, nicht den Temp-Ordner selbst.
                # Gesperrte Dateien werden uebersprungen.

                Get-ChildItem `
                    -LiteralPath $Path `
                    -Force `
                    -ErrorAction SilentlyContinue |
                    Remove-Item `
                        -Recurse `
                        -Force `
                        -ErrorAction SilentlyContinue

                $newSize = Get-FolderSizeGB -Path $Path

                Write-Status (
                    "Bereinigung abgeschlossen. Restgroesse: $newSize GB"
                ) "OK"

                if ($newSize -gt 2) {

                    Write-Status (
                        "Temp-Ordner liegt weiterhin ueber 2 GB"
                    ) "WARN"
                }
            }
            catch {

                Write-Status (
                    "Bereinigung fehlgeschlagen: $_"
                ) "ERROR"
            }
        }
        else {

            Write-Status (
                "Bereinigung wurde nicht durchgefuehrt"
            ) "WARN"
        }
    }
    else {

        Write-Status (
            "Temp-Ordner liegt innerhalb der Vorgabe"
        ) "OK"
    }
}

# Benutzer-Temp

Clean-TempFolder -Path $env:TEMP

# Globaler Windows-Temp

Clean-TempFolder -Path "$env:SystemRoot\Temp"
}

# ============================================================
# IPV4 ROUTEN PRUEFEN ob existent

if ($script:SelectedTaskIds -contains "ipv4-routes") {
$RequiredRoutes = @(
    "188.144.0.0",
    "100.102.0.0",
    "100.102.128.0",
    "100.103.0.0"
)

Write-Section "PERMANENTE IPV4 ROUTEN"

try {
    $routes = @(
        Get-NetRoute `
            -AddressFamily IPv4 `
            -PolicyStore PersistentStore `
            -ErrorAction Stop
    )
    foreach ($required in $RequiredRoutes) {

        $found = @(
            $routes | Where-Object {

                $_.DestinationPrefix -match (
                    "^" +
                    [regex]::Escape($required) +
                    "/\d+$"
                )
            }
        )

        if ($found.Count -gt 0) {

            foreach ($route in $found) {

                Write-Status (
                    "Route vorhanden: " +
                    "$($route.DestinationPrefix) | " +
                    "Gateway: $($route.NextHop) | " +
                    "Interface: $($route.InterfaceAlias)"
                ) "OK"
            }
        }
        else {

            Write-Status (
                "PERMANENTE ROUTE FEHLT: $required"
            ) "ERROR"
        }
    }
}
catch {
    Write-Status (
        "Permanente IPv4-Routen konnten nicht gelesen werden: $_"
    ) "ERROR"
}
}

# ============================================================
# EVENT CHECK (IDs 50, 51, 55, 7, 11; Critical/Error/Warning; last 10 days)

if ($script:SelectedTaskIds -contains "event-log") {
Write-Section "EREIGNISANZEIGE (IDs 50, 51, 55, 7, 11; Kritisch, Fehler, Warnung)"

try {
    $startDateCheck = (Get-Date).AddDays(-10)
    
    # Abfrage der ausgewaehlten IDs und der Level Kritisch (1), Fehler (2) und Warnung (3)
    $eventFilter = @{
        LogName   = 'System'
        ID        = @(50, 51, 55, 7, 11)
        Level     = @(1, 2, 3)
        StartTime = $startDateCheck
    }

    $events = Get-WinEvent -FilterHashtable $eventFilter -ErrorAction SilentlyContinue

    if ($events) {
        $eventCount = @($events).Count
        Write-Status "Achtung: Es wurden $eventCount kritische, fehlerhafte oder warnende Ereignisse mit den IDs 50, 51, 55, 7 und 11 in den letzten 10 Tagen gefunden!" "WARN"

        foreach ($evt in $events) {
            # Kurzausgabe fuer das Protokoll (auf eine Zeile reduziert)
            $cleanMessage = ($evt.Message -replace '[\r\n]+', ' ').Trim()
            if ($cleanMessage.Length -gt 120) {
                $cleanMessage = $cleanMessage.Substring(0, 120) + "..."
            }
            
            Write-Status "ID: $($evt.Id) | Zeit: $($evt.TimeCreated) | Quelle: $($evt.ProviderName) | $cleanMessage" "WARN"
        }
    }
    else {
        Write-Status "Keine kritischen, fehlerhaften oder warnenden Ereignisse mit den IDs 50, 51, 55, 7 und 11 in den letzten 10 Tagen gefunden." "OK"
    }
}
catch {
    Write-Status "Ereignisanzeige konnte nicht erfolgreich abgefragt werden: $_" "INFO"
}

# Pause und auf beliebige Taste warten
Write-Host ""
if ([Environment]::UserInteractive -and $Host -and $Host.UI -and $Host.UI.RawUI) {
    Write-Host "Druecken Sie eine beliebige Taste, um fortzufahren..." -ForegroundColor Cyan
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Host ""
}
else {
    Write-Status "Pause uebersprungen: Nicht-interaktive Umgebung" "WARN"
}
}

# ============================================================
# DNS CACHE LEEREN

if ($script:SelectedTaskIds -contains "dns-cache") {

Write-Section "DNS CACHE"

try {
    $dnsResult = & ipconfig.exe /flushdns 2>&1

    foreach ($line in $dnsResult) {
        Write-Status "$line" "INFO"
    }

    if ($LASTEXITCODE -ne 0) {
        throw "DNS-Cache konnte nicht geleert werden"
    }

    Write-Status (
        "DNS-Aufloesungscache erfolgreich geleert"
    ) "OK"

    $script:Changes++

}
catch {

    Write-Status (
        "DNS-Cache konnte nicht geleert werden: $_"
    ) "ERROR"
}
}

# ============================================================
# ABSCHLUSSAUSWERTUNG

Write-Section "AUSGEWAEHLTE AUFGABE ABGESCHLOSSEN"

$endTime = Get-Date

if ($script:SelectedTaskIds.Count -eq $script:AllTaskIds.Count) {
    Write-Status "Alle ausgewaehlten Aufgaben abgeschlossen: $script:SelectionDescription"
}
else {
    Write-Status "Ausgewaehlte Aufgabe(n) abgeschlossen: $script:SelectionDescription"
}
Write-Status "Computername: $env:COMPUTERNAME"
Write-Status "Benutzer: $env:USERNAME"
if ($script:SelectedTaskIds -contains "windows-version") {
    Write-Status "Windows: $($os.Caption)"
    Write-Status "Windows-Version: $displayVersion"
    Write-Status "Build: $build.$ubr"
}

Write-Status "Beginn: $($startDate.ToString('dd.MM.yyyy HH:mm:ss'))"
Write-Status "Ende: $($endTime.ToString('dd.MM.yyyy HH:mm:ss'))"

continue
}

# ============================================================
# GESAMTERGEBNIS UND PRUEFBERICHT

Write-Section "ALBIS SYSTEMCHECK - ABSCHLUSS"
Write-Status "Systemcheck beendet: Auswahl Q"
Write-Status "Beginn: $($startDate.ToString('dd.MM.yyyy HH:mm:ss'))"
Write-Status "Ende: $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')"

Write-Section "GESAMTERGEBNIS"

Write-Status "Erfolgreiche Pruefungen: $script:Success"
Write-Status "Warnungen: $script:Warnings"
Write-Status "Fehler: $script:Errors"
Write-Status "Durchgefuehrte Aenderungen: $script:Changes"

if ($script:Errors -gt 0) {
    Write-Status "SYSTEMCHECK MIT KRITISCHEN FEHLERN ABGESCHLOSSEN" "ERROR"
}
elseif ($script:Warnings -gt 0) {
    Write-Status "SYSTEMCHECK MIT WARNUNGEN ABGESCHLOSSEN" "WARN"
}
else {
    Write-Status "SYSTEMCHECK OHNE FESTGESTELLTE FEHLER ABGESCHLOSSEN" "OK"
}

Write-Section "PRUEFBERICHT"

Add-Content -Path $script:LogFile -Value ""
Add-Content -Path $script:LogFile -Value "==============================================="
Add-Content -Path $script:LogFile -Value "AIS SYSTEMCHECK - ENDBERICHT"
Add-Content -Path $script:LogFile -Value "==============================================="
Add-Content -Path $script:LogFile -Value "Computer: $env:COMPUTERNAME"
Add-Content -Path $script:LogFile -Value "Benutzer: $env:USERNAME"
Add-Content -Path $script:LogFile -Value "Datum: $(Get-Date)"
Add-Content -Path $script:LogFile -Value ""
Add-Content -Path $script:LogFile -Value "Erfolgreich: $script:Success"
Add-Content -Path $script:LogFile -Value "Warnungen: $script:Warnings"
Add-Content -Path $script:LogFile -Value "Fehler: $script:Errors"
Add-Content -Path $script:LogFile -Value "Aenderungen: $script:Changes"
Add-Content -Path $script:LogFile -Value ""
Add-Content -Path $script:LogFile -Value "Pruefbericht: $script:LogFile"
Add-Content -Path $script:LogFile -Value "==============================================="

Write-Host ""
Write-Host "Erfolgreich: $script:Success" -ForegroundColor Green
Write-Host "Warnungen:   $script:Warnings" -ForegroundColor Yellow
Write-Host "Fehler:      $script:Errors" -ForegroundColor Red
Write-Host "Aenderungen: $script:Changes" -ForegroundColor Cyan
Write-Host ""
Write-Host "Pruefbericht gespeichert unter:" -ForegroundColor Cyan
Write-Host $script:LogFile -ForegroundColor White
Write-Host ""

if (Confirm-Critical "Pruefbericht jetzt mit Editor oeffnen?") {
    Start-Process notepad.exe -ArgumentList "`"$script:LogFile`""
}

Write-Host ""
Write-Host "AIS SYSTEMCHECK abgeschlossen." -ForegroundColor Green
