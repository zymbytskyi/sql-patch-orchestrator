#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
Import-Module Microsoft.PowerShell.Management
Import-Module Microsoft.PowerShell.Utility
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'SqlPatchParallel.ps1')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('SqlPatchSmbTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
$cycleRoot=$temp;$CopyLimitMBps=20;$state=$null
$global:SmbStarts=0;$global:SmbUnavailable=$false
function Assert($Value,$Message){if(-not$Value){throw $Message}}
function Set-ServerState {param($State,$Server,$Status,$Message)}
function Invoke-Command {param($Session,[object[]]$ArgumentList,[scriptblock]$ScriptBlock);& $ScriptBlock @ArgumentList}
function Test-Path {
    param([Alias('Path')]$LiteralPath,$PathType)
    if($LiteralPath-like '\\TARGET\*'){return (-not$global:SmbUnavailable)}
    if($PathType){Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType}
    else{Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath}
}
function Start-Process {
    param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru)
    $global:SmbStarts++
    Assert ($WindowStyle-eq'Hidden') 'Copy process must not open an interactive window.'
    Assert ($ArgumentList-notmatch '/MIR|/PURGE|/MOV|/COPYALL|/ZB') 'Destructive or privilege-bypass flag found.'
    # Actual Robocopy process against local fixture; only the SMB boundary is substituted.
    $mapped=$ArgumentList.Replace('\\TARGET\C$\','C:\')
    Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath -ArgumentList $mapped -WindowStyle Hidden -PassThru
}
try{
    $sourceRoot=Join-Path $temp 'source with spaces';$targetRoot=Join-Path $temp 'target'
    New-Item -ItemType Directory -Path $sourceRoot,$targetRoot|Out-Null
    $source=Join-Path $sourceRoot 'test package.bin';$destination=Join-Path $targetRoot 'test package.bin'
    $data=New-Object byte[] (5MB+17);(New-Object Random(42)).NextBytes($data)
    [IO.File]::WriteAllBytes($source,$data);$hash=(Get-FileHash $source).Hash
    $result=Copy-VerifiedSmb $source $destination $null $hash TARGET
    Assert ($result-eq'Copied (SMB verified)'-and(Get-FileHash $destination).Hash-eq$hash) 'Actual Robocopy transfer failed.'
    $result=Copy-VerifiedSmb $source $destination $null $hash TARGET
    Assert ($result-eq'AlreadyPresent'-and$global:SmbStarts-eq1) 'Verified package was transferred twice.'
    $failed=$false
    try{Copy-VerifiedSmb $source $destination $null ('1'*64) TARGET|Out-Null}catch{$failed=$_.Exception.Message-match'SHA-256 mismatch'}
    Assert ($failed-and(Get-FileHash $destination).Hash-eq$hash) 'Corrupt candidate replaced final media.'
    $global:SmbUnavailable=$true;$failed=$false;$before=$global:SmbStarts
    try{Copy-VerifiedSmb $source (Join-Path $targetRoot 'missing.bin') $null $hash TARGET|Out-Null}catch{$failed=$_.Exception.Message-match'No automatic slow fallback'}
    Assert ($failed-and$global:SmbStarts-eq$before) 'Unavailable SMB silently fell back or launched copy.'
    Write-Output '[PASS] Actual Robocopy process, quoted paths, safe flags, final SHA-256, reuse, corruption rejection, and unavailable-SMB guard (local transport fixture).'
}catch{
    Write-Host $_.ScriptStackTrace
    throw
}finally{
    Remove-Item -LiteralPath $temp -Recurse -Force
    Remove-Variable SmbStarts,SmbUnavailable -Scope Global -ErrorAction SilentlyContinue
}
$global:LASTEXITCODE=0
