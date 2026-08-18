<#
.SYNOPSIS
Remote standalone SQL patch orchestration with live console and HTML status.

.DESCRIPTION
Processes one server at a time. Domain discovery, parallel patching, clustered
SQL, Always On, forced failover, and data-loss operations are outside scope.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('ValidateScope','Inventory','Backup','Prepare','Preflight','Apply','PostVerify','Dashboard')][string]$Mode,
    [Alias('ServerListPath')][string]$TargetListPath,
    [string]$PackageRoot,
    [string]$RunRoot,
    [string]$Cycle = (Get-Date).ToString('MMMMyyyy',[Globalization.CultureInfo]::GetCultureInfo('en-US')),
    [ValidateSet('WinRM','PowerShellDirect')][string]$Transport = 'WinRM',
    [pscredential]$Credential,
    [switch]$ApproveScope,
    [switch]$DownloadLatest,
    [switch]$ConfirmBackup,
    [switch]$ConfirmApply,
    [ValidateSet('0','1')][string]$BackupChoice = '0',
    [string]$V2SourcePath,
    [int]$ReadyTimeoutSeconds = 1200,
    [ValidateRange(1,365)][int]$BackupWarningDays = 7,
    [long]$MinimumTargetFreeBytes = 3GB
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if([string]::IsNullOrWhiteSpace($TargetListPath)){$TargetListPath=Join-Path $PSScriptRoot 'targets.txt'}
if([string]::IsNullOrWhiteSpace($PackageRoot)){$PackageRoot=Join-Path $PSScriptRoot 'Packages'}
if([string]::IsNullOrWhiteSpace($RunRoot)){$RunRoot=Join-Path $PSScriptRoot 'Runs'}
if([string]::IsNullOrWhiteSpace($V2SourcePath)){
    $packagedV2=Join-Path $PSScriptRoot 'SqlPatchV2Local'
    $labV2=Join-Path $PSScriptRoot '..\SqlPatchV2Local'
    if(Test-Path -LiteralPath $packagedV2 -PathType Container){$V2SourcePath=$packagedV2}else{$V2SourcePath=$labV2}
}
$supported = @{14='2017';15='2019';16='2022';17='2025'}
$downloadPages = @{14='https://www.microsoft.com/en-us/download/details.aspx?id=56128';15='https://www.microsoft.com/en-us/download/details.aspx?id=100809';16='https://www.microsoft.com/en-us/download/details.aspx?id=105013';17='https://www.microsoft.com/en-us/download/details.aspx?id=108540'}
$buildHistoryPages = @{14='https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/build-versions';15='https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2019/build-versions';16='https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions';17='https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2025/build-versions'}
$cycleRoot = Join-Path $RunRoot $Cycle
$statePath = Join-Path $cycleRoot 'state.json'
$dashboardPath = Join-Path $cycleRoot 'Dashboard.html'

