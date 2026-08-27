<# .SYNOPSIS Tests the V3.0.3 cycle, inventory, download, installer, and system-backup contracts. #>
#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$failures=New-Object Collections.Generic.List[string]
$menu=Get-Content (Join-Path $root 'Start-SqlPatchV3Menu.ps1') -Raw
$engine=Get-Content (Join-Path $root 'Invoke-SqlPatchV3Remote.ps1') -Raw
$worker=Get-Content (Join-Path $root 'SqlPatchV2Local\Invoke-SqlPatchV2Local.ps1') -Raw
$readme=Get-Content (Join-Path $root 'README.md') -Raw
$version=(Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
foreach($required in @('Select-PatchCycle','Patch cycle must use an English month and year','8. Select or create another patch cycle','Show-InventoryBlockers',"Stage-notin@('InventoryReady','Prepared','PreflightReady')")){if($menu-notmatch[regex]::Escape($required)){$failures.Add("Menu behavior missing: $required")}}
foreach($required in @("SchemaVersion='1.4'",'AgeDays','IsCopyOnly-is[DBNull]','HasChecksum-is[DBNull]','BackupPath-is[DBNull]','^Enterprise Edition','Prepare was not started')){if($engine-notmatch[regex]::Escape($required)){$failures.Add("Engine behavior missing: $required")}}
foreach($required in @("database_id IN (1,3,4)",'WITH COPY_ONLY, CHECKSUM','RESTORE VERIFYONLY FROM DISK','Created $created of $expected required backup(s)','xp_instance_regread','^Enterprise Edition')){if($worker-notmatch[regex]::Escape($required)){$failures.Add("Backup behavior missing: $required")}}
if($worker-match[regex]::Escape('Backup ''$path'' was not found.')){$failures.Add('Backup incorrectly requires the remoting DBA to have NTFS read access to the SQL-owned backup file.')}
if($version-ne'3.0.3'-or$readme-notmatch'v3\.0\.3'){$failures.Add('Version, README, and release tag are inconsistent.')}
$installerText=Get-Content (Join-Path $root 'Install-FromGitHub.ps1') -Raw
foreach($text in @($menu,$engine,$worker,$installerText)){if($text-match[regex]::Escape('Start-MpScan')){$failures.Add('An explicit blocking Microsoft Defender custom scan remains in an operational script.')}}
foreach($required in @('Retrying over HTTPS','Invoke-WebRequest -Uri $update.Uri','GitHub installation completed','& $installer -Destination $Destination -Force')){if(($engine+"`n"+$installerText)-notmatch[regex]::Escape($required)){$failures.Add("Remote download or installer observability behavior missing: $required")}}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('SqlPatchV303-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    $global:SqlPatchTestMenuAnswers=New-Object Collections.Generic.Queue[string]
    foreach($answer in @('September2026','3','','0')){$global:SqlPatchTestMenuAnswers.Enqueue($answer)}
    function global:Read-Host{param([string]$Prompt);if($global:SqlPatchTestMenuAnswers.Count){return $global:SqlPatchTestMenuAnswers.Dequeue()};return '0'}
    $menuOutput=(& (Join-Path $root 'Start-SqlPatchV3Menu.ps1') -RunRoot $testRoot 6>&1|Out-String)
    if($menuOutput-notmatch'Cycle: September2026'){$failures.Add('Interactive cycle selection did not activate September2026.')}
    if($menuOutput-notmatch'Preparation was not started' -or $menuOutput-notmatch'does not have a successful inventory'){$failures.Add('Option 3 did not stop cleanly before download when inventory state was absent.')}
    try{& (Join-Path $root 'Invoke-SqlPatchV3Remote.ps1') -Mode Dashboard -Cycle '..\bad' 2>$null;$failures.Add('Unsafe cycle path was accepted.')}catch{if($_.Exception.Message-notmatch'Patch cycle must use an English month and year'){$failures.Add('Unsafe cycle path returned the wrong validation message.')}}
}finally{Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue;Remove-Variable SqlPatchTestMenuAnswers -Scope Global -ErrorAction SilentlyContinue;if(Test-Path $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}}
if($failures.Count){$failures|ForEach-Object{"[FAIL] $_"};Write-Output "Tests: FAIL ($($failures.Count))";exit 1}
Write-Output '[PASS] Monthly cycle selection and switching contract.'
Write-Output '[PASS] Inventory-blocked preparation gate and reason reporting.'
Write-Output '[PASS] Exact system-only COPY_ONLY, CHECKSUM, and VERIFYONLY backup contract.'
Write-Output '[PASS] SQL Server 2017 backup-path fallback and time-zone-safe backup age evidence.'
Write-Output 'Tests: PASS'
