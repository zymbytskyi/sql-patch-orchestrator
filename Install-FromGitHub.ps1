<# .SYNOPSIS Securely downloads and installs SQL Patch Orchestrator V3 from GitHub Releases. #>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param([ValidatePattern('^(latest|\d+\.\d+\.\d+)$')][string]$Version='latest',[string]$Destination='C:\SqlPatchOrchestrator',[switch]$Force)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$repository='zymbytskyi/sql-patch-orchestrator'
$apiRoot="https://api.github.com/repos/$repository"
$releaseUri=if($Version-eq'latest'){"$apiRoot/releases/latest"}else{"$apiRoot/releases/tags/v$Version"}
$headers=@{Accept='application/vnd.github+json';'User-Agent'='SqlPatchOrchestrator-Installer'}
$temporaryRoot=Join-Path ([IO.Path]::GetTempPath()) ('SqlPatchOrchestrator-'+[guid]::NewGuid().ToString('N'))
try{
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $release=Invoke-RestMethod -Uri $releaseUri -Headers $headers -UseBasicParsing
    if($release.draft-or$release.prerelease){throw 'Draft and prerelease packages are not accepted.'}
    $assets=@($release.assets|Where-Object{$_.name-match'^SqlPatchOrchestrator-v\d+\.\d+\.\d+\.zip$'})
    if($assets.Count-ne1){throw "Expected exactly one release ZIP; found $($assets.Count)."}
    $asset=$assets[0]
    if($Version-ne'latest'-and$asset.name-ne"SqlPatchOrchestrator-v$Version.zip"){throw "Release asset '$($asset.name)' does not match requested version $Version."}
    if([int64]$asset.size-le0){throw 'Release asset is empty.'}
    $digest=[string]$asset.digest
    if($digest-notmatch'^sha256:([A-Fa-f0-9]{64})$'){throw 'GitHub did not provide a valid SHA-256 digest for the release asset.'}
    $expectedHash=$matches[1].ToUpperInvariant()
    New-Item -ItemType Directory -Path $temporaryRoot -Force|Out-Null
    $zipPath=Join-Path $temporaryRoot $asset.name
    Write-Host "Downloading $($asset.name)..."
    Invoke-WebRequest -Uri ([string]$asset.browser_download_url) -Headers $headers -UseBasicParsing -OutFile $zipPath
    $actualHash=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    if($actualHash-ne$expectedHash){throw "Release ZIP SHA-256 mismatch. Expected $expectedHash; received $actualHash."}
    Write-Host "SHA-256 verified: $actualHash" -ForegroundColor Green
    $extractRoot=Join-Path $temporaryRoot 'Extracted';Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot
    $installer=Join-Path $extractRoot 'SqlPatchOrchestrator\Install-SqlPatchOrchestrator.ps1'
    if(-not(Test-Path $installer -PathType Leaf)){throw 'The packaged installer is missing.'}
    $parameters=@{Destination=$Destination};if($Force){$parameters.Force=$true};& $installer @parameters
}finally{if(Test-Path $temporaryRoot){Remove-Item -LiteralPath $temporaryRoot -Recurse -Force}}