function Encode-Html { param([object]$Value); [Net.WebUtility]::HtmlEncode([string]$Value) }
function Get-PropertyValue {
    param([object]$InputObject,[string]$Name,[object]$Default='')
    if($null-ne$InputObject-and$InputObject.PSObject.Properties.Name-contains$Name){return $InputObject.$Name}
    $Default
}
function Set-PropertyValue {
    param([object]$InputObject,[string]$Name,[object]$Value)
    if($InputObject.PSObject.Properties.Name-contains$Name){$InputObject.$Name=$Value}
    else{$InputObject|Add-Member NoteProperty $Name $Value}
}
function Format-ReleaseDate {
    param([object]$Value)
    if($null-eq$Value-or[string]::IsNullOrWhiteSpace([string]$Value)-or[string]$Value-eq'Unknown'){return 'Unknown'}
    try{([datetime]$Value).ToString('yyyy-MM-dd')}catch{'Unknown'}
}
function Get-BackupWarnings {
    param([object[]]$Backups)
    $warnings=New-Object Collections.Generic.List[string]
    foreach($backup in @($Backups)){
        if($backup.LastFull-eq'NEVER'){$warnings.Add("$($backup.Database): no full backup history");continue}
        try{$age=([datetime]::Now-[datetime]::ParseExact([string]$backup.LastFull,'yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)).TotalDays;if($age-gt$BackupWarningDays){$warnings.Add("$($backup.Database): last full backup is $([math]::Floor($age)) day(s) old")}}
        catch{$warnings.Add("$($backup.Database): backup timestamp could not be parsed")}
    }
    @($warnings)
}
function Get-Scope {
    if (-not (Test-Path -LiteralPath $TargetListPath -PathType Leaf)) { throw "Target list '$TargetListPath' was not found." }
    $lines = @(Get-Content -LiteralPath $TargetListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if (-not $lines.Count) { throw 'The DBA target list is empty.' }
    $uniqueLines = @($lines | Sort-Object -Unique)
    if ($uniqueLines.Count -ne $lines.Count) { throw 'The target list contains duplicate entries.' }
    $parsed = foreach ($line in $lines) {
        if ($line -notmatch '^([A-Za-z0-9][A-Za-z0-9.-]{0,252})(?:\\([A-Za-z0-9_$#@-]{1,128}))?$') { throw "Invalid target '$line'. Use SERVER or SERVER\INSTANCE." }
        [pscustomobject]@{ Server=$matches[1]; Instance=if($matches[2]){$matches[2]}else{''}; Target=$line }
    }
    $groups = @($parsed | Group-Object Server)
    if ($groups.Count -gt 12) { throw "The target list has $($groups.Count) servers; maximum is 12." }
    foreach ($group in $groups) {
        $all = @($group.Group | Where-Object { -not $_.Instance })
        if ($all.Count -and $group.Count -gt 1) { throw "Server '$($group.Name)' mixes a whole-server target with instance targets." }
        [pscustomobject]@{
            Server = [string]$group.Group[0].Server
            RequestedInstances = @($group.Group | Where-Object Instance | ForEach-Object Instance)
            Targets = @($group.Group | ForEach-Object Target)
        }
    }
}
function Get-ScopeHash {
    param([string[]]$Names)
    $bytes = [Text.Encoding]::UTF8.GetBytes((($Names | ForEach-Object { $_.ToLowerInvariant() }) -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','') } finally { $sha.Dispose() }
}
function New-TargetSession {
    param([string]$Server)
    if ($Transport -eq 'PowerShellDirect') {
        if (-not $Credential) { throw 'PowerShellDirect transport requires -Credential.' }
        return New-PSSession -VMName $Server -Credential $Credential
    }
    if ($Credential) { return New-PSSession -ComputerName $Server -Credential $Credential }
    New-PSSession -ComputerName $Server
}
function Save-State {
    param($State)
    if (-not (Test-Path $cycleRoot)) { New-Item -ItemType Directory -Path $cycleRoot -Force | Out-Null }
    $State.UpdatedUtc = [datetime]::UtcNow.ToString('o')
    $json = $State | ConvertTo-Json -Depth 10
    $uniqueId=[guid]::NewGuid().ToString('N')
    $temp = Join-Path $cycleRoot ("state.{0}.{1}.tmp" -f $PID,$uniqueId)
    $legacyTemp=$statePath+'.tmp';if(Test-Path -LiteralPath $legacyTemp -PathType Leaf){Remove-Item -LiteralPath $legacyTemp -Force -ErrorAction SilentlyContinue}
    try {
        [IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($false))
        [IO.File]::Copy($temp,$statePath,$true)
    }
    finally{if(Test-Path -LiteralPath $temp -PathType Leaf){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}}
    Write-Dashboard -State $State
    Show-Console -State $State
}
function Read-State {
    if (-not (Test-Path $statePath -PathType Leaf)) { throw "State '$statePath' does not exist. Run Inventory first." }
    Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
}
function Write-Dashboard {
    param($State)
    $rows = foreach ($server in @($State.Servers)) {
        $instances=@($server.Instances)
        if(-not$instances.Count){
            '<tr><td>{0}<br><small>requested: {1}</small></td><td class="{2}">{3}</td><td colspan="8">{4}</td></tr>' -f (Encode-Html $server.Server),(Encode-Html (@($server.RequestedInstances)-join', ')),(Encode-Html $server.Status),(Encode-Html $server.Status),(Encode-Html $server.Message)
            continue
        }
        foreach($instance in $instances){
            $fullName=Get-PropertyValue $instance 'FullName' ("$($server.Server)\$($instance.InstanceName)")
            $systemBackups=@($instance.Backups|Where-Object{$_.Database-in@('master','model','msdb')}|ForEach-Object{"<b>$((Encode-Html $_.Database))</b>: $((Encode-Html $_.LastFull))"})-join'<br>'
            $userBackups=@($instance.Backups|Where-Object{$_.Database-notin@('master','model','msdb')}|ForEach-Object{"<b>$((Encode-Html $_.Database))</b>: $((Encode-Html $_.LastFull))"})-join'<br>'
            if(-not$userBackups){$userBackups='<span class="muted">none</span>'}
            $warnings=@($instance.BackupWarnings);$backupClass=if($warnings.Count){'warn'}else{'ok'}
            $readiness=Get-PropertyValue $instance 'Readiness' 'Not checked'
            $readinessClass=if($readiness-eq'Ready'){'ok'}elseif($readiness-eq'Blocked'){'bad'}else{'warn'}
            $packageName=Get-PropertyValue $instance 'PackageName' 'Not selected'
            $distributionState=Get-PropertyValue $instance 'DistributionState' 'Not staged'
            $packageState=Get-PropertyValue $instance 'PackageState' 'Not verified'
            $packageClass=if($packageState-in@('Staged','Signature + SHA-256 verified','Installed')){'ok'}else{'warn'}
            $releaseDate=Format-ReleaseDate (Get-PropertyValue $instance 'ReleaseDate' 'Unknown');$packageAge=if($releaseDate-ne'Unknown'){[math]::Max(0,[int](([datetime]::UtcNow.Date-[datetime]$releaseDate).TotalDays))}else{'Unknown'}
            $hostText="Free C: $((Encode-Html (Get-PropertyValue $server 'FreeGiB' 'Not checked'))) GiB<br>Pending reboot: $((Encode-Html (Get-PropertyValue $server 'PendingReboot' 'Not checked')))<br>Partial files: $((Encode-Html (Get-PropertyValue $server 'PartialFiles' 'Not checked')))"
            $timeText="$((Encode-Html (Get-PropertyValue $server 'TimeZone' 'Unknown timezone'))) $((Encode-Html (Get-PropertyValue $server 'UtcOffset' '')))"
            $postStatus=Get-PropertyValue $instance 'PostVerifyStatus' 'Not run';$postClass=if($postStatus-eq'Passed'){'ok'}elseif($postStatus-eq'Failed'){'bad'}else{'warn'}
            $postText="DB: $((Encode-Html (Get-PropertyValue $instance 'DatabaseSummary' 'Not checked')))<br>Engine: $((Encode-Html (Get-PropertyValue $instance 'EngineServiceSummary' 'Not checked')))<br>SQL auto services: $((Encode-Html (Get-PropertyValue $server 'SqlServiceSummary' 'Not checked')))<br><span class=`"muted`">$((Encode-Html (Get-PropertyValue $server 'PostVerifyWarnings' '')))</span>"
            '<tr><td><b>{0}</b><br><span class="muted">{1}</span></td><td class="{2}"><b>{3}</b><br><span class="muted">SQL: {4}; standalone: {5}; sysadmin: {6}</span></td><td>{7}<br><span class="muted">{8}</span></td><td>{9}<br><span class="muted">target: {10}</span></td><td class="{11}"><b>copy: {12}</b><br>verify: {13}<br><span class="muted">{14}; hash match: {15}</span><br><b>released: {16}</b><br><span class="muted">{17}; age: {18} day(s)</span></td><td class="{19}">{20}{21}</td><td>{22}</td><td>{23}<br><span class="muted">{24}</span></td><td class="{25}"><b>{26}</b><br>{27}</td><td class="{28}"><b>{29}</b><br><span class="muted">{30}</span></td></tr>' -f (Encode-Html $fullName),$timeText,$readinessClass,(Encode-Html $readiness),(Encode-Html (Get-PropertyValue $instance 'SqlReady' 'Unknown')),(Encode-Html (Get-PropertyValue $instance 'Standalone' 'Unknown')),(Encode-Html (Get-PropertyValue $instance 'Sysadmin' 'Unknown')),(Encode-Html $instance.Edition),(Encode-Html $instance.UpdateLevel),(Encode-Html $instance.Version),(Encode-Html $instance.TargetVersion),$packageClass,(Encode-Html $distributionState),(Encode-Html $packageState),(Encode-Html $packageName),(Encode-Html (Get-PropertyValue $instance 'PackageHashVerified' 'Not checked')),(Encode-Html $releaseDate),(Encode-Html (Get-PropertyValue $instance 'UpdateName' 'Not selected')),(Encode-Html $packageAge),$backupClass,$systemBackups,$(if($warnings.Count){"<br><span class=`"warn`">$((Encode-Html ($warnings-join'; ')))</span>"}),$userBackups,$hostText,(Encode-Html (Get-PropertyValue $server 'LastChangeUtc' $State.UpdatedUtc)),$postClass,(Encode-Html $postStatus),$postText,(Encode-Html $server.Status),(Encode-Html $server.Status),(Encode-Html $server.Message)
        }
    }
    $html = @"
<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="5"><title>SQL Patch $((Encode-Html $State.Cycle))</title><style>body{font-family:Segoe UI,Arial;margin:20px;background:#10151d;color:#edf2f7}h1{margin-bottom:4px}.summary{margin-top:0;color:#9fb0c3}.table-wrap{overflow-x:auto}table{border-collapse:collapse;width:100%;min-width:1700px;font-size:13px}th{position:sticky;top:0;background:#1a2230;color:#bcd0e5}th,td{padding:9px;border:1px solid #354052;text-align:left;vertical-align:top}.ok,.Complete,.Prepared,.Ready,.PreflightReady,.PostVerified{color:#6ee7a8}.bad,.Failed,.Blocked,.PostVerifyFailed{color:#ff8080}.warn,.Copying,.Inventory,.Patching,.Rebooting,.WaitingForOS,.WaitingForSQL,.Validating,.Preflight,.PostVerifying{color:#ffd166}.muted,small{color:#9fb0c3;font-size:11px}tr:hover{background:#17202c}</style></head><body><h1>SQL Patch $((Encode-Html $State.Cycle))</h1><p class="summary">Campaign stage: <b>$((Encode-Html $State.Stage))</b> | updated UTC: $((Encode-Html $State.UpdatedUtc)) | auto-refresh: 5 seconds</p><div class="table-wrap"><table><thead><tr><th>Full instance</th><th>Instance readiness</th><th>Edition / CU</th><th>Current / target build</th><th>Package / release date</th><th>System backup dates</th><th>User backup dates</th><th>Host checks</th><th>Post-verification</th><th>Stage / current activity</th></tr></thead><tbody>$($rows -join "`n")</tbody></table></div><p><small>Backup timestamps are reported in each SQL Server's local time. Update release dates come from Microsoft Learn build history and dashboard generation time is UTC.</small></p></body></html>
"@
    [IO.File]::WriteAllText($dashboardPath,$html,[Text.UTF8Encoding]::new($false))
}
function Show-Console {
    param($State)
    Write-Host "`nSQL PATCH V3 | $($State.Cycle) | $($State.Stage) | $($State.UpdatedUtc)"
    Write-Host ('-' * 92)
    foreach ($server in @($State.Servers)) {
        $requested=if(@($server.RequestedInstances).Count){@($server.RequestedInstances)-join', '}else{'ALL'}
        Write-Host ('{0,-20} {1,-14} {2} [requested: {3}]' -f $server.Server,$server.Status,$server.Message,$requested)
        foreach($instance in @($server.Instances)){
            $fullName=Get-PropertyValue $instance 'FullName' ("$($server.Server)\$($instance.InstanceName)")
            Write-Host ("  {0} | {1} | target {2} | {3}" -f $fullName,$instance.Version,$instance.TargetVersion,$instance.Edition) -ForegroundColor DarkGray
            $consoleReleaseDate=Format-ReleaseDate (Get-PropertyValue $instance 'ReleaseDate' 'Unknown');if($consoleReleaseDate-ne'Unknown'){$consoleAge=[math]::Max(0,[int](([datetime]::UtcNow.Date-[datetime]$consoleReleaseDate).TotalDays));Write-Host ("    package {0}: released {1}; age {2} day(s)" -f (Get-PropertyValue $instance 'UpdateName' ''),$consoleReleaseDate,$consoleAge) -ForegroundColor DarkGray}
            foreach($backup in @($instance.Backups)){Write-Host ("    backup {0}: {1}" -f $backup.Database,$backup.LastFull) -ForegroundColor DarkGray}
            foreach($warning in @($instance.BackupWarnings)){Write-Host ("    WARNING: {0}" -f $warning) -ForegroundColor Yellow}
        }
    }
    Write-Host "Dashboard: $dashboardPath"
}
function Set-ServerState {
    param($State,[string]$Server,[string]$Status,[string]$Message)
    $entry = @($State.Servers | Where-Object Server -eq $Server)[0]
    $entry.Status = $Status; $entry.Message = $Message
    if($entry.PSObject.Properties.Name-contains'LastChangeUtc'){$entry.LastChangeUtc=[datetime]::UtcNow.ToString('o')}
    else{$entry|Add-Member NoteProperty LastChangeUtc ([datetime]::UtcNow.ToString('o'))}
    Save-State $State
}
function Confirm-Scope {
    param([string[]]$Names)
    Write-Host 'Approved DBA scope:' -ForegroundColor Cyan
    for ($i=0;$i-lt$Names.Count;$i++) { Write-Host ("{0}. {1}" -f ($i+1),$Names[$i]) }
    if (-not $ApproveScope) { $answer=Read-Host "Type $($Names.Count) to confirm this exact list";if($answer-ne[string]$Names.Count){throw 'Scope confirmation failed.'} }
}
function Get-RemoteInventory {
    param([Management.Automation.Runspaces.PSSession]$Session)
    Invoke-Command -Session $Session -ScriptBlock {
        $registry = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
        $instances = @()
        if (Test-Path $registry) {
            $map=Get-ItemProperty $registry
            foreach($property in $map.PSObject.Properties|Where-Object{$_.Name-notmatch'^PS'}){
                $name=[string]$property.Name;$server=if($name-eq'MSSQLSERVER'){'localhost'}else{"localhost\$name"}
                try{
                    $c=New-Object Data.SqlClient.SqlConnection "Server=$server;Database=master;Integrated Security=SSPI;Encrypt=False;Connect Timeout=15"
                    try{$c.Open();$q=$c.CreateCommand();$q.CommandTimeout=120;$q.CommandText=@"
SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) Edition,CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(32)) ProductVersion,CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(32)) UpdateLevel,CAST(SERVERPROPERTY('IsClustered') AS int) IsClustered,CAST(SERVERPROPERTY('IsHadrEnabled') AS int) IsHadrEnabled,ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0) IsSysadmin,(SELECT COUNT(*) FROM sys.availability_replicas) ReplicaCount;
"@;$r=$q.ExecuteReader();[void]$r.Read();$info=[pscustomobject]@{InstanceName=$name;Edition=[string]$r.GetValue(0);Version=[string]$r.GetValue(1);UpdateLevel=[string]$r.GetValue(2);IsClustered=[int]$r.GetValue(3);IsHadrEnabled=[int]$r.GetValue(4);IsSysadmin=[int]$r.GetValue(5);ReplicaCount=[int]$r.GetValue(6)};$r.Close();$q.CommandText=@"
SELECT d.name DatabaseName,d.state_desc State,b.backup_finish_date LastFullBackup FROM sys.databases d OUTER APPLY(SELECT TOP(1) backup_finish_date FROM msdb.dbo.backupset WHERE database_name=d.name AND type='D' ORDER BY backup_finish_date DESC)b WHERE d.database_id<>2 ORDER BY d.database_id;
"@;$a=New-Object Data.SqlClient.SqlDataAdapter $q;$t=New-Object Data.DataTable;[void]$a.Fill($t);$info|Add-Member NoteProperty Backups @($t|ForEach-Object{[pscustomobject]@{Database=[string]$_.DatabaseName;State=[string]$_.State;LastFull=if($_.LastFullBackup-eq[DBNull]::Value){'NEVER'}else{([datetime]$_.LastFullBackup).ToString('yyyy-MM-dd HH:mm:ss')}}});$instances+=$info}finally{if($c){$c.Dispose()}}
                }catch{$instances+=[pscustomobject]@{InstanceName=$name;Error=$_.Exception.Message}}
            }
        }
        $clus=Get-Service ClusSvc -ErrorAction SilentlyContinue
        $timeZone=Get-TimeZone
        [pscustomobject]@{ComputerName=$env:COMPUTERNAME;TimeZone=$timeZone.Id;UtcOffset=(Get-Date).ToString('zzz');ClusterRegistry=[bool](Test-Path 'HKLM:\Cluster');ClusterService=if($clus){$clus.Status.ToString()}else{'Absent'};Instances=$instances}
    }
}
function Get-RemotePostVerification {
    param([Management.Automation.Runspaces.PSSession]$Session,[string[]]$InstanceNames)
    Invoke-Command -Session $Session -ArgumentList (,$InstanceNames) -ScriptBlock {
        param([string[]]$Names)
        $services=@(Get-CimInstance Win32_Service)
        $sqlPattern='^(MSSQL|SQLAgent|SQLBrowser|SQLWriter|MsDtsServer|SSISScaleOut)'
        $automaticSql=@($services|Where-Object{$_.StartMode-eq'Auto'-and($_.Name-match$sqlPattern-or$_.DisplayName-match'^SQL Server')})
        $stoppedSql=@($automaticSql|Where-Object{$_.State-ne'Running'}|ForEach-Object{"$($_.Name)=$($_.State)"})
        $stoppedOther=@($services|Where-Object{$_.StartMode-eq'Auto'-and$_.State-ne'Running'-and$_.Name-notmatch$sqlPattern-and$_.DisplayName-notmatch'^SQL Server'}|ForEach-Object Name)
        $instanceResults=foreach($name in $Names){
            $engineName=if($name-eq'MSSQLSERVER'){'MSSQLSERVER'}else{"MSSQL`$$name"}
            $engine=@($services|Where-Object{$_.Name-eq$engineName})[0]
            $sqlTarget=if($name-eq'MSSQLSERVER'){'localhost'}else{"localhost\$name"}
            try{
                $connection=New-Object Data.SqlClient.SqlConnection "Server=$sqlTarget;Database=master;Integrated Security=SSPI;Encrypt=False;Connect Timeout=15"
                try{
                    $connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=120
                    $command.CommandText="SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(32));";$version=[string]$command.ExecuteScalar()
                    $command.CommandText="SELECT name,state_desc,HAS_DBACCESS(name) HasAccess FROM sys.databases ORDER BY database_id;"
                    $adapter=New-Object Data.SqlClient.SqlDataAdapter $command;$table=New-Object Data.DataTable;[void]$adapter.Fill($table)
                    $databases=@($table|ForEach-Object{[pscustomobject]@{Name=[string]$_.name;State=[string]$_.state_desc;HasAccess=[int]$_.HasAccess}})
                    [pscustomobject]@{InstanceName=$name;Version=$version;EngineService=$engineName;EngineStatus=if($engine){[string]$engine.State}else{'Missing'};Databases=$databases;Error=''}
                }finally{if($connection){$connection.Dispose()}}
            }catch{[pscustomobject]@{InstanceName=$name;Version='';EngineService=$engineName;EngineStatus=if($engine){[string]$engine.State}else{'Missing'};Databases=@();Error=$_.Exception.Message}}
        }
        [pscustomobject]@{
            ComputerName=$env:COMPUTERNAME
            LastBootUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            FreeBytes=[long](Get-Volume C).SizeRemaining
            PendingReboot=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')-or(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
            PartialFiles=@(Get-ChildItem 'C:\SqlPatchV3Remote' -Filter '*.partial' -Recurse -File -ErrorAction SilentlyContinue).Count
            AutomaticSqlServiceCount=$automaticSql.Count
            StoppedAutomaticSqlServices=$stoppedSql
            StoppedOtherAutomaticServices=$stoppedOther
            Instances=@($instanceResults)
        }
    }
}
function Get-PackageMap {
    param($State)
    $map=@{}
    $majors=@($State.Servers|ForEach-Object Instances|ForEach-Object Major|Sort-Object -Unique)
    foreach($major in $majors){
        $year=$supported[[int]$major];$files=@(Get-ChildItem -LiteralPath $PackageRoot -Filter "SQLServer$year-KB*-x64.exe" -File -ErrorAction SilentlyContinue)
        if($files.Count-ne1){throw "Expected exactly one SQL Server $year package in '$PackageRoot'; found $($files.Count)."}
        $map[[string]$major]=New-PackageRecord -Path $files[0].FullName -Major ([int]$major)
    }
    $map
}
function New-PackageRecord {
    param([string]$Path,[int]$Major)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Package '$Path' was not found."}
    $year=$supported[$Major];if([IO.Path]::GetFileName($Path)-notmatch"^SQLServer$year-KB\d+-x64\.exe$"){throw "Package '$Path' does not match SQL Server $year."}
    $sig=Get-AuthenticodeSignature -LiteralPath $Path
    if($sig.Status-ne'Valid'-or-not$sig.SignerCertificate-or$sig.SignerCertificate.Subject-notmatch'Microsoft Corporation'){throw "Package '$([IO.Path]::GetFileName($Path))' is not validly signed by Microsoft."}
    if(Get-Command Start-MpScan -ErrorAction SilentlyContinue){Start-MpScan -ScanType CustomScan -ScanPath $Path}
    $version=[version](Get-Item -LiteralPath $Path).VersionInfo.ProductVersion
    if($version.Major-ne$Major){throw "Package '$([IO.Path]::GetFileName($Path))' product version does not match SQL major $Major."}
    $release=Get-PackageReleaseMetadata -Path $Path -Major $Major -Version $version.ToString()
    [pscustomobject]@{Major=$Major;Path=[IO.Path]::GetFullPath($Path);Name=[IO.Path]::GetFileName($Path);Version=$version.ToString();Hash=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash;UpdateName=$release.UpdateName;ReleaseDate=$release.ReleaseDate;PackageAgeDays=$release.PackageAgeDays;MetadataSource=$release.MetadataSource;ReleaseMetadataSchema=2}
}
function Get-MicrosoftDownloadPage {
    param([Parameter(Mandatory)][string]$Uri)
    for($attempt=1;$attempt-le3;$attempt++){
        try{return Invoke-WebRequest -Uri $Uri -UseBasicParsing -ErrorAction Stop}
        catch{
            if($attempt-eq3){throw}
            Write-Warning "Microsoft Download Center request failed on attempt $attempt of 3: $($_.Exception.Message)"
            Start-Sleep -Seconds (2*$attempt)
        }
    }
}
function Get-PackageReleaseMetadata {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][int]$Major,[Parameter(Mandatory)][string]$Version)
    $fileName=[IO.Path]::GetFileName($Path);$kbMatch=[regex]::Match($fileName,'KB\d+','IgnoreCase');$kb=if($kbMatch.Success){$kbMatch.Value.ToUpperInvariant()}else{''}
    $cachePath=Join-Path $PackageRoot 'package-metadata.json';$cached=@()
    if(Test-Path -LiteralPath $cachePath -PathType Leaf){
        try{
            $document=Get-Content -LiteralPath $cachePath -Raw|ConvertFrom-Json;$pending=New-Object Collections.Queue
            foreach($item in @($document)){$pending.Enqueue($item)}
            while($pending.Count){$item=$pending.Dequeue();if($item.PSObject.Properties.Name-contains'FileName'){$cached+=,$item}elseif($item.PSObject.Properties.Name-contains'value'){foreach($nested in @($item.value)){$pending.Enqueue($nested)}}}
        }catch{Write-Warning "Ignoring invalid package metadata cache '$cachePath'.";$cached=@()}
    }
    if($cached.Count){
        $byKey=@{};foreach($item in $cached){$normalized=[pscustomobject]@{SchemaVersion=if($item.PSObject.Properties.Name -contains 'SchemaVersion'){[int]$item.SchemaVersion}else{1};FileName=[string]$item.FileName;Major=[int]$item.Major;Version=[string]$item.Version;KB=[string]$item.KB;UpdateName=[string]$item.UpdateName;ReleaseDate=Format-ReleaseDate $item.ReleaseDate;Source=[string]$item.Source};$byKey["$($normalized.FileName)|$($normalized.Version)"]=$normalized};$cached=@($byKey.Values)
        try{[IO.File]::WriteAllText($cachePath,($cached|Sort-Object FileName|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}catch{Write-Warning "Could not normalize package metadata cache '$cachePath': $($_.Exception.Message)"}
    }
    $cacheMatches=@($cached|Where-Object{([int]$_.SchemaVersion -eq 2) -and ([string]$_.FileName -eq $fileName) -and ([string]$_.Version -eq $Version)});$match=if($cacheMatches.Count){$cacheMatches[0]}else{$null}
    if($match){$cachedDate=Format-ReleaseDate $match.ReleaseDate;return [pscustomobject]@{UpdateName=$match.UpdateName;ReleaseDate=$cachedDate;PackageAgeDays=if($cachedDate-ne'Unknown'){[math]::Max(0,[int](([datetime]::UtcNow.Date-[datetime]$cachedDate).TotalDays))}else{'Unknown'};MetadataSource='Cached Microsoft Learn metadata'}}
    try{
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $response=Invoke-WebRequest -Uri $buildHistoryPages[$Major] -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $matchingRow=$null
        foreach($htmlRow in [regex]::Matches([string]$response.Content,'<tr[^>]*>[\s\S]*?</tr>','IgnoreCase')){$rowText=[Net.WebUtility]::HtmlDecode([regex]::Replace($htmlRow.Value,'<[^>]+>',' '));$rowText=[regex]::Replace($rowText,'\s+',' ').Trim();if(($rowText -match ('(^|\s)'+[regex]::Escape($Version)+'(\s|$)')) -and ($rowText -match ('\b'+[regex]::Escape($kb)+'\b'))){$matchingRow=$rowText;break}}
        if(-not$matchingRow){throw "Build $Version / $kb was not found in one Microsoft Learn CU table row."}
        $cu=[regex]::Match($matchingRow,'\bCU\d+\b','IgnoreCase');$dateMatch=[regex]::Match($matchingRow,'\b[A-Z][a-z]+ \d{1,2}, \d{4}\b')
        if(-not$cu.Success-or-not$dateMatch.Success){throw "CU name or release date was missing from the Microsoft Learn row for $Version / $kb."}
        $date=[datetime]::ParseExact($dateMatch.Value,'MMMM d, yyyy',[Globalization.CultureInfo]::GetCultureInfo('en-US')).ToString('yyyy-MM-dd')
        $record=[pscustomobject]@{SchemaVersion=2;FileName=$fileName;Major=$Major;Version=$Version;KB=$kb;UpdateName=$cu.Value.ToUpperInvariant();ReleaseDate=$date;Source=$buildHistoryPages[$Major]}
        $updated=@($cached|Where-Object{$_.FileName-ne$fileName-or$_.Version-ne$Version})+$record
        [IO.File]::WriteAllText($cachePath,($updated|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        [pscustomobject]@{UpdateName=$record.UpdateName;ReleaseDate=$date;PackageAgeDays=[math]::Max(0,[int](([datetime]::UtcNow.Date-[datetime]::ParseExact($date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)).TotalDays));MetadataSource='Microsoft Learn build history'}
    }catch{
        Write-Warning "Release date is unavailable for ${fileName}: $($_.Exception.Message)"
        [pscustomobject]@{UpdateName=if($kb){$kb}else{'Local update'};ReleaseDate='Unknown';PackageAgeDays='Unknown';MetadataSource='Unknown (offline/local media)'}
    }
}
function Get-LatestUpdateForMajor {
    param([int]$Major)
    $year=$supported[$Major];$page=$downloadPages[$Major]
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $response=Get-MicrosoftDownloadPage -Uri $page
    $html=[Net.WebUtility]::HtmlDecode([string]$response.Content)
    $plain=[regex]::Replace($html,'<script[\s\S]*?</script>|<style[\s\S]*?</style>|<[^>]+>',' ');$plain=[regex]::Replace($plain,'\s+',' ')
    $filePattern="SQLServer$year-KB\d+-x64\.exe";$fileMatch=[regex]::Match($plain,$filePattern,'IgnoreCase')
    $versionMatch=[regex]::Match($plain,"Version:\s*($Major\.0\.\d+\.\d+)",'IgnoreCase')
    $cuMatch=[regex]::Match($plain,"Cumulative Update Package\s+(\d+)(?:\s+Azure Connect Pack)?\s+for SQL Server $year\s+-\s+(KB\d+)",'IgnoreCase')
    $urls=@($response.Links|ForEach-Object{if($_.PSObject.Properties.Name-contains'href'){[string]$_.href}}|Where-Object{$_-match"^https://download\.microsoft\.com/.*/$filePattern(?:\?.*)?$"})
    if(-not$urls.Count){$urlMatch=[regex]::Match($html,('https://download\.microsoft\.com/[^"''\s<>]+/{0}(?:\?[^"''\s<>]*)?'-f$filePattern),'IgnoreCase');if($urlMatch.Success){$urls=@($urlMatch.Value)}}
    if(-not$fileMatch.Success-or-not$versionMatch.Success-or-not$cuMatch.Success-or-not$urls.Count){throw "Could not read the latest SQL Server $year CU from Microsoft Download Center. Use reviewed local media instead."}
    $uri=[uri]$urls[0];if($uri.Scheme-ne'https'-or$uri.Host-ne'download.microsoft.com'){throw "Unexpected Microsoft download URL '$uri'."}
    [pscustomobject]@{Major=$Major;Year=$year;Name="CU$($cuMatch.Groups[1].Value)";KB=$cuMatch.Groups[2].Value.ToUpperInvariant();Version=$versionMatch.Groups[1].Value;FileName=$fileMatch.Value;Uri=$uri.AbsoluteUri}
}
function Get-LatestPackageMap {
    param($State)
    if(-not(Test-Path -LiteralPath $PackageRoot)){New-Item -ItemType Directory -Path $PackageRoot -Force|Out-Null}
    $map=@{};$majors=@($State.Servers|ForEach-Object Instances|ForEach-Object Major|Sort-Object -Unique)
    foreach($major in $majors){
        $update=Get-LatestUpdateForMajor -Major ([int]$major);Write-Host "Latest SQL Server $($update.Year): $($update.Name) $($update.KB), build $($update.Version)" -ForegroundColor Cyan
        $destination=Join-Path $PackageRoot $update.FileName
        if(-not(Test-Path -LiteralPath $destination -PathType Leaf)){
            $partial=$destination+'.download';Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            try{Write-Host "Downloading $($update.FileName) from Microsoft...";if(Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue){Start-BitsTransfer -Source $update.Uri -Destination $partial -DisplayName 'SQL Patch V3 preparation'}else{Invoke-WebRequest -Uri $update.Uri -OutFile $partial -UseBasicParsing};Move-Item -LiteralPath $partial -Destination $destination}
            catch{Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue;throw}
        }
        $record=New-PackageRecord -Path $destination -Major ([int]$major)
        if([version]$record.Version-ne[version]$update.Version){throw "Downloaded package build $($record.Version) does not match Microsoft metadata $($update.Version)."}
        Write-Host "Release date: $($record.ReleaseDate); package age: $($record.PackageAgeDays) day(s)" -ForegroundColor Cyan
        $map[[string]$major]=$record
    }
    $map
}
function Copy-VerifiedToSession {
    param([string]$LocalPath,[string]$RemotePath,[Management.Automation.Runspaces.PSSession]$Session)
    $localHash=(Get-FileHash $LocalPath -Algorithm SHA256).Hash
    $existing=Invoke-Command -Session $Session -ArgumentList $RemotePath -ScriptBlock{param($Path);if(Test-Path $Path -PathType Leaf){(Get-FileHash $Path -Algorithm SHA256).Hash}}
    if($existing-eq$localHash){return 'AlreadyPresent'}
    $partial=$RemotePath+'.partial'
    for($attempt=1;$attempt-le3;$attempt++){
        try{
            Invoke-Command -Session $Session -ArgumentList $partial -ScriptBlock{param($Path);Remove-Item $Path -Force -ErrorAction SilentlyContinue}
            Copy-Item $LocalPath -Destination $partial -ToSession $Session -Force
            $copiedHash=Invoke-Command -Session $Session -ArgumentList $partial -ScriptBlock{param($Path);(Get-FileHash $Path -Algorithm SHA256).Hash}
            if($copiedHash-ne$localHash){throw "SHA-256 mismatch after copy attempt $attempt."}
            Invoke-Command -Session $Session -ArgumentList @($partial,$RemotePath) -ScriptBlock{param($Partial,$Final);Move-Item $Partial $Final -Force}
            return 'Copied'
        }
        catch{
            Invoke-Command -Session $Session -ArgumentList $partial -ScriptBlock{param($Path);Remove-Item $Path -Force -ErrorAction SilentlyContinue} -ErrorAction SilentlyContinue
            if($attempt-ge3){throw "Copy to '$RemotePath' failed after three attempts: $($_.Exception.Message)"}
            Start-Sleep 5
        }
    }
}

try {
    $scope=@(Get-Scope);$scopeTargets=@($scope|ForEach-Object Targets);$scopeHash=Get-ScopeHash $scopeTargets
    if($Mode-eq'ValidateScope'){Confirm-Scope $scopeTargets;Write-Host "Scope valid: $($scope.Count) server(s), $($scopeTargets.Count) target(s), SHA256 $scopeHash" -ForegroundColor Green;exit 0}
    if($Mode-eq'Dashboard'){
        $state=Read-State;$enriched=$false
        foreach($package in @($state.Packages)){
            if($package.PSObject.Properties.Name -notcontains 'ReleaseMetadataSchema' -or [int]$package.ReleaseMetadataSchema -ne 2 -or (Format-ReleaseDate $package.ReleaseDate) -eq 'Unknown'){
                $metadata=Get-PackageReleaseMetadata -Path $package.Path -Major ([int]$package.Major) -Version $package.Version
                Set-PropertyValue $package UpdateName $metadata.UpdateName;Set-PropertyValue $package ReleaseDate $metadata.ReleaseDate;Set-PropertyValue $package PackageAgeDays $metadata.PackageAgeDays;Set-PropertyValue $package MetadataSource $metadata.MetadataSource;Set-PropertyValue $package ReleaseMetadataSchema 2;$enriched=$true
            }
            foreach($instance in @($state.Servers|ForEach-Object Instances|Where-Object{$_.Major-eq$package.Major})){
                if($instance.PSObject.Properties.Name -notcontains 'ReleaseMetadataSchema' -or [int]$instance.ReleaseMetadataSchema -ne 2 -or (Format-ReleaseDate $instance.ReleaseDate) -eq 'Unknown'){Set-PropertyValue $instance UpdateName $package.UpdateName;Set-PropertyValue $instance ReleaseDate $package.ReleaseDate;Set-PropertyValue $instance PackageAgeDays $package.PackageAgeDays;Set-PropertyValue $instance MetadataSource $package.MetadataSource;Set-PropertyValue $instance ReleaseMetadataSchema 2;$enriched=$true}
            }
        }
        if($enriched){Save-State $state}else{Show-Console $state};Write-Host "Open: $dashboardPath";exit 0
    }
    if($Mode-eq'Inventory'){
        Confirm-Scope $scopeTargets
        $state=[pscustomobject]@{SchemaVersion='1.3';Cycle=$Cycle;ScopeHash=$scopeHash;Stage='Inventory';Transport=$Transport;UpdatedUtc='';Packages=@();Servers=@($scope|ForEach-Object{[pscustomobject]@{Server=$_.Server;RequestedInstances=@($_.RequestedInstances);Status='Pending';Message='Waiting';LastChangeUtc='';TimeZone='Not checked';UtcOffset='';FreeGiB='Not checked';PendingReboot='Not checked';PartialFiles='Not checked';Instances=@()}})};Save-State $state
        foreach($targetServer in $scope){$server=$targetServer.Server;$session=$null;try{Set-ServerState $state $server 'Connecting' 'Opening remote session';$session=New-TargetSession $server;Set-ServerState $state $server 'Inventory' 'Reading SQL instances and backup history';$inventory=Get-RemoteInventory $session;$entry=@($state.Servers|Where-Object { $_.Server -eq $server })[0];$reasons=New-Object Collections.Generic.List[string]
            $entry.TimeZone=$inventory.TimeZone;$entry.UtcOffset=$inventory.UtcOffset
            if($inventory.ClusterRegistry){$reasons.Add('WSFC registry exists')};if($inventory.ClusterService-ne'Absent'-and$inventory.ClusterService-ne'Stopped'){$reasons.Add("Cluster Service $($inventory.ClusterService)")};if(-not@($inventory.Instances).Count){$reasons.Add('No SQL Database Engine instance found')}
            $requested=@($targetServer.RequestedInstances);$available=@($inventory.Instances|ForEach-Object InstanceName)
            foreach($name in $requested){if($name-notin$available){$reasons.Add("Requested instance $name was not found")}}
            $selected=if($requested.Count){@($inventory.Instances|Where-Object{$_.InstanceName-in$requested})}else{@($inventory.Instances)}
            $normalized=@();foreach($instance in $selected){if($instance.PSObject.Properties.Name-contains'Error'){$reasons.Add("$($instance.InstanceName): $($instance.Error)");continue};$instanceReasons=New-Object Collections.Generic.List[string];$major=([version]$instance.Version).Major;if(-not$supported.ContainsKey($major)){$instanceReasons.Add("unsupported major $major")};if($instance.Edition-notmatch'Express|^Standard Edition|Standard Developer|Developer Edition'){$instanceReasons.Add("unsupported edition $($instance.Edition)")};if($instance.IsClustered-or$instance.IsHadrEnabled-or$instance.ReplicaCount){$instanceReasons.Add('FCI/Always On/AG detected')};if(-not$instance.IsSysadmin){$instanceReasons.Add('current account is not sysadmin')};foreach($reason in $instanceReasons){$reasons.Add("$($instance.InstanceName): $reason")};$warnings=@(Get-BackupWarnings $instance.Backups);$normalized+=[pscustomobject]@{FullName="$server\$($instance.InstanceName)";InstanceName=$instance.InstanceName;Major=$major;Edition=$instance.Edition;Version=$instance.Version;UpdateLevel=$instance.UpdateLevel;TargetVersion='Not selected';Readiness=if($instanceReasons.Count){'Blocked'}else{'Ready'};SqlReady='Yes';Standalone=if($instance.IsClustered-or$instance.IsHadrEnabled-or$instance.ReplicaCount){'No'}else{'Yes'};Sysadmin=if($instance.IsSysadmin){'Yes'}else{'No'};PackageName='Not selected';UpdateName='Not selected';ReleaseDate='Unknown';PackageAgeDays='Unknown';MetadataSource='Not queried';ReleaseMetadataSchema=2;DistributionState='Not staged';PackageState='Not verified';PackageHashVerified='Not checked';BackupAction='Inventory only';Backups=@($instance.Backups);BackupWarnings=$warnings}};$entry.Instances=$normalized
            $warningCount=@($normalized|ForEach-Object BackupWarnings).Count
            if($reasons.Count){Set-ServerState $state $server 'Blocked' ($reasons-join'; ')}else{Set-ServerState $state $server 'Ready' ("{0} instance(s); inventory complete; {1} backup warning(s)" -f $normalized.Count,$warningCount)}
        }catch{Set-ServerState $state $server 'Failed' $_.Exception.Message}finally{if($session){Remove-PSSession $session}}}
        $state.Stage=if(@($state.Servers|Where-Object { $_.Status -in @('Blocked','Failed') }).Count){'InventoryBlocked'}else{'InventoryReady'};Save-State $state;if($state.Stage-ne'InventoryReady'){exit 1};exit 0
    }
    $state=Read-State;if($state.ScopeHash-ne$scopeHash){throw 'targets.txt changed after Inventory. Run Inventory again.'}
    if($Mode-eq'Backup'){
        if(-not$ConfirmBackup){throw 'Backup requires -ConfirmBackup.'}
        if($BackupChoice-ne'1'){throw 'Backup mode requires BackupChoice 1 (system databases).'}
        if($state.Stage-ne'InventoryReady'){throw "Backup requires InventoryReady; current stage is $($state.Stage)."}
        foreach($targetServer in $scope){
            $server=$targetServer.Server;$entry=@($state.Servers|Where-Object { $_.Server -eq $server })[0];$session=$null
            try{
                Set-ServerState $state $server 'BackingUp' 'Creating and verifying COPY_ONLY system-database backups'
                $session=New-TargetSession $server
                Invoke-Command -Session $session -ScriptBlock{New-Item -ItemType Directory -Path 'C:\SqlPatchV3Remote\V2' -Force|Out-Null}
                foreach($worker in @(Get-ChildItem $V2SourcePath -File)){[void](Copy-VerifiedToSession $worker.FullName "C:\SqlPatchV3Remote\V2\$($worker.Name)" $session)}
                foreach($instance in @($entry.Instances)){
                    $backupResult=Invoke-Command -Session $session -ArgumentList @($instance.InstanceName,$BackupChoice) -ScriptBlock{param($Instance,$Backup);$lines=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\SqlPatchV3Remote\V2\Invoke-SqlPatchV2Local.ps1 -InstanceName $Instance -BackupOnly -BackupChoice $Backup);$code=$LASTEXITCODE;[pscustomobject]@{ExitCode=$code;Output=($lines-join"`n")}}
                    if($backupResult.ExitCode-ne0){throw "V2 backup failed for $($instance.InstanceName) with exit $($backupResult.ExitCode). $($backupResult.Output)"}
                }
                $inventory=Get-RemoteInventory $session
                foreach($instance in @($entry.Instances)){$actual=@($inventory.Instances|Where-Object { $_.InstanceName -eq $instance.InstanceName })[0];if(-not$actual-or$actual.PSObject.Properties.Name-contains'Error'){throw "Could not refresh backup history for $($instance.InstanceName)."};$instance.Backups=@($actual.Backups);$instance.BackupWarnings=@(Get-BackupWarnings $actual.Backups);$instance.BackupAction='System COPY_ONLY verified'}
                $warningCount=@($entry.Instances|ForEach-Object BackupWarnings).Count
                Set-ServerState $state $server 'Ready' ("COPY_ONLY backups completed and verified; inventory refreshed; {0} backup warning(s) remain" -f $warningCount)
            }catch{$state.Stage='BackupFailed';Set-ServerState $state $server 'Failed' $_.Exception.Message;Save-State $state;throw}finally{if($session){Remove-PSSession $session}}
        }
        $state.Stage='InventoryReady';Save-State $state;exit 0
    }
    if($Mode-eq'Prepare'){
        if($state.Stage-notin@('InventoryReady','Prepared','PreflightReady')){throw "Prepare requires InventoryReady; current stage is $($state.Stage)."};$packages=if($DownloadLatest){Get-LatestPackageMap $state}else{Get-PackageMap $state}
        $state.Packages=@($packages.GetEnumerator()|ForEach-Object{[pscustomobject]@{Major=[int]$_.Key;Name=$_.Value.Name;Version=$_.Value.Version;Hash=$_.Value.Hash;Path=$_.Value.Path;UpdateName=$_.Value.UpdateName;ReleaseDate=$_.Value.ReleaseDate;PackageAgeDays=$_.Value.PackageAgeDays;MetadataSource=$_.Value.MetadataSource;ReleaseMetadataSchema=2}})
        foreach($targetServer in $scope){$server=$targetServer.Server;$session=$null;try{Set-ServerState $state $server 'Copying' 'Hash pre-check; resumable verified staging';$session=New-TargetSession $server;Invoke-Command -Session $session -ScriptBlock{New-Item -ItemType Directory -Path 'C:\SqlPatchV3Remote\V2','C:\SqlPatchV3Remote\Packages' -Force|Out-Null};$results=New-Object Collections.Generic.List[string];Get-ChildItem $V2SourcePath -File|ForEach-Object{$remote="C:\SqlPatchV3Remote\V2\$($_.Name)";$results.Add("worker/$($_.Name): $(Copy-VerifiedToSession $_.FullName $remote $session)")};$entry=@($state.Servers|Where-Object { $_.Server -eq $server })[0];foreach($instance in @($entry.Instances)){$p=$packages[[string]$instance.Major];$instance.TargetVersion=$p.Version;$instance.PackageName=$p.Name;Set-PropertyValue $instance UpdateName $p.UpdateName;Set-PropertyValue $instance ReleaseDate $p.ReleaseDate;Set-PropertyValue $instance PackageAgeDays $p.PackageAgeDays;Set-PropertyValue $instance MetadataSource $p.MetadataSource;Set-PropertyValue $instance ReleaseMetadataSchema 2;$remote="C:\SqlPatchV3Remote\Packages\$($p.Name)";$copyState=Copy-VerifiedToSession $p.Path $remote $session;$instance.DistributionState=$copyState;$instance.PackageState='Staged';$instance.PackageHashVerified='Yes';$results.Add("package/$($p.Name): $copyState; released $($p.ReleaseDate)")};Set-ServerState $state $server 'Prepared' ($results-join'; ')
        }catch{Set-ServerState $state $server 'Failed' $_.Exception.Message;throw}finally{if($session){Remove-PSSession $session}}};$state.Stage='Prepared';Save-State $state;exit 0
    }
    if($Mode-eq'Preflight'){
        if($state.Stage-notin@('Prepared','PreflightReady')){throw "Preflight requires Prepared state; current stage is $($state.Stage)."}
        foreach($targetServer in $scope){$server=$targetServer.Server;$entry=@($state.Servers|Where-Object Server -eq $server)[0];$session=$null
            try{
                Set-ServerState $state $server 'Preflight' 'Verifying remote inventory, media hashes, disk, reboot state, and backup history'
                $session=New-TargetSession $server;$inventory=Get-RemoteInventory $session
                if($inventory.ClusterRegistry-or($inventory.ClusterService-ne'Absent'-and$inventory.ClusterService-ne'Stopped')){throw 'WSFC state appeared after Inventory.'}
                foreach($instance in @($entry.Instances)){
                    $actual=@($inventory.Instances|Where-Object InstanceName -eq $instance.InstanceName)[0]
                    if(-not$actual){throw "Requested instance $($instance.InstanceName) is missing."}
                    if($actual.PSObject.Properties.Name-contains'Error'){throw "$($instance.InstanceName): $($actual.Error)"}
                    if($actual.IsClustered-or$actual.IsHadrEnabled-or$actual.ReplicaCount){throw "$($instance.InstanceName): FCI/Always On/AG appeared after Inventory."}
                    if(-not$actual.IsSysadmin){throw "$($instance.InstanceName): current account is no longer sysadmin."}
                    $instance.Version=$actual.Version;$instance.UpdateLevel=$actual.UpdateLevel;$instance.Backups=@($actual.Backups);$instance.BackupWarnings=@(Get-BackupWarnings $actual.Backups);$instance.Readiness='Ready';$instance.SqlReady='Yes';$instance.Standalone='Yes';$instance.Sysadmin='Yes'
                    $package=@($state.Packages|Where-Object Major -eq $instance.Major)[0];if(-not$package){throw "Selected package metadata is missing for SQL major $($instance.Major)."}
                    if(-not(Test-Path -LiteralPath $package.Path -PathType Leaf)-or(Get-FileHash -LiteralPath $package.Path -Algorithm SHA256).Hash-ne$package.Hash){throw "Controller package '$($package.Name)' is missing or changed."}
                    $remotePath="C:\SqlPatchV3Remote\Packages\$($package.Name)"
                    $remote=Invoke-Command -Session $session -ArgumentList $remotePath -ScriptBlock{param($Path);if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};$sig=Get-AuthenticodeSignature -LiteralPath $Path;[pscustomobject]@{Hash=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash;Signature=$sig.Status.ToString();Signer=if($sig.SignerCertificate){$sig.SignerCertificate.Subject}else{''}}}
                    if(-not$remote-or$remote.Hash-ne$package.Hash-or$remote.Signature-ne'Valid'-or$remote.Signer-notmatch'Microsoft Corporation'){throw "Remote package '$($package.Name)' failed hash or Microsoft signature verification."};$instance.PackageName=$package.Name;$instance.PackageState='Signature + SHA-256 verified';$instance.PackageHashVerified='Yes'
                }
                foreach($worker in Get-ChildItem -LiteralPath $V2SourcePath -File){$remotePath="C:\SqlPatchV3Remote\V2\$($worker.Name)";$remoteHash=Invoke-Command -Session $session -ArgumentList $remotePath -ScriptBlock{param($Path);if(Test-Path -LiteralPath $Path -PathType Leaf){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}};if($remoteHash-ne(Get-FileHash -LiteralPath $worker.FullName -Algorithm SHA256).Hash){throw "Remote worker '$($worker.Name)' failed hash verification."}}
                $hostState=Invoke-Command -Session $session -ScriptBlock{[pscustomobject]@{FreeBytes=[long](Get-Volume C).SizeRemaining;PendingReboot=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')-or(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired');PartialFiles=@(Get-ChildItem 'C:\SqlPatchV3Remote' -Filter '*.partial' -Recurse -File -ErrorAction SilentlyContinue).Count}}
                $entry.FreeGiB=[math]::Round($hostState.FreeBytes/1GB,2);$entry.PendingReboot=[string][bool]$hostState.PendingReboot;$entry.PartialFiles=[int]$hostState.PartialFiles
                if($hostState.FreeBytes-lt$MinimumTargetFreeBytes){throw "Only $([math]::Round($hostState.FreeBytes/1GB,2)) GiB is free; minimum is $([math]::Round($MinimumTargetFreeBytes/1GB,2)) GiB."}
                if($hostState.PendingReboot){throw 'A pending reboot exists before patching.'};if($hostState.PartialFiles){throw "$($hostState.PartialFiles) partial distribution file(s) exist."}
                $warningCount=@($entry.Instances|ForEach-Object BackupWarnings).Count
                Set-ServerState $state $server 'PreflightReady' ("All remote hashes/readiness checks passed; {0} backup warning(s)" -f $warningCount)
            }catch{Set-ServerState $state $server 'Failed' $_.Exception.Message;$state.Stage='PreflightBlocked';Save-State $state;throw}finally{if($session){Remove-PSSession $session}}
        }
        $state.Stage='PreflightReady';Save-State $state;exit 0
    }
    if($Mode-eq'PostVerify'){
        if($state.Stage-notin@('InventoryReady','Prepared','PreflightReady','Applying','Failed','Complete','PostVerified','PostVerifyFailed')){throw "PostVerify requires completed Inventory or a later stage; current stage is $($state.Stage)."}
        $previousStage=$state.Stage;$baseStage=if($previousStage-in@('PostVerified','PostVerifyFailed')){Get-PropertyValue $state 'PostVerifyBaseStage' $previousStage}else{$previousStage};Set-PropertyValue $state PostVerifyBaseStage $baseStage;$postPatch=$baseStage-in@('Applying','Failed','Complete');$previousServerState=@{}
        foreach($entry in @($state.Servers)){$previousServerState[$entry.Server]=[pscustomobject]@{Status=$entry.Status;Message=$entry.Message}}
        $state.Stage='PostVerifying';Save-State $state;$failed=$false
        foreach($targetServer in $scope){
            $server=$targetServer.Server;$entry=@($state.Servers|Where-Object Server -eq $server)[0];$session=$null
            try{
                Set-ServerState $state $server 'PostVerifying' 'Checking services, databases, builds, reboot state, disk, and SQL stability twice'
                $session=New-TargetSession $server;$names=@($entry.Instances|ForEach-Object InstanceName)
                $first=Get-RemotePostVerification $session $names;Start-Sleep -Seconds 2;$second=Get-RemotePostVerification $session $names
                $serverIssues=New-Object Collections.Generic.List[string]
                if($second.StoppedAutomaticSqlServices.Count){$serverIssues.Add("Automatic SQL service(s) not running: $($second.StoppedAutomaticSqlServices-join', ')")}
                if($second.PendingReboot){$serverIssues.Add('Pending reboot remains')};if($second.PartialFiles){$serverIssues.Add("$($second.PartialFiles) partial package file(s) remain")};if($second.FreeBytes-lt$MinimumTargetFreeBytes){$serverIssues.Add("Only $([math]::Round($second.FreeBytes/1GB,2)) GiB free")}
                Set-PropertyValue $entry FreeGiB ([math]::Round($second.FreeBytes/1GB,2));Set-PropertyValue $entry PendingReboot ([string][bool]$second.PendingReboot);Set-PropertyValue $entry PartialFiles ([int]$second.PartialFiles);Set-PropertyValue $entry LastBootUtc $second.LastBootUtc
                $runningSql=[int]$second.AutomaticSqlServiceCount-@($second.StoppedAutomaticSqlServices).Count;Set-PropertyValue $entry SqlServiceSummary ("{0}/{1} automatic SQL services running"-f$runningSql,$second.AutomaticSqlServiceCount)
                $otherStopped=@($second.StoppedOtherAutomaticServices);$warning=if($otherStopped.Count){"Warning only: $($otherStopped.Count) other automatic Windows service(s) stopped: $((@($otherStopped|Select-Object -First 8))-join', ')"}else{'No stopped non-SQL automatic services reported'};Set-PropertyValue $entry PostVerifyWarnings $warning
                foreach($instance in @($entry.Instances)){
                    $issues=New-Object Collections.Generic.List[string];$one=@($first.Instances|Where-Object{$_.InstanceName-eq$instance.InstanceName})[0];$two=@($second.Instances|Where-Object{$_.InstanceName-eq$instance.InstanceName})[0]
                    if(-not$one-or-not$two){$issues.Add('Instance missing from one or both probes')}
                    elseif($one.Error-or$two.Error){$issues.Add("SQL query failed: $($one.Error) $($two.Error)".Trim())}
                    else{
                        if($one.Version-ne$two.Version){$issues.Add("Build changed between probes: $($one.Version) -> $($two.Version)")}
                        if($two.EngineStatus-ne'Running'){$issues.Add("Engine service $($two.EngineService) is $($two.EngineStatus)")}
                        $badDatabases=@($two.Databases|Where-Object{$_.State-ne'ONLINE'-or$_.HasAccess-ne1});if($badDatabases.Count){$issues.Add("Database issue(s): $(@($badDatabases|ForEach-Object{"$($_.Name)=$($_.State)/access:$($_.HasAccess)"})-join', ')")}
                        if($instance.TargetVersion-ne'Not selected'-and[version]$two.Version-lt[version]$instance.TargetVersion){$issues.Add("Build $($two.Version) is below target $($instance.TargetVersion)")}
                        $instance.Version=$two.Version;$databaseCount=@($two.Databases).Count;Set-PropertyValue $instance DatabaseSummary ("$databaseCount/$databaseCount online and accessible");Set-PropertyValue $instance EngineServiceSummary ("$($two.EngineService)=$($two.EngineStatus)")
                    }
                    foreach($serverIssue in $serverIssues){$issues.Add($serverIssue)}
                    if($issues.Count){Set-PropertyValue $instance PostVerifyStatus 'Failed';Set-PropertyValue $instance PostVerifyDetails ($issues-join'; ');$failed=$true}else{Set-PropertyValue $instance PostVerifyStatus 'Passed';Set-PropertyValue $instance PostVerifyDetails 'Two SQL probes, services, databases, build, and host checks passed'}
                }
                if($serverIssues.Count){Set-ServerState $state $server 'PostVerifyFailed' ($serverIssues-join'; ');$failed=$true}else{Set-ServerState $state $server 'PostVerified' 'Two SQL probes passed; selected databases are online/accessible and automatic SQL services are running'}
            }catch{$failed=$true;Set-PropertyValue $entry PostVerifyWarnings $_.Exception.Message;foreach($instance in @($entry.Instances)){Set-PropertyValue $instance PostVerifyStatus 'Failed';Set-PropertyValue $instance PostVerifyDetails $_.Exception.Message};Set-ServerState $state $server 'PostVerifyFailed' $_.Exception.Message}finally{if($session){Remove-PSSession $session}}
        }
        if($failed){$state.Stage='PostVerifyFailed'}elseif($postPatch){$state.Stage='PostVerified'}else{$state.Stage=$previousStage;foreach($entry in @($state.Servers)){$prior=$previousServerState[$entry.Server];$entry.Status=$prior.Status;$entry.Message=$prior.Message}}
        Save-State $state;if($failed){exit 1};exit 0
    }
    if($Mode-eq'Apply'){
        if(-not$ConfirmApply){throw 'Apply requires -ConfirmApply.'};$resumeAfterPostVerify=$state.Stage-eq'PostVerifyFailed'-and(Get-PropertyValue $state 'PostVerifyBaseStage' '')-in@('Applying','Failed');if($state.Stage-notin@('PreflightReady','Applying','Failed')-and-not$resumeAfterPostVerify){throw "Apply requires PreflightReady state or a failed Apply resume state; current stage is $($state.Stage)."};$state.Stage='Applying';Save-State $state
        foreach($targetServer in $scope){$server=$targetServer.Server;$entry=@($state.Servers|Where-Object { $_.Server -eq $server })[0];if($entry.Status-eq'Complete'){continue};$session=$null;$patched=$false;try{$session=New-TargetSession $server;foreach($instance in @($entry.Instances)){if([version]$instance.Version-ge[version]$instance.TargetVersion){continue};$packageRecord=@($state.Packages|Where-Object { [int]$_.Major -eq [int]$instance.Major })[0];if(-not$packageRecord){throw "Frozen package metadata is missing for SQL major $($instance.Major)."};$package=Invoke-Command -Session $session -ArgumentList $packageRecord.Name -ScriptBlock{param($Name);$path="C:\SqlPatchV3Remote\Packages\$Name";if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Frozen package is missing: $path"};$path};if($BackupChoice-ne'0'){Set-ServerState $state $server 'BackingUp' "COPY_ONLY choice $BackupChoice for $($instance.InstanceName)";$backupResult=Invoke-Command -Session $session -ArgumentList @($instance.InstanceName,$BackupChoice) -ScriptBlock{param($Instance,$Backup);$lines=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\SqlPatchV3Remote\V2\Invoke-SqlPatchV2Local.ps1 -InstanceName $Instance -BackupOnly -BackupChoice $Backup);$code=$LASTEXITCODE;[pscustomobject]@{ExitCode=$code;Output=($lines-join"`n")}};if($backupResult.ExitCode-ne0){throw "V2 backup failed for $($instance.InstanceName) with exit $($backupResult.ExitCode). $($backupResult.Output)"}};Set-ServerState $state $server 'Patching' "Installing $($instance.InstanceName) to $($instance.TargetVersion)";$output=Invoke-Command -Session $session -ArgumentList @($instance.InstanceName,$package) -ScriptBlock{param($Instance,$Package);$lines=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\SqlPatchV3Remote\V2\Invoke-SqlPatchV2Local.ps1 -InstanceName $Instance -BackupChoice 0 -LocalPackagePath $Package -ConfirmInstall -Restart No);$code=$LASTEXITCODE;[pscustomobject]@{ExitCode=$code;Output=($lines-join"`n")}};if($output.ExitCode-ne0){throw "V2 patch failed for $($instance.InstanceName) with exit $($output.ExitCode). $($output.Output)"};$patched=$true}
            if($patched){Set-ServerState $state $server 'Rebooting' 'Update installed; mandatory graceful remote restart requested';Invoke-Command -Session $session -ScriptBlock{shutdown.exe /r /t 5 /d p:4:2 /c 'SQL patch V3 completed; mandatory restart'|Out-Null};Remove-PSSession $session;$session=$null;Set-ServerState $state $server 'WaitingForOS' 'Waiting for remote PowerShell after restart';$deadline=[datetime]::UtcNow.AddSeconds($ReadyTimeoutSeconds);$ready=0;$requiredNames=@($entry.Instances|ForEach-Object InstanceName);while([datetime]::UtcNow-lt$deadline-and$ready-lt2){$candidate=$null;try{$candidate=New-TargetSession $server;$probe=Get-RemoteInventory $candidate;$selected=@($probe.Instances|Where-Object{$_.InstanceName-in$requiredNames});$queryReady=$selected.Count-eq$requiredNames.Count-and@($selected|Where-Object{$_.PSObject.Properties.Name-contains'Error'}).Count-eq0;if($queryReady){$ready++;if($ready-ge2){$session=$candidate;$candidate=$null}}else{$ready=0}}catch{$ready=0}finally{if($candidate){Remove-PSSession $candidate}};if($ready-lt2){Start-Sleep 10}};if($ready-lt2){throw "Server did not become SQL-ready within $ReadyTimeoutSeconds seconds."};Set-ServerState $state $server 'WaitingForSQL' 'Two consecutive selected-instance SQL query readiness probes passed'}
            Set-ServerState $state $server 'Validating' 'Querying final SQL builds';$final=Get-RemoteInventory $session;foreach($instance in @($entry.Instances)){$actual=@($final.Instances|Where-Object { $_.InstanceName -eq $instance.InstanceName })[0];if(-not$actual-or[version]$actual.Version-lt[version]$instance.TargetVersion){throw "$($instance.InstanceName) did not reach target $($instance.TargetVersion)."};$instance.Version=$actual.Version};Set-ServerState $state $server 'Complete' $(if($patched){'All selected updates installed; remote server rebooted and SQL readiness passed'}else{'All selected instances were already at or above supplied package builds; no reboot required'})
        }catch{Set-ServerState $state $server 'Failed' $_.Exception.Message;$state.Stage='Failed';Save-State $state;throw}finally{if($session){Remove-PSSession $session}}};$state.Stage='Complete';Save-State $state;exit 0
    }
}
catch{Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red;exit 1}
