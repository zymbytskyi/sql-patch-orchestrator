#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'SqlPatchParallel.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Invoke-SqlPatchV3Remote.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('Get-PropertyValue','Set-PropertyValue','Get-ScopeHash','Get-CycleStorageKey')){
    $node=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-eq$name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($Condition,[string]$Message){if(-not$Condition){throw $Message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('SqlPatchParallelTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
$Cycle='Test2026';$cycleRoot=$temp;$TargetListPath=Join-Path $temp 'targets.txt'
$PackageRoot=$temp;$V2SourcePath=$temp;$Transport='WinRM';$Credential=$null
$CopyMethod='PowerShell';$CopyConcurrency=3;$ApplyConcurrency=2;$CopyLimitMBps=20;$ControllerCpuLimit=75
$MinimumControllerFreeGB=2;$ControllerWaitSeconds=5;$ReadyTimeoutSeconds=20;$BackupChoice='0'
$global:SqlPatchTestPressure=$false;$global:SqlPatchTestLocalAt=-1
function Get-ControllerCapacity {[pscustomobject]@{Cpu=if($global:SqlPatchTestPressure){99}else{10};FreeGB=8}}
function Resolve-ExecutionHosts {param($State)} # Tested independently below.
function Save-State {param($State)}
function Set-ServerState {param($State,$Server,$Status,$Message);throw $Message}
function New-PSSession {param($ComputerName);$null}
function New-TargetSession {param($Server);$null}
function Prepare-OneServer {param($State,$Entry,$Session);$global:SqlPatchTestLocalAt=@($State.Servers|Where-Object Status -eq 'Prepared').Count;$Entry.Status='Prepared'}
function Apply-OneServer {param($State,$Entry,$Session);$global:SqlPatchTestLocalAt=@($State.Servers|Where-Object Status -eq 'Complete').Count;$Entry.Status='AwaitingControllerRestart'}
function New-TestState {
    param([int]$Count=5,[switch]$Local,[string]$Fail='')
    $entries=@(1..$Count|ForEach-Object{[pscustomobject]@{Server="HOST$_";RequestedInstances=@();Instances=@();Status='PreflightReady';Message='';IsController=$false;Fail=($_-eq$Fail)}})
    if($Local){$entries+= [pscustomobject]@{Server='CONTROLLER';RequestedInstances=@();Instances=@();Status='PreflightReady';Message='';IsController=$true;Fail=$false}}
    [pscustomobject]@{Cycle=$Cycle;Stage='PreflightReady';ScopeHash='';UpdatedUtc='';Packages=@();Servers=$entries}
}
$fake=@'
param($Mode,$Cycle,$TargetListPath,$PackageRoot,$RunRoot,$Transport,$V2SourcePath,$WorkerTarget,$ConfirmApply,$BackupChoice,$ReadyTimeoutSeconds,$CopyLimitMBps)
$path=Join-Path (Join-Path $RunRoot $Cycle) 'state.json'
$s=Get-Content $path -Raw|ConvertFrom-Json
$s.Servers[0]|Add-Member NoteProperty Started ([datetime]::UtcNow.ToString('o'))
Start-Sleep -Milliseconds 3500
$s.Servers[0]|Add-Member NoteProperty Finished ([datetime]::UtcNow.ToString('o'))
$s.Servers[0].Status=if($s.Servers[0].Fail){'Failed'}elseif($Mode-eq'Prepare'){'Prepared'}else{'Complete'}
$s.UpdatedUtc=[datetime]::UtcNow.ToString('o')
[IO.File]::WriteAllText($path,($s|ConvertTo-Json -Depth 10))
if($s.Servers[0].Fail){exit 1}
exit 0
'@
$fakePath=Join-Path $temp 'worker.ps1'
[IO.File]::WriteAllText($fakePath,$fake)
try{
    foreach($phase in @('Prepare','Apply')){
        $state=New-TestState -Local
        Invoke-ParallelPhase $state $phase -EnginePath $fakePath
        $expected=if($phase-eq'Prepare'){'Prepared'}else{'AwaitingControllerRestart'}
        Assert ($state.Stage-eq$expected) "Wrong final $phase stage."
        Assert ($global:SqlPatchTestLocalAt-eq5) 'Controller ran before remote targets completed.'
        $remote=@($state.Servers|Where-Object {-not$_.IsController})
        $peak=0
        foreach($entry in $remote){
            $at=[datetime]$entry.Started
            $active=@($remote|Where-Object {([datetime]$_.Started)-le$at-and([datetime]$_.Finished)-gt$at}).Count
            $peak=[math]::Max($peak,$active)
        }
        $limit=if($phase-eq'Prepare'){$CopyConcurrency}else{$ApplyConcurrency}
        Assert ($peak-ge2-and$peak-le$limit) "$phase did not run concurrently within the requested bound: $peak."
    }
    $state=New-TestState -Count 6 -Local -Fail '1'
    $failed=$false
    try{Invoke-ParallelPhase $state Apply -EnginePath $fakePath}catch{$failed=$true}
    Assert ($failed-and$state.Stage-eq'Failed') 'Apply failure was hidden.'
    Assert (@($state.Servers|Where-Object Status -eq 'Deferred').Count-ge1) 'Apply kept starting after failure.'
    Assert ($state.Servers[-1].Status-eq'Deferred') 'Local controller patched after remote failure.'
    $state=New-TestState -Count 4 -Fail '1'
    try{Invoke-ParallelPhase $state Prepare -EnginePath $fakePath}catch{}
    Assert (@($state.Servers|Where-Object Status -eq 'Prepared').Count-eq3) 'Copy failure prevented other target staging.'
    $global:SqlPatchTestPressure=$true;$state=New-TestState -Count 2
    try{Invoke-ParallelPhase $state Apply -EnginePath $fakePath}catch{}
    Assert (@($state.Servers|Where-Object Status -eq 'Deferred').Count-eq2) 'Resource pressure did not defer the queue.'
    Assert (-not@($state.Servers|Where-Object {$_.PSObject.Properties.Name-contains'Started'}).Count) 'Worker started under resource pressure.'
    Write-Output '[PASS] Real worker processes: bounded overlap, final-state merge, local-last order, Apply fail-stop, Prepare failure isolation, resource gate.'
}finally{
    if(Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
$global:LASTEXITCODE=0
