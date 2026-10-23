<# .SYNOPSIS Updates program files from one reviewed immutable GitHub commit. Does not run SQL patching. #>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$Commit,
    [string]$Destination='C:\SqlPatchOrchestrator'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
function Get-GitBlobHash {
    param([string]$Path)
    $bytes=[IO.File]::ReadAllBytes($Path)
    $header=[Text.Encoding]::UTF8.GetBytes("blob $($bytes.Length)"+[char]0)
    $sha=[Security.Cryptography.SHA1]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash([byte[]]($header+$bytes)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Install-VerifiedProgramFiles {
    param([string]$Stage,[string]$Destination,[string[]]$Files,[hashtable]$Hashes)
    $destinationRoot=[IO.Path]::GetFullPath($Destination).TrimEnd('\')
    if($destinationRoot-eq[IO.Path]::GetPathRoot($destinationRoot).TrimEnd('\')){throw 'Destination cannot be a drive root.'}
    if(Test-Path -LiteralPath $destinationRoot){
        $item=Get-Item -LiteralPath $destinationRoot
        if($item.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Destination must not be a junction or symbolic link.'}
    }
    foreach($name in $Files){
        if($name-match'(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($name)){throw 'Unsafe program path.'}
        $target=[IO.Path]::GetFullPath((Join-Path $destinationRoot $name))
        if(-not$target.StartsWith($destinationRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Program path escapes destination.'}
        $check=$target
        while($check-and$check.StartsWith($destinationRoot,[StringComparison]::OrdinalIgnoreCase)){
            if(Test-Path -LiteralPath $check){if((Get-Item -LiteralPath $check).Attributes-band[IO.FileAttributes]::ReparsePoint){throw "Reparse point in destination: $check"}}
            $check=Split-Path $check -Parent
        }
        if((Get-GitBlobHash (Join-Path $Stage $name))-ne$Hashes[$name]){throw "Staged hash mismatch: $name"}
    }
    New-Item -ItemType Directory -Path $destinationRoot -Force|Out-Null
    $backup=Join-Path $destinationRoot ('ProgramBackups\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup -Force|Out-Null
    $existing=@{}
    foreach($name in $Files){
        $target=Join-Path $destinationRoot $name
        $existing[$name]=Test-Path -LiteralPath $target -PathType Leaf
        if($existing[$name]){
            $copy=Join-Path $backup $name
            New-Item -ItemType Directory -Path (Split-Path $copy) -Force|Out-Null
            Copy-Item -LiteralPath $target -Destination $copy -Force
        }
    }
    $changed=New-Object Collections.Generic.List[string]
    try{
        foreach($name in $Files){
            $target=Join-Path $destinationRoot $name
            New-Item -ItemType Directory -Path (Split-Path $target) -Force|Out-Null
            $changed.Add($name)
            Copy-Item -LiteralPath (Join-Path $Stage $name) -Destination $target -Force
            if((Get-GitBlobHash $target)-ne$Hashes[$name]){throw "Installed hash mismatch: $name"}
        }
    }catch{
        $failure=$_.Exception.Message
        foreach($name in $changed){
            $target=Join-Path $destinationRoot $name
            if($existing[$name]){Copy-Item -LiteralPath (Join-Path $backup $name) -Destination $target -Force}
            elseif(Test-Path -LiteralPath $target -PathType Leaf){Remove-Item -LiteralPath $target -Force}
        }
        throw "Program update failed; previous files restored from '$backup'. $failure"
    }
    $backup
}

$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run Windows PowerShell as Administrator.'}
$Destination=[IO.Path]::GetFullPath($Destination).TrimEnd('\')
$running=@(Get-CimInstance Win32_Process|Where-Object{
    $_.ProcessId-ne$PID-and$_.Name-match'^(powershell|pwsh)\.exe$'-and$_.CommandLine-match'(Start-SqlPatchV3Menu|Invoke-SqlPatchV3Remote|Invoke-SqlPatchV2Local)\.ps1'
})
if($running.Count){throw 'Close all patch menus and wait for active patch operations to finish before updating.'}
# Same menu mutex; held until the complete program replacement is finished.
$hash=[Security.Cryptography.SHA256]::Create()
try{$mutexId=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Destination.ToLowerInvariant())))).Replace('-','')}finally{$hash.Dispose()}
$mutex=New-Object Threading.Mutex($false,"Local\SqlPatchV3Menu_$mutexId")
$held=$false
try{
    try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
    if(-not$held){throw 'A patch menu is open. Close it before updating.'}
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $repo='zymbytskyi/sql-patch-orchestrator'
    $headers=@{'User-Agent'='SqlPatchOrchestrator-Updater';Accept='application/vnd.github+json'}
    $tree=Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/git/trees/${Commit}?recursive=1" -Headers $headers -ErrorAction Stop
    if($tree.truncated){throw 'GitHub returned a truncated file tree.'}
    $files=@('Invoke-SqlPatchV3Remote.ps1','SqlPatchParallel.ps1','Start-SqlPatchV3Menu.ps1','SqlPatchV2Local/Invoke-SqlPatchV2Local.ps1','SqlPatchV2Local/SqlPatchUpdates.ps1','SqlPatchV2Local/README.md','README.md','CHANGELOG.md','RELEASE-NOTES.md','SECURITY.md','LICENSE','VERSION','Update-FromGitHub.ps1')
    $stage=Join-Path ([IO.Path]::GetTempPath()) ('SqlPatchUpdate-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage|Out-Null
    $hashes=@{}
    foreach($name in $files){
        $entries=@($tree.tree|Where-Object{$_.path-eq$name-and$_.type-eq'blob'-and$_.mode-eq'100644'})
        if($entries.Count-ne1){throw "Missing or ambiguous program file in commit: $name"}
        $file=Join-Path $stage $name
        New-Item -ItemType Directory -Path (Split-Path $file) -Force|Out-Null
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$repo/$Commit/$name" -UseBasicParsing -OutFile $file -ErrorAction Stop
        $hashes[$name]=[string]$entries[0].sha
        if((Get-GitBlobHash $file)-ne$hashes[$name]){throw "Git blob hash mismatch: $name"}
        if($name.EndsWith('.ps1')){
            $tokens=$null;$errors=$null
            [void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
            if($errors.Count){throw "PowerShell syntax error in $name"}
        }
    }
    $backup=Install-VerifiedProgramFiles -Stage $stage -Destination $Destination -Files $files -Hashes $hashes
    # Existing state and media are never rewritten or removed.
    foreach($folder in @('Packages','Runs')){New-Item -ItemType Directory -Path (Join-Path $Destination $folder) -Force|Out-Null}
    if(-not(Test-Path -LiteralPath (Join-Path $Destination 'targets.txt'))){[IO.File]::WriteAllText((Join-Path $Destination 'targets.txt'),'# Add approved SERVER\INSTANCE targets here.'+[Environment]::NewLine)}
    Write-Host ("Updated to "+(Get-Content -LiteralPath (Join-Path $Destination 'VERSION') -Raw).Trim()+" from commit $Commit") -ForegroundColor Green
    Write-Host "Previous program files: $backup"
    Write-Host 'targets.txt, Packages and Runs preserved. No SQL installation or reboot started.'
    Write-Host 'Reopen the menu. Run Inventory, then option 3 / source 2, then Readiness. Review the new KB/build before Apply.'
}finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}

