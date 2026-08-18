<#
.SYNOPSIS
V2 local patching for standalone SQL Server 2017, 2019, 2022, and 2025.

.DESCRIPTION
Supports standalone Express, Standard, Standard Developer, and Developer
Database Engine instances. Any FCI, Windows failover-cluster membership,
Always On enablement, or Availability Group metadata blocks the entire run
before backup, download, or setup. No scheduled task or automatic resume is
created. Run the same script again after a reboot to verify the build.
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$BackupOnly,
    [string]$InstanceName,
    [ValidateSet('0','1','2')][string]$BackupChoice,
    [string]$LocalPackagePath,
    [switch]$ConfirmInstall,
    [ValidateSet('Prompt','Yes','No')][string]$Restart = 'Prompt'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$packageRoot = 'C:\ProgramData\SqlPatchV2Local\Packages'
$products = @{
    14 = @{ Product = 'SQL Server 2017'; Token = '2017'; DownloadPage = 'https://www.microsoft.com/en-us/download/details.aspx?id=56128' }
    15 = @{ Product = 'SQL Server 2019'; Token = '2019'; DownloadPage = 'https://www.microsoft.com/en-us/download/details.aspx?id=100809' }
    16 = @{ Product = 'SQL Server 2022'; Token = '2022'; DownloadPage = 'https://www.microsoft.com/en-us/download/details.aspx?id=105013' }
    17 = @{ Product = 'SQL Server 2025'; Token = '2025'; DownloadPage = 'https://www.microsoft.com/en-us/download/details.aspx?id=108540' }
}

function Write-Step { param([string]$Text); Write-Host "`n== $Text ==" -ForegroundColor Cyan }

function Test-Yes { param([string]$Answer); return $Answer -match '^(?i:y|yes|t|tak)$' }

function Invoke-SqlQuery {
    param([string]$ServerInstance, [string]$Query, [int]$TimeoutSeconds = 120)
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = "Server=$ServerInstance;Database=master;Integrated Security=SSPI;Application Name=SqlPatchV2Local;Connect Timeout=15;Encrypt=False"
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = $TimeoutSeconds
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
        $table = New-Object System.Data.DataTable
        [void]$adapter.Fill($table)
        return (, $table)
    }
    finally { if ($connection) { $connection.Dispose() } }
}

function Get-LocalInstances {
    $registryPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if (-not (Test-Path -LiteralPath $registryPath)) { throw 'No local SQL Server Database Engine instance was found.' }
    $map = Get-ItemProperty -LiteralPath $registryPath
    $instances = New-Object System.Collections.Generic.List[object]
    foreach ($property in $map.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }) {
        $instanceName = [string]$property.Name
        $serverInstance = if ($instanceName -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$instanceName" }
        try {
            $query = @"
SELECT CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)) AS ServerName,
       CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS Edition,
       CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(32)) AS ProductVersion,
       CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(32)) AS ProductUpdateLevel,
       CAST(SERVERPROPERTY('IsClustered') AS int) AS IsClustered,
       CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS IsHadrEnabled,
       ISNULL(IS_SRVROLEMEMBER(N'sysadmin'), 0) AS IsSysadmin,
       (SELECT COUNT(*) FROM sys.availability_replicas) AS AvailabilityReplicaCount;
"@
            $row = (Invoke-SqlQuery -ServerInstance $serverInstance -Query $query).Rows[0]
            $major = ([version][string]$row.ProductVersion).Major
            if ($products.ContainsKey($major)) {
                $instances.Add([pscustomobject]@{
                    InstanceName = $instanceName
                    ServerInstance = $serverInstance
                    DisplayName = if ($instanceName -eq 'MSSQLSERVER') { "$env:COMPUTERNAME (default)" } else { "$env:COMPUTERNAME\$instanceName" }
                    Edition = [string]$row.Edition
                    Version = [string]$row.ProductVersion
                    Update = [string]$row.ProductUpdateLevel
                    Major = $major
                    IsClustered = [bool]$row.IsClustered
                    IsHadrEnabled = [bool]$row.IsHadrEnabled
                    AvailabilityReplicaCount = [int]$row.AvailabilityReplicaCount
                    IsSysadmin = [bool]$row.IsSysadmin
                })
            }
        }
        catch { Write-Warning "Could not query local instance '$serverInstance': $($_.Exception.Message)" }
    }
    return $instances.ToArray()
}

