#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Update-FromGitHub.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
foreach($name in @('Get-GitBlobHash','Install-VerifiedProgramFiles')){Invoke-Expression ($ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-eq$name},$true).Extent.Text)}
$test=Join-Path ([IO.Path]::GetTempPath()) ('SqlUpdaterTest-'+[guid]::NewGuid().ToString('N'))
$stage=Join-Path $test 'stage';$dest=Join-Path $test 'installed'
New-Item -ItemType Directory $stage,$dest -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $stage 'program.ps1'),'new')
[IO.File]::WriteAllText((Join-Path $dest 'program.ps1'),'old')
foreach($name in @('targets.txt','Packages/media.exe','Runs/state.json')){$p=Join-Path $dest $name;New-Item -ItemType Directory (Split-Path $p) -Force|Out-Null;[IO.File]::WriteAllText($p,'preserve')}
$hashes=@{'program.ps1'=(Get-GitBlobHash (Join-Path $stage 'program.ps1'))}
$backup=Install-VerifiedProgramFiles $stage $dest @('program.ps1') $hashes
if((Get-Content (Join-Path $backup 'program.ps1'))-ne'old'){throw 'Missing backup'}
foreach($name in @('targets.txt','Packages/media.exe','Runs/state.json')){if((Get-Content (Join-Path $dest $name))-ne'preserve'){throw 'State changed'}}
$hashes['program.ps1']='wrong';$blocked=$false
try{Install-VerifiedProgramFiles $stage $dest @('program.ps1') $hashes}catch{$blocked=$true}
if(-not$blocked){throw 'Bad hash accepted'}
$hashes['program.ps1']=Get-GitBlobHash (Join-Path $stage 'program.ps1')
[IO.File]::WriteAllText((Join-Path $dest 'program.ps1'),'old again')
function Copy-Item {param($LiteralPath,$Destination,[switch]$Force);if($LiteralPath-eq(Join-Path $stage 'program.ps1')){[IO.File]::WriteAllText($Destination,'partial');throw 'Injected copy failure'};Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force}
$blocked=$false
try{Install-VerifiedProgramFiles $stage $dest @('program.ps1') $hashes}catch{$blocked=$true}
if(-not$blocked-or(Get-Content (Join-Path $dest 'program.ps1'))-ne'old again'){throw 'Rollback failed'}
Write-Output '[PASS] Updater syntax, hashes, program backup, state preservation and rollback after partial replacement.'
