<# .SYNOPSIS Installs SQL Patch Orchestrator V3 into C:\SqlPatchOrchestrator. #>
#Requires -Version 5.1
[CmdletBinding()]
param([string]$Destination='C:\SqlPatchOrchestrator',[switch]$Force,[switch]$NoDesktopShortcut,[string]$DesktopDirectory)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$sourceRoot=$PSScriptRoot
$payloadRoot=if(Test-Path (Join-Path $sourceRoot 'SqlPatchOrchestrator') -PathType Container){Join-Path $sourceRoot 'SqlPatchOrchestrator'}else{$sourceRoot}
$required=@('Invoke-SqlPatchV3Remote.ps1','SqlPatchParallel.ps1','Start-SqlPatchV3Menu.ps1','SqlPatchV2Local\Invoke-SqlPatchV2Local.ps1','SqlPatchV2Local\SqlPatchUpdates.ps1','README.md','OFFLINE-INSTALL.md','Start-SqlPatch.ps1','Start-SqlPatch.cmd','LICENSE')
foreach($name in $required){if(-not(Test-Path (Join-Path $payloadRoot $name) -PathType Leaf)){throw "Package file '$name' is missing."}}
$manifest=Join-Path $payloadRoot 'manifest.sha256'
if(Test-Path $manifest -PathType Leaf){
    foreach($line in Get-Content $manifest){
        if($line -notmatch '^([A-Fa-f0-9]{64})\s+\*(.+)$'){throw "Invalid manifest line '$line'."}
        $path=Join-Path $payloadRoot $matches[2]
        if(-not(Test-Path $path -PathType Leaf)){throw "Manifest file '$($matches[2])' is missing."}
        if((Get-FileHash $path -Algorithm SHA256).Hash-ne$matches[1].ToUpperInvariant()){throw "SHA-256 mismatch for '$($matches[2])'."}
    }
}
$resolvedPayload=[IO.Path]::GetFullPath($payloadRoot).TrimEnd('\')
$resolvedDestination=[IO.Path]::GetFullPath($Destination).TrimEnd('\')
if($resolvedPayload-ne$resolvedDestination){
    if(Test-Path $Destination){
        if(-not$Force){$answer=Read-Host "'$Destination' already exists. Replace program files and keep targets/packages/runs? [y/N]";if($answer-notmatch'^(?i:y|yes)$'){Write-Host 'Installation cancelled.';exit 0}}
    }else{New-Item -ItemType Directory -Path $Destination -Force|Out-Null}
    foreach($name in @('Invoke-SqlPatchV3Remote.ps1','SqlPatchParallel.ps1','Start-SqlPatchV3Menu.ps1','Install-FromGitHub.ps1','README.md','OFFLINE-INSTALL.md','Start-SqlPatch.ps1','Start-SqlPatch.cmd','SECURITY.md','LICENSE','VERSION')){Copy-Item (Join-Path $payloadRoot $name) (Join-Path $Destination $name) -Force}
    $workerDestination=Join-Path $Destination 'SqlPatchV2Local'
    New-Item -ItemType Directory -Path $workerDestination -Force|Out-Null
    Copy-Item (Join-Path $payloadRoot 'SqlPatchV2Local\*') $workerDestination -Force
    $sourceTargets=Join-Path $payloadRoot 'targets.txt';$destinationTargets=Join-Path $Destination 'targets.txt'
    if(-not(Test-Path $destinationTargets -PathType Leaf)){Copy-Item $sourceTargets $destinationTargets}
}
New-Item -ItemType Directory -Path (Join-Path $Destination 'Packages'),(Join-Path $Destination 'Runs') -Force|Out-Null
if(-not$NoDesktopShortcut){
    try{
        if([string]::IsNullOrWhiteSpace($DesktopDirectory)){$DesktopDirectory=[Environment]::GetFolderPath('CommonDesktopDirectory')}
        if(-not(Test-Path -LiteralPath $DesktopDirectory -PathType Container)){throw "Desktop directory does not exist: $DesktopDirectory"}
        $shell=New-Object -ComObject WScript.Shell
        $shortcut=$shell.CreateShortcut((Join-Path $DesktopDirectory 'SQL Patch Orchestrator.lnk'))
        $shortcut.TargetPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $shortcut.Arguments='-NoExit -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $resolvedDestination 'Start-SqlPatch.ps1')+'"'
        $shortcut.WorkingDirectory=$resolvedDestination
        $shortcut.Description='SQL Patch Orchestrator - elevated standalone maintenance menu'
        $shortcut.Save()
        Write-Host "Desktop shortcut created in '$DesktopDirectory'."
    }catch{Write-Warning "Program installed, but desktop shortcut creation failed: $($_.Exception.Message). Run Start-SqlPatch.cmd from the installation folder."}
}
Write-Host "Installed SQL Patch Orchestrator V3 to '$resolvedDestination'." -ForegroundColor Green
Write-Host "Run: cd $resolvedDestination; .\Start-SqlPatchV3Menu.ps1"

