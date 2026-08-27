<# .SYNOPSIS Builds a ZIP with a top-level SqlPatchOrchestrator folder. #>
#Requires -Version 5.1
[CmdletBinding()]
param([ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version='3.0.4',[string]$OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($OutputDirectory)){$OutputDirectory=Join-Path $PSScriptRoot 'Release'}
$files=@('Invoke-SqlPatchV3Remote.ps1','Start-SqlPatchV3Menu.ps1','Install-SqlPatchOrchestrator.ps1','Install-FromGitHub.ps1','Install.cmd','targets.txt','README.md','SECURITY.md','LICENSE','VERSION')
foreach($name in $files){if(-not(Test-Path (Join-Path $PSScriptRoot $name) -PathType Leaf)){throw "Missing release file '$name'."}}
if(-not(Test-Path (Join-Path $PSScriptRoot 'SqlPatchV2Local\Invoke-SqlPatchV2Local.ps1') -PathType Leaf)){throw 'Bundled V2 worker is missing.'}
$buildRoot=Join-Path ([IO.Path]::GetTempPath()) ('SqlPatchOrchestrator-'+[guid]::NewGuid().ToString('N'))
$payloadRoot=Join-Path $buildRoot 'SqlPatchOrchestrator'
try{
    New-Item -ItemType Directory -Path $payloadRoot -Force|Out-Null
    foreach($name in $files){Copy-Item (Join-Path $PSScriptRoot $name) (Join-Path $payloadRoot $name)}
    Copy-Item (Join-Path $PSScriptRoot 'SqlPatchV2Local') $payloadRoot -Recurse
    New-Item -ItemType Directory -Path (Join-Path $payloadRoot 'Packages'),(Join-Path $payloadRoot 'Runs') -Force|Out-Null
    New-Item -ItemType File -Path (Join-Path $payloadRoot 'Packages\.gitkeep'),(Join-Path $payloadRoot 'Runs\.gitkeep') -Force|Out-Null
    $manifestNames=@($files+@('SqlPatchV2Local\Invoke-SqlPatchV2Local.ps1','SqlPatchV2Local\README.md'))
    $manifestLines=foreach($name in $manifestNames){'{0} *{1}'-f(Get-FileHash (Join-Path $payloadRoot $name) -Algorithm SHA256).Hash,$name}
    [IO.File]::WriteAllLines((Join-Path $payloadRoot 'manifest.sha256'),$manifestLines,(New-Object Text.UTF8Encoding($false)))
    New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null
    $zipPath=Join-Path $OutputDirectory "SqlPatchOrchestrator-v$Version.zip"
    if(Test-Path $zipPath){Remove-Item -LiteralPath $zipPath -Force}
    Compress-Archive -LiteralPath $payloadRoot -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Output $zipPath
}finally{if(Test-Path $buildRoot){Remove-Item -LiteralPath $buildRoot -Recurse -Force}}