function Select-Instance {
    param([string]$SelectedInstanceName)
    $instances = @(Get-LocalInstances)
    if (-not $instances.Count) { throw 'No query-ready local SQL Server 2017, 2019, 2022, or 2025 instance was found.' }
    if (-not [string]::IsNullOrWhiteSpace($SelectedInstanceName)) {
        $selected = @($instances | Where-Object InstanceName -eq $SelectedInstanceName)
        if ($selected.Count -ne 1) { throw "Local instance '$SelectedInstanceName' was not found exactly once." }
        Write-Host "Selected: $($selected[0].DisplayName) | $($selected[0].Edition) | $($selected[0].Version)"
        return $selected[0]
    }
    if ($instances.Count -eq 1) {
        Write-Host "Found: $($instances[0].DisplayName) | $($instances[0].Edition) | $($instances[0].Version)"
        return $instances[0]
    }
    for ($index = 0; $index -lt $instances.Count; $index++) {
        Write-Host ("{0}. {1} | {2} | {3}" -f ($index + 1), $instances[$index].DisplayName, $instances[$index].Edition, $instances[$index].Version)
    }
    do { $choice = Read-Host 'Select local instance number' } until ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $instances.Count)
    return $instances[[int]$choice - 1]
}

function Assert-SupportedStandalone {
    param($Instance)
    $clusterService = Get-Service -Name ClusSvc -ErrorAction SilentlyContinue
    $clusterRegistry = Test-Path -LiteralPath 'HKLM:\Cluster'
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($Instance.IsClustered) { $reasons.Add('SERVERPROPERTY(IsClustered)=1 (FCI)') }
    if ($Instance.IsHadrEnabled) { $reasons.Add('SERVERPROPERTY(IsHadrEnabled)=1 (Always On enabled)') }
    if ($Instance.AvailabilityReplicaCount -gt 0) { $reasons.Add("Availability Group replica metadata=$($Instance.AvailabilityReplicaCount)") }
    if ($clusterRegistry) { $reasons.Add('local WSFC configuration exists') }
    if ($clusterService -and $clusterService.Status -ne 'Stopped') { $reasons.Add("Cluster Service status=$($clusterService.Status)") }
    if ($reasons.Count) { throw "BLOCKED: clustered or Always On server detected: $($reasons -join '; '). V2 made no changes." }
    $editionSupported = $Instance.Edition -match 'Express' -or $Instance.Edition -match '^Standard Edition' -or $Instance.Edition -match 'Standard Developer' -or $Instance.Edition -match 'Developer Edition'
    if (-not $editionSupported) { throw "BLOCKED: edition '$($Instance.Edition)' is outside V2 scope. Supported: Express, Standard, Standard Developer, Developer." }
    if (-not $Instance.IsSysadmin) { throw "BLOCKED: current Windows account is not SQL sysadmin on '$($Instance.DisplayName)'." }
    Write-Host 'Standalone safety gate: PASS' -ForegroundColor Green
}

