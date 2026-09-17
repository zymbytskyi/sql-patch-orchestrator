#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'SqlPatchParallel.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Invoke-SqlPatchV3Remote.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('Copy-VerifiedToSession','Get-PropertyValue','Set-PropertyValue')){
    $node=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-eq$name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($Condition,$Message){if(-not$Condition){throw $Message}}
function Start-Sleep {param($Seconds,$Milliseconds)}
function Save-State {param($State)}
function Set-ServerState {param($State,$Server,$Status,$Message);$State.Servers[0].Status=$Status}
$global:TransferChunks=0;$global:TransferLostAck=$false
function Invoke-Command {
    param($Session,[object[]]$ArgumentList,[scriptblock]$ScriptBlock)
    if($ScriptBlock.ToString()-match 'Partial-file offset'){
        $global:TransferChunks++
        & $ScriptBlock @ArgumentList
        if($global:TransferLostAck){$global:TransferLostAck=$false;throw 'Simulated lost acknowledgement after remote write'}
    }else{& $ScriptBlock @ArgumentList}
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('SqlPatchTransferTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
    $source=Join-Path $temp 'source.bin';$dest=Join-Path $temp 'target.bin'
    $data=New-Object byte[] (2MB+13);$random=New-Object Random(42);$random.NextBytes($data);[IO.File]::WriteAllBytes($source,$data)
    $CopyLimitMBps=20;$server='TESTHOST';$state=[pscustomobject]@{Servers=@([pscustomobject]@{Status=''})}
    $result=Copy-VerifiedToSession $source $dest $null
    Assert ($result-eq'Copied'-and$global:TransferChunks-eq3) 'Chunk boundaries or final short chunk failed.'
    Assert ((Get-FileHash $source).Hash-eq(Get-FileHash $dest).Hash) 'Copied bytes differ.'
    $global:TransferChunks=0
    Assert ((Copy-VerifiedToSession $source $dest $null)-eq'AlreadyPresent') 'Existing file was not reused.'
    Assert ($global:TransferChunks-eq0) 'Existing valid media copied again.'
    Remove-Item -LiteralPath $dest
    $prefix=New-Object byte[] 1MB;[Array]::Copy($data,$prefix,1MB);[IO.File]::WriteAllBytes(($dest+'.partial'),$prefix)
    Assert ((Copy-VerifiedToSession $source $dest $null)-eq'Resumed') 'Verified partial did not resume.'
    Assert ($global:TransferChunks-eq2) 'Resume retransmitted completed prefix.'
    Remove-Item -LiteralPath $dest
    $prefix[0]=$prefix[0]-bxor255;[IO.File]::WriteAllBytes(($dest+'.partial'),$prefix);$global:TransferChunks=0
    Assert ((Copy-VerifiedToSession $source $dest $null)-eq'Copied') 'Corrupt partial was trusted.'
    Assert ($global:TransferChunks-eq3) 'Corrupt prefix was not replaced.'
    Remove-Item -LiteralPath $dest
    $global:TransferLostAck=$true;$global:TransferChunks=0
    Assert ((Copy-VerifiedToSession $source $dest $null)-eq'Resumed') 'Lost acknowledgement did not resume safely.'
    Assert ($global:TransferChunks-eq3) 'Acknowledgement loss duplicated bytes.'
    Assert ((Get-FileHash $source).Hash-eq(Get-FileHash $dest).Hash) 'Resumed bytes differ.'
    $rejected=$false
    try{Copy-VerifiedToSession $source (Join-Path $temp 'bad.bin') $null ('0'*64)|Out-Null}catch{$rejected=$true}
    Assert ($rejected-and-not(Test-Path (Join-Path $temp 'bad.bin'))) 'Hash failure published invalid final media.'
    $package=[pscustomobject]@{Major=16;Path=$source;Name='source.bin';Hash=(Get-FileHash $source).Hash;Version='16.0.1.0';UpdateName='test';ReleaseDate='test';PackageAgeDays=0;MetadataSource='test'}
    $entry=[pscustomobject]@{Server='LOCAL';Status='';IsController=$true;Instances=@([pscustomobject]@{Major=16;TargetVersion='';PackageName='';DistributionState='';PackageState='';PackageHashVerified=''})}
    $state=[pscustomobject]@{Packages=@($package);Servers=@($entry)};$V2SourcePath=$temp
    function Copy-VerifiedToSession {throw 'Local media must never invoke transfer'}
    Prepare-OneServer $state $entry $null
    Assert ($entry.Status-eq'Prepared'-and$entry.Instances[0].RemotePackagePath-eq$source-and$entry.Instances[0].DistributionState-eq'LocalExisting') 'Local source reuse failed.'
    Write-Output '[PASS] Chunk boundaries, SHA-256, reuse, verified resume, corrupt partial, lost acknowledgement, hash rejection, and local no-copy.'
}finally{
    Remove-Item -LiteralPath $temp -Recurse -Force
    Remove-Variable TransferChunks,TransferLostAck -Scope Global -ErrorAction SilentlyContinue
}
$global:LASTEXITCODE=0
