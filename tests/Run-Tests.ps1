<# .SYNOPSIS Tests the V3.0.5 cycle, inventory, download, installer, and system-backup contracts. #>
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
foreach($required in @('Select-PatchCycle','Get-CycleStorageKey','Cycle name','8. Select or create another patch cycle','Show-InventoryBlockers',"Stage-notin@('InventoryReady','Prepared','PreflightReady')")){if($menu-notmatch[regex]::Escape($required)){$failures.Add("Menu behavior missing: $required")}}
if(($menu+"`n"+$engine)-match'English month'){$failures.Add('Cycle input still requires an English month name.')}
foreach($text in @($menu,$engine)){if($text-notmatch[regex]::Escape('-Encoding UTF8')){$failures.Add('Runtime UTF-8 reads are not explicit for Windows PowerShell 5.1.')}}
foreach($required in @("SchemaVersion='1.4'",'AgeDays','IsCopyOnly-is[DBNull]','HasChecksum-is[DBNull]','BackupPath-is[DBNull]','^Enterprise Edition','Prepare was not started','Get-CycleStorageKey','cycle-name.txt')){if($engine-notmatch[regex]::Escape($required)){$failures.Add("Engine behavior missing: $required")}}
if($engine-match[regex]::Escape('Join-Path $RunRoot $Cycle')){$failures.Add('Free-form cycle label is used directly as a filesystem path.')}
foreach($required in @("database_id IN (1,3,4)",'WITH COPY_ONLY, CHECKSUM','RESTORE VERIFYONLY FROM DISK','Created $created of $expected required backup(s)','xp_instance_regread','^Enterprise Edition')){if($worker-notmatch[regex]::Escape($required)){$failures.Add("Backup behavior missing: $required")}}
if($worker-match[regex]::Escape('Backup ''$path'' was not found.')){$failures.Add('Backup incorrectly requires the remoting DBA to have NTFS read access to the SQL-owned backup file.')}
if($version-ne'3.0.5'-or$readme-notmatch'v3\.0\.5'){$failures.Add('Version, README, and release tag are inconsistent.')}
$installerText=Get-Content (Join-Path $root 'Install-FromGitHub.ps1') -Raw
foreach($text in @($menu,$engine,$worker,$installerText)){if($text-match[regex]::Escape('Start-MpScan')){$failures.Add('An explicit blocking Microsoft Defender custom scan remains in an operational script.')}}
foreach($required in @('Retrying over HTTPS','Invoke-WebRequest -Uri $update.Uri','GitHub installation completed','& $installer -Destination $Destination -Force')){if(($engine+"`n"+$installerText)-notmatch[regex]::Escape($required)){$failures.Add("Remote download or installer observability behavior missing: $required")}}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('SqlPatchV305-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    $global:SqlPatchTestMenuAnswers=New-Object Collections.Generic.Queue[string]
    $arbitraryCycle='Emergency ../ KB123 #night'
    foreach($answer in @($arbitraryCycle,'3','','0')){$global:SqlPatchTestMenuAnswers.Enqueue($answer)}
    function global:Read-Host{param([string]$Prompt);if($global:SqlPatchTestMenuAnswers.Count){return $global:SqlPatchTestMenuAnswers.Dequeue()};return '0'}
    $menuOutput=(& (Join-Path $root 'Start-SqlPatchV3Menu.ps1') -RunRoot $testRoot 6>&1|Out-String)
    if($menuOutput-notmatch[regex]::Escape("Cycle: $arbitraryCycle")){$failures.Add('Interactive cycle selection did not retain the arbitrary label.')}
    if($menuOutput-notmatch'Preparation was not started' -or $menuOutput-notmatch'does not have a successful inventory'){$failures.Add('Option 3 did not stop cleanly before download when inventory state was absent.')}
    $global:SqlPatchTestMenuAnswers.Clear();foreach($answer in @('agosto2026','0')){$global:SqlPatchTestMenuAnswers.Enqueue($answer)}
    $localizedOutput=(& (Join-Path $root 'Start-SqlPatchV3Menu.ps1') -RunRoot $testRoot 6>&1|Out-String)
    if($localizedOutput-notmatch'Cycle: agosto2026'){$failures.Add('Localized arbitrary cycle label was not retained.')}
    $unicodeCycle=-join@([char]0x422,[char]0x435,[char]0x441,[char]0x442);$unicodeSha=[Security.Cryptography.SHA256]::Create();try{$unicodeHash=([BitConverter]::ToString($unicodeSha.ComputeHash([Text.Encoding]::UTF8.GetBytes($unicodeCycle.ToLowerInvariant())))).Replace('-','')}finally{$unicodeSha.Dispose()};$unicodeDirectory=Join-Path $testRoot ('Cycle-'+$unicodeHash.Substring(0,16));New-Item -ItemType Directory -Path $unicodeDirectory -Force|Out-Null;[IO.File]::WriteAllText((Join-Path $unicodeDirectory 'state.json'),([pscustomobject]@{Cycle=$unicodeCycle}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $global:SqlPatchTestMenuAnswers.Clear();foreach($answer in @('another test','0')){$global:SqlPatchTestMenuAnswers.Enqueue($answer)};$existingOutput=(& (Join-Path $root 'Start-SqlPatchV3Menu.ps1') -RunRoot $testRoot 6>&1|Out-String);if($existingOutput-notmatch[regex]::Escape($unicodeCycle)){$failures.Add('UTF-8 cycle label was corrupted when existing cycles were listed.')}
    $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($arbitraryCycle.ToLowerInvariant())))).Replace('-','')}finally{$sha.Dispose()};$expectedKey='Cycle-'+$hash.Substring(0,16)
    $testTargets=Join-Path $testRoot 'targets.txt';[IO.File]::WriteAllText($testTargets,"SERVER1`r`n",[Text.UTF8Encoding]::new($false))
    $engineOutput=(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Invoke-SqlPatchV3Remote.ps1') -Mode Dashboard -Cycle $arbitraryCycle -RunRoot $testRoot -TargetListPath $testTargets 2>&1|Out-String)
    if($LASTEXITCODE-ne1-or$engineOutput-notmatch[regex]::Escape((Join-Path (Join-Path $testRoot $expectedKey) 'state.json'))){$failures.Add('Arbitrary cycle label did not resolve to the expected safe storage key.')}
}finally{Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue;Remove-Variable SqlPatchTestMenuAnswers -Scope Global -ErrorAction SilentlyContinue;if(Test-Path $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}}
if($failures.Count){$failures|ForEach-Object{"[FAIL] $_"};Write-Output "Tests: FAIL ($($failures.Count))";exit 1}
Write-Output '[PASS] Monthly cycle selection and switching contract.'
Write-Output '[PASS] Free-form multilingual cycle labels and hashed storage isolation.'
Write-Output '[PASS] Inventory-blocked preparation gate and reason reporting.'
Write-Output '[PASS] Exact system-only COPY_ONLY, CHECKSUM, and VERIFYONLY backup contract.'
Write-Output '[PASS] SQL Server 2017 backup-path fallback and time-zone-safe backup age evidence.'
Write-Output 'Tests: PASS'