function Show-BackupHistory {
    param([string]$ServerInstance)
    $query = @"
SELECT d.name AS DatabaseName, d.state_desc AS State,
       b.backup_finish_date AS LastFullBackup, b.is_copy_only AS IsCopyOnly,
       b.physical_device_name AS BackupPath
FROM sys.databases AS d
OUTER APPLY (
    SELECT TOP (1) bs.backup_finish_date, bs.is_copy_only, bmf.physical_device_name
    FROM msdb.dbo.backupset AS bs
    LEFT JOIN msdb.dbo.backupmediafamily AS bmf ON bmf.media_set_id = bs.media_set_id
    WHERE bs.database_name = d.name AND bs.type = 'D'
    ORDER BY bs.backup_finish_date DESC
) AS b
WHERE d.database_id <> 2
ORDER BY d.database_id;
"@
    $table = Invoke-SqlQuery -ServerInstance $ServerInstance -Query $query
    foreach ($row in $table.Rows) {
        $date = if ($row.LastFullBackup -eq [DBNull]::Value) { 'NEVER' } else { ([datetime]$row.LastFullBackup).ToString('yyyy-MM-dd HH:mm:ss') }
        $kind = if ($row.LastFullBackup -eq [DBNull]::Value) { '' } elseif ([bool]$row.IsCopyOnly) { 'COPY_ONLY' } else { 'FULL' }
        Write-Host ("{0} | {1} | last full: {2} {3}" -f $row.DatabaseName, $row.State, $date, $kind)
        if ($row.BackupPath -ne [DBNull]::Value -and -not [string]::IsNullOrWhiteSpace([string]$row.BackupPath)) { Write-Host "  $($row.BackupPath)" -ForegroundColor DarkGray }
    }
}

function Quote-SqlIdentifier { param([string]$Value); return '[' + $Value.Replace(']', ']]') + ']' }
function Quote-SqlLiteral { param([string]$Value); return "N'" + $Value.Replace("'", "''") + "'" }

function Invoke-OptionalBackups {
    param($Instance, [string]$SelectedChoice)
    Write-Host '0. Do not create backups (default)'
    Write-Host '1. COPY_ONLY system databases (master, model, msdb)'
    Write-Host '2. COPY_ONLY all databases (system and user; tempdb excluded)'
    $choice = $SelectedChoice
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = Read-Host 'Select [0]' }
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '0' }
    if ($choice -eq '0') { Write-Host 'No new backup was requested.' -ForegroundColor Yellow; return }
    if ($choice -notin @('1', '2')) { throw "Unknown backup selection '$choice'." }
    $filter = if ($choice -eq '1') { 'database_id IN (1,3,4)' } else { 'database_id <> 2' }
    $databases = Invoke-SqlQuery -ServerInstance $Instance.ServerInstance -Query "SELECT name, state_desc FROM sys.databases WHERE $filter ORDER BY database_id;"
    $pathTable = Invoke-SqlQuery -ServerInstance $Instance.ServerInstance -Query "SELECT CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(4000)) AS BackupPath;"
    $backupRoot = [string]$pathTable.Rows[0].BackupPath
    if ([string]::IsNullOrWhiteSpace($backupRoot) -or -not (Test-Path -LiteralPath $backupRoot -PathType Container)) { throw "SQL default backup directory '$backupRoot' is unavailable." }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeInstance = if ($Instance.InstanceName -eq 'MSSQLSERVER') { 'DEFAULT' } else { $Instance.InstanceName -replace '[^A-Za-z0-9._-]', '_' }
    $created = 0
    foreach ($row in $databases.Rows) {
        $name = [string]$row.name
        if ([string]$row.state_desc -ne 'ONLINE') { Write-Warning "Skipping '$name' because its state is $($row.state_desc)."; continue }
        $safeDatabase = $name -replace '[^A-Za-z0-9._-]', '_'
        $path = Join-Path $backupRoot ("{0}_{1}_{2}_COPY_ONLY_{3}.bak" -f $env:COMPUTERNAME, $safeInstance, $safeDatabase, $stamp)
        $sql = 'BACKUP DATABASE {0} TO DISK = {1} WITH COPY_ONLY, CHECKSUM, INIT, STATS = 10; RESTORE VERIFYONLY FROM DISK = {1} WITH CHECKSUM;' -f (Quote-SqlIdentifier $name), (Quote-SqlLiteral $path)
        Write-Host "Backing up '$name'..."
        [void](Invoke-SqlQuery -ServerInstance $Instance.ServerInstance -Query $sql -TimeoutSeconds 3600)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Backup '$path' was not found." }
        Write-Host "Verified: $path" -ForegroundColor Green
        $created++
    }
    if (-not $created) { throw 'No database was eligible for backup.' }
    Write-Host "Completed and verified $created COPY_ONLY backup(s)." -ForegroundColor Green
}

