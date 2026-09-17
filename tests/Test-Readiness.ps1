#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
Import-Module Microsoft.PowerShell.Utility
$root=Split-Path $PSScriptRoot -Parent
$engine=Join-Path $root 'Invoke-SqlPatchV3Remote.ps1'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('SqlPatchReadiness-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
function Assert($Value,$Message){if(-not$Value){throw $Message}}
$global:ReadinessHost='';$global:ReadinessDeny=$false;$global:ReadinessCorrupt=$false
$global:ReadinessHash=(Get-FileHash (Join-Path $root 'README.md')).Hash
$global:ReadinessWorkers=@{}
Get-ChildItem (Join-Path $root 'SqlPatchV2Local') -File|ForEach-Object{$global:ReadinessWorkers[$_.Name]=(Get-FileHash $_.FullName).Hash}
function New-PSSession {
    param($ComputerName,$Authentication,$ErrorAction)
    $global:ReadinessHost=$ComputerName
    if($global:ReadinessDeny-and$ComputerName-eq'HOST01'){throw 'Access is denied.'}
}
function Invoke-Command {
    param($Session,[object[]]$ArgumentList,[scriptblock]$ScriptBlock)
    $text=$ScriptBlock.ToString()
    if($text-match 'Get-AuthenticodeSignature'){
        return [pscustomobject]@{Hash=if($global:ReadinessCorrupt-and$global:ReadinessHost-eq'HOST02'){'WRONG'}else{$global:ReadinessHash};Signature='Valid';Signer='Microsoft Corporation'}
    }
    if($text-match 'FreeBytes='){return [pscustomobject]@{FreeBytes=20GB;PendingReboot=$false;PartialFiles=0}}
    if($text-match 'Get-FileHash'){return $global:ReadinessWorkers[[IO.Path]::GetFileName($ArgumentList[0])]}
    [pscustomobject]@{TimeZone='UTC';UtcOffset='+00:00';ClusterRegistry=$false;ClusterService='Absent';Instances=@(
        [pscustomobject]@{InstanceName='MSSQLSERVER';Version='16.0.1.0';Edition='Standard Edition';UpdateLevel='CU';IsClustered=0;IsHadrEnabled=0;ReplicaCount=0;IsSysadmin=1;Backups=@()}
    )}
}
try{
    $targets=Join-Path $temp 'targets.txt';[IO.File]::WriteAllText($targets,"HOST01`r`nHOST02`r`n")
    $common=@{Cycle='Test2026';RunRoot=$temp;TargetListPath=$targets;ApproveScope=$true}
    $null=& $engine -Mode Inventory @common 6>&1
    Assert ($LASTEXITCODE-eq0) 'Fixture inventory failed.'
    $output=(& $engine -Mode Preflight @common 6>&1|Out-String)
    Assert ($LASTEXITCODE-eq1-and$output-match'HOST01: NOT READY'-and$output-match'HOST02: NOT READY') 'InventoryReady did not yield a per-host summary.'
    Assert ($output-notmatch'FAILED:|SQL PATCH V3 \|') 'Preflight printed a general exception or verbose inventory.'
    $path=Join-Path $temp 'Test2026\state.json'
    $state=Get-Content $path -Raw|ConvertFrom-Json
    Assert ($state.Stage-eq'InventoryReady') 'Early readiness prevented subsequent preparation.'
    $state.Stage='InventoryReady';$state.Packages=@([pscustomobject]@{Major=16;Path=(Join-Path $root 'README.md');Name='test.exe';Hash=$global:ReadinessHash})
    foreach($entry in $state.Servers){
        $item=$entry.Instances[0];$item.TargetVersion='16.0.2.0';$item.PackageName='test.exe'
        $item|Add-Member NoteProperty CopyMethod 'SMB'
    }
    [IO.File]::WriteAllText($path,($state|ConvertTo-Json -Depth 12))
    $global:ReadinessDeny=$true
    $output=(& $engine -Mode Preflight @common 6>&1|Out-String)
    Assert ($LASTEXITCODE-eq1-and$output-match'HOST01: NOT READY'-and$output-match'HOST02: READY') 'First failure stopped later hosts.'
    $global:ReadinessDeny=$false
    $output=(& $engine -Mode Preflight @common 6>&1|Out-String)
    Assert ($LASTEXITCODE-eq0-and$output-match'HOST01: READY'-and$output-match'HOST02: READY') 'Blocked preflight could not be retried.'
    $html=Get-Content (Join-Path $temp 'Test2026\Dashboard.html') -Raw
    Assert ($html-match'Folder: C:\\SqlPatchV3Remote\\Packages'-and$html-match'File: C:\\SqlPatchV3Remote\\Packages\\test.exe'-and$html-match'Transport: SMB') 'Dashboard destination or transport missing.'
    Assert ($html-match'<td class="ok"><b>copy:') 'Verified media was not green.'
    $global:ReadinessCorrupt=$true
    $null=& $engine -Mode Preflight @common 6>&1
    Assert ($LASTEXITCODE-eq1) 'Corrupt remote package passed preflight.'
    $html=Get-Content (Join-Path $temp 'Test2026\Dashboard.html') -Raw
    $row=[regex]::Match($html,'<tr><td><b>HOST02[\s\S]*?</tr>').Value
    Assert ($row-match'<td class="warn"><b>copy:') 'Corrupt/unverified media remained green.'
    Write-Output '[PASS] Early readiness, per-host failure isolation, retry, concise console, destination paths, green only after hash verification.'
}finally{
    Remove-Variable ReadinessHost,ReadinessDeny,ReadinessCorrupt,ReadinessHash,ReadinessWorkers -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force
}
$global:LASTEXITCODE=0
