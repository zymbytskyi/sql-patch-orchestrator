#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
Import-Module Microsoft.PowerShell.Utility
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'SqlPatchParallel.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Invoke-SqlPatchV3Remote.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('Get-PropertyValue','Set-PropertyValue')){
    $node=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-eq$name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($Condition,$Message){if(-not$Condition){throw $Message}}
function Save-State {param($State)}
function Set-ServerState {param($State,$Server,$Status,$Message);$State.Servers[0].Status=$Status;$State.Servers[0].Message=$Message}
function Get-ItemProperty {param($Path,$ErrorAction);[pscustomobject]@{MachineGuid='CONTROLLER'}}
function Get-FileHash {param($LiteralPath);[pscustomobject]@{Hash='HASH'}}
function New-TargetSession {param($Server);'SESSION'}
function Remove-PSSession {param($Session)}
function Start-Sleep {param($Seconds)}
function Get-RemoteInventory {
    param($Session)
    [pscustomobject]@{ClusterRegistry=$false;ClusterService='Absent';Instances=@([pscustomobject]@{InstanceName='MSSQLSERVER';Version=$global:ApplyFixture.Version;IsClustered=0;IsHadrEnabled=$global:ApplyFixture.Hadr;ReplicaCount=0;IsSysadmin=1})}
}
function Invoke-Command {
    param($Session,[object[]]$ArgumentList,[scriptblock]$ScriptBlock)
    $text=$ScriptBlock.ToString()
    if($text-match 'SetupRunning='){
        return [pscustomobject]@{Id=$global:ApplyFixture.Identity;Boot='2026-01-01T00:00:00.0000000Z';SetupRunning=$false}
    }
    if($text-match 'Get-FileHash'){return 'HASH'}
    if($text-match 'SqlPatchStandaloneInstall'){
        $global:ApplyFixture.InstallCount++
        if(-not$global:ApplyFixture.SetupCode){$global:ApplyFixture.Version='16.0.2.0'}
        return [pscustomobject]@{Code=$global:ApplyFixture.SetupCode;Output='test result'}
    }
    if($text-match 'shutdown.exe'){$global:ApplyFixture.RebootCount++;return}
    if($text-match 'LastBootUpTime'){return '2026-01-02T00:00:00.0000000Z'}
    throw "Unmocked remote operation: $text"
}
function New-Case {
    $global:ApplyFixture=[pscustomobject]@{Identity='REMOTE';Version='16.0.1.0';Hadr=0;SetupCode=0;InstallCount=0;RebootCount=0}
    [pscustomobject]@{Servers=@([pscustomobject]@{Server='TEST';HostIdentity='REMOTE';Status='';Message='';Instances=@([pscustomobject]@{InstanceName='MSSQLSERVER';Major=16;Version='16.0.1.0';TargetVersion='16.0.2.0'})});Packages=@([pscustomobject]@{Major=16;Name='test.exe';Hash='HASH'})}
}
$V2SourcePath=$root;$BackupChoice='0';$ReadyTimeoutSeconds=10
try{
    $state=New-Case;Apply-OneServer $state $state.Servers[0] 'SESSION'
    Assert ($state.Servers[0].Status-eq'Complete'-and$global:ApplyFixture.InstallCount-eq1-and$global:ApplyFixture.RebootCount-eq1) 'Remote patch/reboot did not complete.'
    Apply-OneServer $state $state.Servers[0] 'SESSION'
    Assert ($global:ApplyFixture.InstallCount-eq1-and$global:ApplyFixture.RebootCount-eq1) 'Successful target was patched/rebooted twice.'
    $state=New-Case;$global:ApplyFixture.Identity='CONTROLLER';$state.Servers[0].HostIdentity='CONTROLLER'
    Apply-OneServer $state $state.Servers[0] 'SESSION'
    Assert ($state.Servers[0].Status-eq'AwaitingControllerRestart'-and$global:ApplyFixture.RebootCount-eq0) 'Controller was restarted automatically.'
    foreach($scenario in @('Identity','Hadr','UnknownOutcome','InstallerFailure')){
        $state=New-Case
        switch($scenario){
            Identity {$global:ApplyFixture.Identity='OTHER'}
            Hadr {$global:ApplyFixture.Hadr=1}
            UnknownOutcome {Set-PropertyValue $state.Servers[0].Instances[0] InstallOutcome 'Started'}
            InstallerFailure {$global:ApplyFixture.SetupCode=1}
        }
        $rejected=$false
        try{Apply-OneServer $state $state.Servers[0] 'SESSION'}catch{$rejected=$true}
        Assert ($rejected-and$global:ApplyFixture.RebootCount-eq0) "Unsafe $scenario was accepted."
        if($scenario-ne'InstallerFailure'){Assert ($global:ApplyFixture.InstallCount-eq0) "Installer started despite $scenario."}
    }
    # Resolve aliases before dispatch; two names may never patch one Windows host concurrently.
    function Invoke-Command {param($Session,$ScriptBlock);[pscustomobject]@{Id='SAME';Name='HOST'}}
    $state=[pscustomobject]@{Servers=@([pscustomobject]@{Server='HOST'},[pscustomobject]@{Server='HOST.DOMAIN'})}
    $rejected=$false;try{Resolve-ExecutionHosts $state}catch{$rejected=$true}
    Assert $rejected 'Two aliases of one host were accepted.'
    Write-Output '[PASS] Remote patch/reboot, repeat skip, local manual reboot, identity/AG/unknown-outcome guards, setup failure, duplicate-host rejection (mocked targets).'
}finally{Remove-Variable ApplyFixture -Scope Global -ErrorAction SilentlyContinue}
$global:LASTEXITCODE=0