function Get-LatestUpdate {
    param($Instance)
    $product = $products[[int]$Instance.Major]
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $response = Invoke-WebRequest -Uri $product.DownloadPage -UseBasicParsing
    $html = [Net.WebUtility]::HtmlDecode([string]$response.Content)
    $plain = [regex]::Replace($html, '<script[\s\S]*?</script>|<style[\s\S]*?</style>|<[^>]+>', ' ')
    $plain = [regex]::Replace($plain, '\s+', ' ')
    $token = [string]$product.Token
    $filePattern = "SQLServer$token-KB\d+-x64\.exe"
    $fileMatch = [regex]::Match($plain, $filePattern, 'IgnoreCase')
    $versionMatch = [regex]::Match($plain, "Version:\s*($($Instance.Major)\.0\.\d+\.\d+)", 'IgnoreCase')
    $cuMatch = [regex]::Match($plain, "Cumulative Update Package\s+(\d+)(?:\s+Azure Connect Pack)?\s+for SQL Server $token\s+-\s+(KB\d+)", 'IgnoreCase')
    $urls = @($response.Links | ForEach-Object { if ($_.PSObject.Properties.Name -contains 'href') { [string]$_.href } } | Where-Object { $_ -match "^https://download\.microsoft\.com/.*/$filePattern(?:\?.*)?$" })
    if (-not $urls.Count) {
        $rawUrlPattern = 'https://download\.microsoft\.com/[^"''\s<>]+/{0}(?:\?[^"''\s<>]*)?' -f $filePattern
        $urlMatch = [regex]::Match($html, $rawUrlPattern, 'IgnoreCase')
        if ($urlMatch.Success) { $urls = @($urlMatch.Value) }
    }
    if (-not $fileMatch.Success -or -not $versionMatch.Success -or -not $cuMatch.Success -or -not $urls.Count) { throw "Could not read the latest $($product.Product) CU from Microsoft Download Center. Use a reviewed local package instead." }
    $uri = [uri]$urls[0]
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'download.microsoft.com') { throw "Unexpected download URL '$uri'." }
    return [pscustomobject]@{ Name = "CU$($cuMatch.Groups[1].Value)"; KB = $cuMatch.Groups[2].Value.ToUpperInvariant(); Version = $versionMatch.Groups[1].Value; FileName = $fileMatch.Value; Uri = $uri.AbsoluteUri }
}

function Get-LatestPackage {
    param($Update)
    if (-not (Test-Path -LiteralPath $packageRoot)) { New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null }
    $destination = Join-Path $packageRoot $Update.FileName
    if (Test-Path -LiteralPath $destination -PathType Leaf) { return $destination }
    $partial = $destination + '.download'
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    try {
        Write-Host "Downloading $($Update.Name) $($Update.KB) from Microsoft..."
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) { Start-BitsTransfer -Source $Update.Uri -Destination $partial -DisplayName 'SQL Server CU' }
        else { Invoke-WebRequest -Uri $Update.Uri -OutFile $partial -UseBasicParsing }
        Move-Item -LiteralPath $partial -Destination $destination
        return $destination
    }
    catch { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue; throw }
}

function Test-UpdatePackage {
    param([string]$Path, $Instance)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Update '$Path' was not found." }
    $token = [string]$products[[int]$Instance.Major].Token
    if ([IO.Path]::GetFileName($Path) -notmatch "^SQLServer$token-KB\d+-x64\.exe$") { throw "Package file name does not match selected SQL Server $token instance." }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') { throw "Package is not validly signed by Microsoft Corporation. Status=$($signature.Status)." }
    Write-Host 'Microsoft signature: VALID' -ForegroundColor Green
    if (Get-Command Start-MpScan -ErrorAction SilentlyContinue) { Write-Host 'Running Microsoft Defender scan...'; Start-MpScan -ScanType CustomScan -ScanPath $Path }
}

