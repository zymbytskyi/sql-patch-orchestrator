<# .SYNOPSIS Numbered menu for SQL Patch V3 Remote. #>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Cycle=(Get-Date).ToString('MMMMyyyy',[Globalization.CultureInfo]::GetCultureInfo('en-US')),
    [string]$PackageRoot,
    [string]$RunRoot,
    [ValidateSet('WinRM','PowerShellDirect')][string]$Transport='WinRM',
    [pscredential]$Credential
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($PackageRoot)){$PackageRoot=Join-Path $PSScriptRoot 'Packages'}
if([string]::IsNullOrWhiteSpace($RunRoot)){$RunRoot=Join-Path $PSScriptRoot 'Runs'}
$engine=Join-Path $PSScriptRoot 'Invoke-SqlPatchV3Remote.ps1'
$targets=Join-Path $PSScriptRoot 'targets.txt'
$common=@{Cycle=$Cycle;PackageRoot=$PackageRoot;RunRoot=$RunRoot;Transport=$Transport}
if($Credential){$common.Credential=$Credential}
function Pause-Menu{[void](Read-Host 'Press Enter to return to the menu')}
$mutexBytes=[Text.Encoding]::UTF8.GetBytes($PSScriptRoot.ToLowerInvariant());$mutexSha=[Security.Cryptography.SHA256]::Create()
try{$mutexId=([BitConverter]::ToString($mutexSha.ComputeHash($mutexBytes))).Replace('-','')}finally{$mutexSha.Dispose()}
$menuMutex=New-Object Threading.Mutex($false,"Local\SqlPatchV3Menu_$mutexId")
if(-not$menuMutex.WaitOne(0)){Write-Host 'Another SQL Patch V3 menu is already running. Use that window or close it first.' -ForegroundColor Yellow;[void](Read-Host 'Press Enter to exit');$menuMutex.Dispose();return}
try{while($true){
    Clear-Host
    Write-Host 'SQL PATCH V3 REMOTE - STANDALONE ONLY'
    Write-Host '====================================='
    Write-Host "Cycle: $Cycle"
    Write-Host '1. Open target list (SERVER or SERVER\INSTANCE)'
    Write-Host '2. Inventory, backup review, and optional COPY_ONLY backup'
    Write-Host '3. Choose/download latest CUs, verify, and distribute (NO INSTALL)'
    Write-Host '4. Final remote preflight (READ ONLY)'
    Write-Host '5. Apply sequentially and always reboot patched targets'
    Write-Host '6. Post-patch verification (READ ONLY)'
    Write-Host '7. Show current status and open dashboard'
    Write-Host '0. Exit'
    $choice=Read-Host 'Select'
    try{
        switch($choice){
            '1'{Start-Process notepad.exe -ArgumentList "`"$targets`"";Pause-Menu}
            '2'{
                & $engine -Mode Inventory @common
                $inventoryCode=$LASTEXITCODE
                Write-Host "Inventory exit code: $inventoryCode"
                if($inventoryCode-eq0){
                    $statePath=Join-Path (Join-Path $RunRoot $Cycle) 'state.json'
                    $inventoryState=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
                    $warningCount=@($inventoryState.Servers|ForEach-Object Instances|ForEach-Object BackupWarnings).Count
                    Write-Host "Backup warnings: $warningCount" -ForegroundColor $(if($warningCount){'Yellow'}else{'Green'})
                    Write-Host '0. Continue without creating a backup (default)'
                    Write-Host '1. Create and verify COPY_ONLY system-database backups on every selected instance'
                    $backup=Read-Host 'Select [0]';if([string]::IsNullOrWhiteSpace($backup)){$backup='0'}
                    if($backup-eq'1'){& $engine -Mode Backup @common -ConfirmBackup -BackupChoice 1;Write-Host "Backup exit code: $LASTEXITCODE"}
                    elseif($backup-ne'0'){throw 'Backup choice must be 0 or 1.'}
                }
                Pause-Menu
            }
            '3'{
                Write-Host '1. Use reviewed Microsoft EXEs already in Packages (default)'
                Write-Host '2. Download latest CUs from Microsoft automatically'
                $source=Read-Host 'Select [1]';if([string]::IsNullOrWhiteSpace($source)){$source='1'}
                if($source-eq'1'){& $engine -Mode Prepare @common}
                elseif($source-eq'2'){& $engine -Mode Prepare @common -DownloadLatest}
                else{throw 'Package source must be 1 or 2.'}
                Write-Host "Exit code: $LASTEXITCODE";Pause-Menu
            }
            '4'{
                & $engine -Mode Preflight @common;Write-Host "Exit code: $LASTEXITCODE";Pause-Menu
            }
            '5'{
                if((Read-Host 'Type 5 again to start or resume Apply')-ne'5'){Write-Host 'Cancelled.';Pause-Menu;continue}
                $backup=Read-Host 'Backups: 0 none, 1 system [0]';if([string]::IsNullOrWhiteSpace($backup)){$backup='0'};if($backup-notin@('0','1')){throw 'Backup choice must be 0 or 1.'}
                & $engine -Mode Apply @common -ConfirmApply -BackupChoice $backup;Write-Host "Exit code: $LASTEXITCODE";Pause-Menu
            }
            '6'{& $engine -Mode PostVerify @common;Write-Host "Exit code: $LASTEXITCODE";Pause-Menu}
            '7'{& $engine -Mode Dashboard @common;$path=Join-Path (Join-Path $RunRoot $Cycle) 'Dashboard.html';if(Test-Path $path){Start-Process $path};Pause-Menu}
            '0'{return}
            default{Write-Host 'Select 0-7.' -ForegroundColor Yellow;Pause-Menu}
        }
    }
    catch{Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red;Pause-Menu}
}}
finally{$menuMutex.ReleaseMutex();$menuMutex.Dispose()}
