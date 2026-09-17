#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('SqlPatchMenu-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
Copy-Item (Join-Path $root 'Start-SqlPatchV3Menu.ps1') $temp
Copy-Item (Join-Path $root 'VERSION') $temp
$fixture=@'
param($Mode,$Cycle,$PackageRoot,$RunRoot,$Transport,$CopyMethod,$CopyConcurrency,$ApplyConcurrency,$CopyLimitMBps,[switch]$DownloadLatest,[switch]$ConfirmBackup,[switch]$ConfirmApply,$BackupChoice)
$global:MenuCalls.Add("${Mode}|${CopyMethod}|${DownloadLatest}|${BackupChoice}")
$folder=Join-Path $RunRoot $Cycle
New-Item -ItemType Directory -Path $folder -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $folder 'state.json'),'{"Stage":"InventoryReady","Servers":[]}')
[IO.File]::WriteAllText((Join-Path $folder 'Dashboard.html'),'<html>Fixture</html>')
$global:LASTEXITCODE=0
'@
[IO.File]::WriteAllText((Join-Path $temp 'Invoke-SqlPatchV3Remote.ps1'),$fixture)
$global:MenuCalls=New-Object 'Collections.Generic.List[string]'
$global:MenuAnswers=New-Object Collections.Queue
foreach($answer in @('1','','2','1','','3','2','1','','4','','5','5','0','','6','','7','','8','Another2026','','0')){$global:MenuAnswers.Enqueue($answer)}
function global:Read-Host {param($Prompt);if(-not$global:MenuAnswers.Count){throw "Unexpected prompt $Prompt"};$global:MenuAnswers.Dequeue()}
function global:Clear-Host {}
function global:Start-Process {param($FilePath,$ArgumentList);$global:MenuCalls.Add("Open|$FilePath")}
try{
    & (Join-Path $temp 'Start-SqlPatchV3Menu.ps1') -Cycle Test2026 -RunRoot (Join-Path $temp 'Runs') 6>$null
    foreach($mode in @('Inventory','Backup','Prepare','Preflight','Apply','PostVerify','Dashboard')){if(-not@($global:MenuCalls|Where-Object{$_-like "$mode|*"}).Count){throw "Menu did not invoke $mode"}}
    if($global:MenuCalls-notcontains'Backup|SMB|False|1'){throw 'System-only backup choice was not passed'}
    if($global:MenuCalls-notcontains'Prepare|SMB|True|'){throw 'Automatic download/SMB choice was not passed'}
    if($global:MenuAnswers.Count){throw 'Menu did not consume all expected choices/pauses'}
    Write-Output '[PASS] All menu routes 0-8, system backup, automatic download, SMB selection, Apply confirmation, cycle switch, and pauses (fixture engine).'
}finally{
    foreach($name in @('Read-Host','Clear-Host','Start-Process')){Remove-Item "Function:\global:$name" -ErrorAction SilentlyContinue}
    Remove-Variable MenuCalls,MenuAnswers -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force
}
exit 0
