#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'SqlPatchParallel.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Invoke-SqlPatchV3Remote.ps1'),[ref]$tokens,[ref]$errors)
$node=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-eq'New-TargetSession'},$true)
. ([scriptblock]::Create($node.Extent.Text))
function Assert($Condition,$Message){if(-not$Condition){throw $Message}}
$Transport='WinRM';$UseSSL=$false;$Credential=$null
$script:calls=0;$script:removed=0;$script:trusted=0;$script:elevated=$true
function Test-LocalAdministrator {$script:elevated}
function New-PSSession {
    [CmdletBinding()]param($ComputerName,$VMName,$Authentication,$Credential,[switch]$UseSSL)
    $script:calls++
    [pscustomobject]@{ComputerName=$ComputerName;VMName=$VMName;Authentication=$Authentication;Credential=$Credential;UseSSL=[bool]$UseSSL}
}
function Remove-PSSession {param($Session);$script:removed++}
function Add-TargetTrustedHost {param($Server);$script:trusted++}
function Invoke-Command {throw 'Local execution must never call Invoke-Command.'}
foreach($name in @('.', 'localhost', '127.0.0.1','::1',$env:COMPUTERNAME)){
    Assert (Test-LocalTarget $name) "Local name missed: $name"
    $session=New-TargetSession $name
    Assert ($session-eq'SqlPatch.Local') 'Local session not selected.'
    $result=Invoke-TargetCommand $session -ArgumentList 'hello',(@('a','b')) -ScriptBlock {param($Text,$Names);$Text+':'+($Names-join',')}
    Assert ($result-eq'hello:a,b') 'Local argument array was flattened.'
    Remove-TargetSession $session
}
Assert ($script:calls-eq0-and$script:removed-eq0-and$script:trusted-eq0) 'Local path touched remoting.'
Assert (-not(Test-LocalTarget '')) 'Empty target accepted.'
Assert (-not(Test-LocalTarget ($env:COMPUTERNAME+'.other.invalid'))) 'Foreign FQDN treated as local.'
$script:elevated=$false;$failed=$false
try{$null=New-TargetSession 'localhost'}catch{$failed=$_.Exception.Message-match'Run as Administrator'}
Assert $failed 'Non-elevated local execution was allowed.'
$secret=ConvertTo-SecureString 'test-only-placeholder' -AsPlainText -Force
$Credential=New-Object Management.Automation.PSCredential ('REMOTE01\localadmin',$secret)
$UseSSL=$true
$remote=New-TargetSession 'REMOTE01'
Assert ($remote.Credential-eq$Credential-and$remote.UseSSL-and$remote.Authentication-eq'Negotiate') 'Workgroup HTTPS credentials lost.'
Remove-TargetSession $remote
Assert ($script:removed-eq1) 'Remote session not cleaned up.'
$Credential=New-Object Management.Automation.PSCredential ('.\localadmin',$secret)
$UseSSL=$false
$remote=New-TargetSession 'REMOTE01.example.test'
Assert ($remote.Credential.UserName-eq'REMOTE01\localadmin'-and-not$remote.UseSSL) 'Target-local credential qualification failed.'
$failed=$false
try{$null=New-TargetSession '192.0.2.10'}catch{$failed=$_.Exception.Message-match'explicit TARGET'}
Assert $failed 'IP address produced an invalid local-account authority.'
$Transport='PowerShellDirect'
$direct=New-TargetSession 'localhost'
Assert ($direct.VMName-eq'localhost') 'PowerShell Direct incorrectly bypassed VM transport.'
$Transport='WinRM';$script:calls=0
function New-PSSession {[CmdletBinding()]param($ComputerName,$Authentication,$Credential,[switch]$UseSSL);$script:calls++;throw 'Access is denied.'}
$failed=$false
try{$null=New-TargetSession 'REMOTE01'}catch{$failed=$_.Exception.Message-match'LocalAccountTokenFilterPolicy'}
Assert ($failed-and$script:calls-eq1-and$script:trusted-eq0) 'Access denial lacks UAC guidance or changed trust.'
Write-Output '[PASS] Local dispatch and elevation; argument arrays; no self-remoting; workgroup HTTP/HTTPS credentials; PowerShell Direct; UAC diagnostics.'
$script:calls=0;$script:trusted=0;$UseSSL=$false
function New-PSSession {
    [CmdletBinding()]param($ComputerName,$Authentication,$Credential,[switch]$UseSSL)
    $script:calls++
    Assert ($Credential.UserName-eq'REMOTE01\localadmin') 'Retry lost credentials.'
    if($script:calls-eq1){throw 'The destination must be added to TrustedHosts.'}
    'remote-session'
}
Assert ((New-TargetSession 'REMOTE01')-eq'remote-session') 'HTTP trust retry failed.'
Assert ($script:calls-eq2-and$script:trusted-eq1) 'HTTP trust retry was not bounded.'
$script:calls=0;$script:trusted=0;$UseSSL=$true;$failed=$false
try{$null=New-TargetSession 'REMOTE01'}catch{$failed=$true}
Assert ($failed-and$script:calls-eq1-and$script:trusted-eq0) 'HTTPS failure modified TrustedHosts or retried.'
function Invoke-Command {
    [CmdletBinding()]param($Session,$ScriptBlock,[object[]]$ArgumentList)
    Assert ($Session-eq'remote-session') 'Remote session lost.'
    & $ScriptBlock @ArgumentList
}
Assert ((Invoke-TargetCommand 'remote-session' -ArgumentList 'remote' -ScriptBlock {param($Value);$Value})-eq'remote') 'Remote dispatch failed.'
$properties=[Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
$fqdn=if($properties.DomainName){$properties.HostName+'.'+$properties.DomainName}else{$properties.HostName}
Assert (Test-LocalTarget ($fqdn.ToUpperInvariant()+'.')) 'Configured FQDN not recognized.'
Write-Output '[PASS] Credential-preserving HTTP retry; no HTTPS trust mutation; remote command delegation; configured FQDN.'