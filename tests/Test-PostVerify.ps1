#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$engine=Join-Path $root 'Invoke-SqlPatchV3Remote.ps1'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('PostVerifyRecovery-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temp|Out-Null
function Assert($Condition,$Message){if(-not$Condition){throw $Message}}
$global:PostBuild='16.0.1.0'
function New-PSSession {param($ComputerName,$Authentication,$ErrorAction)}
function Invoke-Command {
    param($Session,[object[]]$ArgumentList,[scriptblock]$ScriptBlock)
    if($ScriptBlock.ToString()-match'StoppedAutomaticSqlServices'){
        return [pscustomobject]@{
            LastBootUtc='2026-11-02T12:00:00Z';StoppedAutomaticSqlServices=@();StoppedOtherAutomaticServices=@('edgeupdate');AutomaticSqlServiceCount=4
            PendingReboot=$false;PartialFiles=0;FreeBytes=20GB
            Instances=@([pscustomobject]@{InstanceName='MSSQLSERVER';Version=$global:PostBuild;EngineService='MSSQLSERVER';EngineStatus='Running';Error='';Databases=@([pscustomobject]@{Name='master';State='ONLINE';HasAccess=1})})
        }
    }
    [pscustomobject]@{TimeZone='UTC';UtcOffset='+00:00';ClusterRegistry=$false;ClusterService='Absent';Instances=@(
        [pscustomobject]@{InstanceName='MSSQLSERVER';Version=$global:PostBuild;Edition='Standard Edition';UpdateLevel='CU';IsClustered=0;IsHadrEnabled=0;ReplicaCount=0;IsSysadmin=1;Backups=@()}
    )}
}
try{
    $targets=Join-Path $temp 'targets.txt'
    [IO.File]::WriteAllText($targets,'FIXTUREHOST')
    $common=@{Cycle='Test2026';RunRoot=$temp;TargetListPath=$targets;ApproveScope=$true}
    $null=& $engine -Mode Inventory @common 6>&1
    Assert ($LASTEXITCODE-eq0) 'Inventory fixture failed.'
    $path=Join-Path $temp 'Test2026\state.json'
    $state=Get-Content $path -Raw|ConvertFrom-Json
    $state.Stage='PostVerifying';$state|Add-Member NoteProperty PostVerifyBaseStage 'Failed'
    $state.Servers[0].Instances[0].TargetVersion='16.0.2.0'
    [IO.File]::WriteAllText($path,($state|ConvertTo-Json -Depth 12))
    $output=(& $engine -Mode PostVerify @common 6>&1|Out-String)
    Assert ($LASTEXITCODE-eq1) "Below-target build passed: $output"
    $state=Get-Content $path -Raw|ConvertFrom-Json
    Assert ($state.Stage-eq'PostVerifyFailed'-and$state.PostVerifyBaseStage-eq'Failed') 'Interrupted verification lost its base stage.'
    Assert ($state.Servers[0].Status-eq'PostVerifyFailed'-and$state.Servers[0].Message-match'below target') 'Host hid instance failure.'
    $html=Get-Content (Join-Path $temp 'Test2026\Dashboard.html') -Raw
    Assert ($html-match'below target') 'Dashboard hid failure details.'
    $global:PostBuild='16.0.2.0'
    $null=& $engine -Mode PostVerify @common 6>&1
    Assert ($LASTEXITCODE-eq0) 'Correct target build failed verification.'
    $state=Get-Content $path -Raw|ConvertFrom-Json
    Assert ($state.Stage-eq'PostVerified'-and$state.Servers[0].Status-eq'PostVerified') 'Successful post-patch verification did not converge.'
    Write-Output '[PASS] Actual PostVerify engine: interrupted resume, below-target failure aggregation, dashboard details and successful retry (mocked SQL).'
}finally{
    Remove-Variable PostBuild -Scope Global -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($temp)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)-and(Split-Path $resolved -Leaf)-like'PostVerifyRecovery-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