try {
    Write-Host 'SQL PATCH V2 LOCAL - STANDALONE ONLY' -ForegroundColor White
    Write-Host '===================================='
    Write-Step '1. Local SQL instance'
    $instance = Select-Instance -SelectedInstanceName $InstanceName
    Write-Step '2. Standalone safety gate'
    Assert-SupportedStandalone -Instance $instance
    Write-Step '3. Last full backups'
    Show-BackupHistory -ServerInstance $instance.ServerInstance
    if ($CheckOnly) { Write-Host "`nV2 check complete. No changes were made." -ForegroundColor Green; exit 0 }
    Write-Step '4. Optional COPY_ONLY backup'
    Invoke-OptionalBackups -Instance $instance -SelectedChoice $BackupChoice
    if ($BackupOnly) { Write-Host 'Backup-only operation complete. No update was selected or installed.' -ForegroundColor Green; exit 0 }
    Write-Step '5. Update'
    Write-Host '1. Latest Microsoft CU (default)'
    Write-Host "2. Another local $($products[[int]$instance.Major].Product) update .exe"
    $choice = if ([string]::IsNullOrWhiteSpace($LocalPackagePath)) { Read-Host 'Select [1]' } else { '2' }
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }
    $downloadedByScript = $false
    if ($choice -eq '1') {
        $latest = Get-LatestUpdate -Instance $instance
        Write-Host "Latest CU: $($latest.Name) | $($latest.KB) | build $($latest.Version)"
        if ([version]$instance.Version -ge [version]$latest.Version) { Write-Host "Already at or above latest CU build: $($instance.Version)." -ForegroundColor Green; exit 0 }
        $package = Get-LatestPackage -Update $latest
        $downloadedByScript = $true
    }
    elseif ($choice -eq '2') {
        $package = if ([string]::IsNullOrWhiteSpace($LocalPackagePath)) { (Read-Host 'Full path to the Microsoft update .exe').Trim().Trim('"') } else { $LocalPackagePath.Trim().Trim('"') }
    }
    else { throw "Unknown update selection '$choice'." }
    Test-UpdatePackage -Path $package -Instance $instance
    Write-Host "Selected instance: $($instance.DisplayName)"
    Write-Host "Installed build:  $($instance.Version)"
    Write-Host "Update package:   $package"
    if (-not $ConfirmInstall -and -not (Test-Yes (Read-Host 'Install this update? [y/N]'))) { Write-Host 'Cancelled. No SQL update was installed.' -ForegroundColor Yellow; exit 0 }
    Write-Step '6. Install'
    $arguments = @('/quiet', '/action=patch', "/instancename=$($instance.InstanceName)", '/IAcceptSQLServerLicenseTerms')
    $process = Start-Process -FilePath $package -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw "SQL update failed with exit code $($process.ExitCode). Review SQL Setup Bootstrap logs." }
    Write-Host "Installer completed successfully (exit $($process.ExitCode))." -ForegroundColor Green
    if ($downloadedByScript) { Remove-Item -LiteralPath $package -Force -ErrorAction SilentlyContinue }
    $needsRestart = $process.ExitCode -eq 3010 -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    if ($needsRestart) {
        Write-Host 'A Windows restart is required.' -ForegroundColor Yellow
        $restartNow = $Restart -eq 'Yes' -or ($Restart -eq 'Prompt' -and (Test-Yes (Read-Host 'Restart now? [y/N]')))
        if ($restartNow) { Write-Host 'Restarting in 30 seconds. Run this same V2 script again after startup.'; & shutdown.exe /r /t 30 /d p:4:2 /c 'SQL Server update'; exit 0 }
        Write-Host 'Restart later, then run this same V2 script again. No automatic resume exists.' -ForegroundColor Yellow
    }
    else { Write-Host 'Run this same V2 script again to display the installed build.' -ForegroundColor Green }
}
catch { Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
