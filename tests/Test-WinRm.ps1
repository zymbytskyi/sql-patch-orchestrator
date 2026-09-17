#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$engine=Join-Path $root 'Invoke-SqlPatchV3Remote.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($engine,[ref]$tokens,[ref]$errors)
foreach($name in @('Add-TargetTrustedHost','New-TargetSession','Get-Scope')){
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert($Condition,[string]$Message){if(-not$Condition){throw $Message}}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('SqlPatchWinRm-'+[guid]::NewGuid().ToString('N'))
$cycleRoot=$testRoot
$Transport='WinRM';$Credential=$null
$global:SqlPatchMockpolicy='old.example.test'
$global:SqlPatchMocksource='Local';$global:SqlPatchMockdenyWrite=$false;$global:SqlPatchMockignoreWrite=$false
$global:SqlPatchMockattempts=@{};$global:SqlPatchMockwrites=0;$global:SqlPatchMockscenario='Mixed'
$global:SqlPatchMocktrustError='The WinRM client cannot process the request. Default credentials with Negotiate over HTTP can be used only if the target machine is part of the TrustedHosts list or the Allow implicit credentials for Negotiate option is specified.'
function Get-Item {
    [CmdletBinding()]param([string]$Path)
    Assert ($Path -eq 'WSMan:\localhost\Client\TrustedHosts') 'Unexpected policy read.'
    [pscustomobject]@{Value=$global:SqlPatchMockpolicy;SourceOfValue=$global:SqlPatchMocksource}
}
function Set-Item {
    [CmdletBinding()]param([string]$Path,[string]$Value,[switch]$Force)
    $global:SqlPatchMockwrites++
    if($global:SqlPatchMockdenyWrite){throw 'Access is denied.'}
    if(-not$global:SqlPatchMockignoreWrite){$global:SqlPatchMockpolicy=$Value}
}
function New-PSSession {
    [CmdletBinding()]param([string]$ComputerName,[string]$Authentication,[pscredential]$Credential)
    Assert (-not$Credential) 'Unexpected alternate credential.'
    Assert ($Authentication -eq 'Negotiate') 'Unexpected authentication.'
    if(-not$global:SqlPatchMockattempts.ContainsKey($ComputerName)){$global:SqlPatchMockattempts[$ComputerName]=0}
    $global:SqlPatchMockattempts[$ComputerName]++
    if($global:SqlPatchMockscenario -eq 'Denied'){throw 'Access is denied.'}
    if($global:SqlPatchMockscenario -eq 'Dns'){throw 'The server name cannot be resolved.'}
    if($global:SqlPatchMockscenario -eq 'Persistent'){throw $global:SqlPatchMocktrustError}
    if($ComputerName -ne 'HOST01' -and -not@($global:SqlPatchMockpolicy -split ',' | Where-Object {$ComputerName -like $_}).Count){throw $global:SqlPatchMocktrustError}
    [pscustomobject]@{ComputerName=$ComputerName}
}
try{
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $TargetListPath=Join-Path $testRoot 'targets.txt'
    $names=@(1..25|ForEach-Object{'HOST{0:00}' -f $_})
    [IO.File]::WriteAllLines($TargetListPath,$names)
    $scope=@(Get-Scope)
    Assert ($scope.Count-eq25) 'Scope still limits server count.'
    foreach($target in $scope){$s=New-TargetSession $target.Server;Assert ($s.ComputerName-eq$target.Server) 'Wrong session target.'}
    Assert ($global:SqlPatchMockattempts.HOST01-eq1) 'Healthy host was retried.'
    Assert ($global:SqlPatchMockattempts.HOST25-eq2) 'Failing target did not retry exactly once.'
    Assert ($global:SqlPatchMockpolicy.StartsWith('old.example.test,')) 'Existing trusted hosts were overwritten.'
    $audit=@(Get-Content (Join-Path $testRoot 'winrm-client-changes.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
    Assert ($audit.Count-eq24-and$audit[0].Previous-eq'old.example.test') 'Prior policy was not recorded.'
    $before=$global:SqlPatchMockwrites
    $global:SqlPatchMockpolicy='*';$null=New-TargetSession 'OTHER01'
    Assert ($global:SqlPatchMockwrites-eq$before) 'Existing wildcard was overwritten.'
    foreach($scenario in @('Denied','Dns')){
        $global:SqlPatchMockscenario=$scenario;$failed=$false
        try{$null=New-TargetSession $scenario}catch{$failed=$true}
        Assert $failed "$scenario should remain blocked."
        Assert ($global:SqlPatchMockwrites-eq$before) "$scenario incorrectly changed trust."
        Assert ($global:SqlPatchMockattempts[$scenario]-eq1) "$scenario retried needlessly."
    }
    $global:SqlPatchMockscenario='Persistent';$failed=$false
    try{$null=New-TargetSession 'PERSIST01'}catch{$failed=$_.Exception.Message -match 'still failed'}
    Assert ($failed-and$global:SqlPatchMockattempts.PERSIST01-eq2) 'Persistent failure did not stop after one retry.'
    $global:SqlPatchMockscenario='Mixed';$global:SqlPatchMockpolicy='';$global:SqlPatchMocksource='GPO';$failed=$false
    try{$null=New-TargetSession 'POLICY01'}catch{$failed=$_.Exception.Message -match 'Group Policy'}
    Assert ($failed-and$global:SqlPatchMockwrites-eq$before) 'GPO policy was modified.'
    $global:SqlPatchMocksource='Local';$global:SqlPatchMockdenyWrite=$true;$failed=$false
    try{$null=New-TargetSession 'NOADMIN01'}catch{$failed=$_.Exception.Message -match 'Administrator'}
    Assert ($failed-and$global:SqlPatchMockattempts.NOADMIN01-eq1) 'Missing elevation was not explained.'
    $global:SqlPatchMockdenyWrite=$false;$global:SqlPatchMockignoreWrite=$true;$failed=$false
    try{$null=New-TargetSession 'IGNORED01'}catch{$failed=$_.Exception.Message -match 'effective TrustedHosts'}
    Assert ($failed-and$global:SqlPatchMockattempts.IGNORED01-eq1) 'Ignored setting was not detected.'
    Write-Output '[PASS] 25 targets; exact implicit-credential error; bounded per-target retry; preserved settings and audit.'
    Write-Output '[PASS] Existing wildcard, access denial, DNS, GPO, missing elevation, ignored writes, persistent failure.'
    # Run the actual engine against a mocked remoting boundary. No remote scripts execute.
    $global:SqlPatchMockpolicy='old.example.test';$global:SqlPatchMocksource='Local';$global:SqlPatchMockignoreWrite=$false
    $global:SqlPatchMockattempts=@{};$global:SqlPatchMockhardFailure=$false;$global:SqlPatchMocksqlBlocked=$false
    function New-PSSession {
        [CmdletBinding()]param([string]$ComputerName,[string]$Authentication,[pscredential]$Credential)
        if(-not$global:SqlPatchMockattempts.ContainsKey($ComputerName)){$global:SqlPatchMockattempts[$ComputerName]=0}
        $global:SqlPatchMockattempts[$ComputerName]++
        if($global:SqlPatchMockhardFailure-and$ComputerName-eq'HOST02'){throw 'Access is denied.'}
        if($ComputerName-ne'HOST01'-and-not@($global:SqlPatchMockpolicy -split ',' | Where-Object {$ComputerName -like $_}).Count){throw $global:SqlPatchMocktrustError}
        # Null is accepted by the engine's typed session parameter; Invoke-Command is mocked below.
        $global:SqlPatchMockcurrentHost=$ComputerName
    }
    function Invoke-Command {
        param($Session,[scriptblock]$ScriptBlock)
        [pscustomobject]@{
            TimeZone='UTC';UtcOffset='+00:00';ClusterRegistry=$false;ClusterService='Absent'
            Instances=@([pscustomobject]@{
                InstanceName='MSSQLSERVER';Edition='Enterprise Edition: Core-based Licensing (64-bit)'
                Version='15.0.4480.2';UpdateLevel='CU';IsClustered=0
                IsHadrEnabled=[int]($global:SqlPatchMocksqlBlocked-and$global:SqlPatchMockcurrentHost-eq'HOST02');ReplicaCount=0;IsSysadmin=1
                Backups=@([pscustomobject]@{Database='sample';LastFull='NEVER';IsCopyOnly=$false;HasChecksum=$false;BackupPath='';AgeDays=$null})
            })
        }
    }
    $runRoot=Join-Path $testRoot 'Runs'
    $console=(& $engine -Mode Inventory -Cycle Test2026 -RunRoot $runRoot -TargetListPath $TargetListPath -ApproveScope 6>&1|Out-String)
    Assert ($LASTEXITCODE-eq0) ("Inventory should pass: "+(($console -split "`n"|Where-Object {$_ -match "Failed|FAILED:"}|Select-Object -First 1)-join""))
    $state=Get-Content (Join-Path $runRoot 'Test2026\state.json') -Raw|ConvertFrom-Json
    Assert ($state.Stage-eq'InventoryReady'-and$state.Servers.Count-eq25) 'Large inventory did not pass.'
    Assert (@($state.Servers|Where-Object Status -ne 'Ready').Count-eq0) 'Missing successful inventory targets.'
    Assert (([regex]::Matches($console,'backup sample:')).Count-eq25) 'Backup detail was repeated during progress.'
    Assert ($state.Servers[0].Instances[0].BackupWarnings.Count-eq1) 'Backup warning lost or treated as blocker.'
    $global:SqlPatchMockhardFailure=$true
    $console=(& $engine -Mode Inventory -Cycle Test2026 -RunRoot $runRoot -TargetListPath $TargetListPath -ApproveScope 6>&1|Out-String)
    Assert ($LASTEXITCODE-eq1) 'Denied target should block inventory.'
    $state=Get-Content (Join-Path $runRoot 'Test2026\state.json') -Raw|ConvertFrom-Json
    Assert ($state.Stage-eq'InventoryBlocked'-and$state.Servers[-1].Status-eq'Ready') 'Inventory stopped before the final healthy target.'
    $console=(& $engine -Mode Prepare -Cycle Test2026 -RunRoot $runRoot -TargetListPath $TargetListPath 6>&1|Out-String)
    Assert ($LASTEXITCODE-eq1-and$console-match'Prepare was not started') 'Failed inventory allowed preparation.'
    $global:SqlPatchMockhardFailure=$false;$global:SqlPatchMocksqlBlocked=$true
    $console=(& $engine -Mode Inventory -Cycle Test2026 -RunRoot $runRoot -TargetListPath $TargetListPath -ApproveScope 6>&1|Out-String)
    Assert ($LASTEXITCODE-eq1-and$console-match'FCI/Always On/AG detected') 'Standalone gate regressed.'
    Write-Output '[PASS] Actual inventory engine: 25 mixed targets, informational backups, compact output, failure isolation, preparation and AG gates.'
}finally{
    Get-Variable -Scope Global -Name SqlPatchMock* | Remove-Variable -Scope Global
    # Only the unique test directory created above is removed.
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
$global:LASTEXITCODE=0
