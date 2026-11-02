#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$engine=Join-Path $root 'Invoke-SqlPatchV3Remote.ps1'
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($engine,[ref]$t,[ref]$e)
. ([scriptblock]::Create($ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-eq'Write-AtomicStateFile'},$true).Extent.Text))
function Assert($Condition,$Message){if(-not$Condition){throw $Message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('StateRecovery-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temp|Out-Null
$destination=Join-Path $temp 'state.json';$source=Join-Path $temp 'state.tmp'
$reader=$null;$ps=$null
try{
    [IO.File]::WriteAllText($destination,'old')
    [IO.File]::WriteAllText($source,'new')
    $reader=[IO.File]::Open($destination,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $ps=[powershell]::Create()
    [void]$ps.AddScript('param($handle) Start-Sleep -Milliseconds 750; $handle.Dispose()').AddArgument($reader)
    $async=$ps.BeginInvoke()
    Write-AtomicStateFile $source $destination
    $ps.EndInvoke($async);$ps.Dispose();$ps=$null;$reader=$null
    Assert ([IO.File]::ReadAllText($destination)-eq'new') 'Transient lock did not recover.'
    [IO.File]::WriteAllText($source,'next')
    $reader=[IO.File]::Open($destination,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $blocked=$false
    try{Write-AtomicStateFile $source $destination}catch{$blocked=$true}
    $reader.Dispose();$reader=$null
    Assert ($blocked-and[IO.File]::ReadAllText($destination)-eq'new'-and(Test-Path $source)) 'Persistent lock corrupted state or was ignored.'
    Write-Output '[PASS] Real Windows sharing violation: transient recovery and persistent-lock atomic preservation.'
}finally{
    if($reader){$reader.Dispose()};if($ps){$ps.Dispose()}
    $resolved=[IO.Path]::GetFullPath($temp)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)-and(Split-Path $resolved -Leaf)-like'StateRecovery-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
