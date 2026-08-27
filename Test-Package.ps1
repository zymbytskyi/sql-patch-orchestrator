<# .SYNOPSIS Validates the dependency-free public V3 package. #>
#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$failures=New-Object Collections.Generic.List[string]
$required=@('Invoke-SqlPatchV3Remote.ps1','Start-SqlPatchV3Menu.ps1','SqlPatchV2Local\Invoke-SqlPatchV2Local.ps1','Install-SqlPatchOrchestrator.ps1','Install-FromGitHub.ps1','Install.cmd','Build-Release.ps1','scripts\Test-Repository.ps1','tests\Run-Tests.ps1','targets.txt','README.md','CHANGELOG.md','NEXT-STEPS.md','SECURITY.md','LICENSE','VERSION')
foreach($name in $required){$path=Join-Path $PSScriptRoot $name;if(-not(Test-Path $path -PathType Leaf)){$failures.Add("Missing '$name'.")}}
foreach($name in $required|Where-Object{$_-match'\.ps1$'}){$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors);if($errors.Count){$failures.Add("$name parse errors: $($errors.Message-join'; ')")}}
$engine=Get-Content (Join-Path $PSScriptRoot 'Invoke-SqlPatchV3Remote.ps1') -Raw
foreach($behavior in @('SqlPatchV2Local','Prepare','Preflight','Apply','PostVerify','forced failover','data-loss operations','FCI/Always On/AG detected',"SchemaVersion='1.4'",'Prepare was not started','Get-CycleStorageKey','cycle-name.txt')){if($engine-notmatch[regex]::Escape($behavior)){$failures.Add("Engine behavior '$behavior' is missing.")}}
if($engine-match[regex]::Escape('Join-Path $RunRoot $Cycle')){$failures.Add('Free-form cycle label is used directly as a filesystem path.')}
$online=Get-Content (Join-Path $PSScriptRoot 'Install-FromGitHub.ps1') -Raw
foreach($behavior in @('releases/latest','browser_download_url','^sha256:([A-Fa-f0-9]{64})$','Get-FileHash','Expand-Archive','Install-SqlPatchOrchestrator.ps1')){if($online-notmatch[regex]::Escape($behavior)){$failures.Add("Installer behavior '$behavior' is missing.")}}
foreach($prohibited in @('Invoke-Expression','iex ','ConvertTo-SecureString','Get-Credential','Start-MpScan')){if($online-match[regex]::Escape($prohibited)){$failures.Add("Prohibited installer behavior '$prohibited' exists.")}}
$trackedCandidate=Get-ChildItem $PSScriptRoot -Recurse -File|Where-Object{$_.FullName-notmatch'[\\/](\.git|Release|config|docs|scripts|src|tests)[\\/]'-and$_.Name-notin@('AGENTS.md','CHANGELOG.md','NEXT-STEPS.md')}
foreach($file in $trackedCandidate){if($file.Extension-in@('.bak','.exe','.log','.zip','.pfx','.p12','.key','.cer','.crt','.clixml')){$failures.Add("Prohibited artifact '$($file.FullName)'.")}}
foreach($file in $trackedCandidate|Where-Object{$_.Extension-in@('.ps1','.psm1')-and$_.Name-ne'Test-Package.ps1'}){if((Get-Content $file.FullName -Raw)-match[regex]::Escape('Start-MpScan')){$failures.Add("Blocking Defender custom scan exists in '$($file.Name)'.")}}
$privacy='(?i)(github_pat|gh[pousr]_[A-Za-z0-9_]{20,}|api[_ -]?key\s*[:=]|BEGIN [A-Z ]*PRIVATE KEY|SQLPATCH22|SQLEXPRESS01|SQLAGLAB|C:\\AI\\|C:\\Users\\[^\\]+\\)'
foreach($file in $trackedCandidate|Where-Object{$_.Name-ne'Test-Package.ps1'-and($_.Extension-in@('.ps1','.cmd','.md','.txt','.gitignore')-or$_.Name-eq'LICENSE')}){$content=Get-Content $file.FullName -Raw;if($content-match$privacy){$failures.Add("Private-data pattern found in '$($file.FullName)'.")}}
if($failures.Count){$failures|ForEach-Object{"[FAIL] $_"};Write-Output "Validation: FAIL ($($failures.Count))";exit 1}
Write-Output '[PASS] PowerShell 5.1 syntax and required V3 workflow.'
Write-Output '[PASS] Secure release installer and self-contained V2 worker.'
Write-Output '[PASS] No packages, backups, logs, credentials, or private lab identities.'
Write-Output 'Validation: PASS'
