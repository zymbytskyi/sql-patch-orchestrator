#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('OfflineInstall-'+[guid]::NewGuid().ToString('N'))
$dest=Join-Path $testRoot 'Installed with spaces'
$desktop=Join-Path $testRoot 'Desktop'
New-Item -ItemType Directory $desktop -Force|Out-Null
try{
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Install-SqlPatchOrchestrator.ps1') -Destination $dest -DesktopDirectory $desktop
    if($LASTEXITCODE-ne0){throw 'Fresh offline installation failed.'}
    $link=Join-Path $desktop 'SQL Patch Orchestrator.lnk'
    if(-not(Test-Path -LiteralPath $link)){throw 'Desktop shortcut missing.'}
    $shell=New-Object -ComObject WScript.Shell
    $shortcut=$shell.CreateShortcut($link)
    if($shortcut.Arguments-notlike('*-File "'+(Join-Path $dest 'Start-SqlPatch.ps1')+'"')){throw 'Shortcut launcher/quoting mismatch.'}
    if($shortcut.WorkingDirectory-ne$dest){throw 'Shortcut working directory mismatch.'}
    foreach($name in @('Start-SqlPatch.ps1','Start-SqlPatch.cmd','OFFLINE-INSTALL.md')){if(-not(Test-Path (Join-Path $dest $name))){throw "Missing installed file: $name"}}
    foreach($name in @('targets.txt','Packages\fixture.txt','Runs\fixture.txt')){[IO.File]::WriteAllText((Join-Path $dest $name),'preserve')}
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Install-SqlPatchOrchestrator.ps1') -Destination $dest -Force -NoDesktopShortcut
    if($LASTEXITCODE-ne0){throw 'Offline upgrade failed.'}
    foreach($name in @('targets.txt','Packages\fixture.txt','Runs\fixture.txt')){if([IO.File]::ReadAllText((Join-Path $dest $name))-ne'preserve'){throw "Upgrade changed $name"}}
    if((Get-Content (Join-Path $dest 'VERSION')).Trim()-ne'3.1.5'){throw 'Installed version mismatch.'}
    Write-Output '[PASS] Real offline install/upgrade, WScript shortcut, spaces and preserved runtime files.'
}finally{
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)-and(Split-Path $resolved -Leaf)-like'OfflineInstall-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
