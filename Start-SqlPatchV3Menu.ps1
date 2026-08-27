<# .SYNOPSIS Numbered menu for SQL Patch V3 Remote. #>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Cycle,
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
function Pause-Menu{[void](Read-Host 'Press Enter to return to the menu')}
function Get-CycleStorageKey{
    param([string]$Value)
    if($Value-match'^[A-Za-z]+\d{4}$'){return $Value}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())))).Replace('-','')}finally{$sha.Dispose()}
    'Cycle-'+$hash.Substring(0,16)
}
function Select-PatchCycle{
    param([string]$RequestedCycle)
    $suggested=(Get-Date).ToString('yyyy-MM',[Globalization.CultureInfo]::InvariantCulture)
    if([string]::IsNullOrWhiteSpace($RequestedCycle)){
        $existing=@(Get-ChildItem -LiteralPath $RunRoot -Directory -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|ForEach-Object{$stateFile=Join-Path $_.FullName 'state.json';if(Test-Path -LiteralPath $stateFile -PathType Leaf){try{[string](Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8|ConvertFrom-Json).Cycle}catch{[string]$_.Name}}else{[string]$_.Name}}|Where-Object{$_}|Select-Object -Unique)
        if($existing.Count){Write-Host ('Existing cycles: '+($existing-join', ')) -ForegroundColor DarkGray}
        $RequestedCycle=Read-Host "Cycle name [$suggested]"
        if([string]::IsNullOrWhiteSpace($RequestedCycle)){$RequestedCycle=$suggested}
    }
    $RequestedCycle.Trim()
}
function Get-CycleState{
    $path=Join-Path (Join-Path $RunRoot (Get-CycleStorageKey $Cycle)) 'state.json'
    if(Test-Path -LiteralPath $path -PathType Leaf){return (Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json)}
    return $null
}
function Show-InventoryBlockers{
    param($State)
    Write-Host "Preparation was not started. Cycle '$Cycle' does not have a successful inventory." -ForegroundColor Yellow
    if($State){Write-Host "Current stage: $($State.Stage)";foreach($server in @($State.Servers|Where-Object{$_.Status-in@('Blocked','Failed')})){Write-Host ("  {0}: {1} - {2}" -f $server.Server,$server.Status,$server.Message) -ForegroundColor Yellow}}
    Write-Host 'Fix the listed target, access, SQL, or standalone-safety issue, then run option 2 again.' -ForegroundColor Yellow
}
function Test-InventoryAccessDenied{
    param($State)
    if(-not$State){return $false}
    return @($State.Servers|Where-Object{$_.Status-eq'Failed'-and$_.Message-match'(?i)Access is denied|0x80070005'}).Count-gt0
}
function Enable-TrustAllWinRmHosts{
    $path='WSMan:\localhost\Client\TrustedHosts'
    $current=[string](Get-Item -Path $path -ErrorAction Stop).Value
    if($current-eq'*'){Write-Host 'WinRM TrustedHosts is already * on this controller.' -ForegroundColor DarkGray;return}
    Set-Item -Path $path -Value '*' -Force -ErrorAction Stop
    Write-Host 'WinRM TrustedHosts was set to * on this controller.' -ForegroundColor Yellow
}
$Cycle=Select-PatchCycle $Cycle
$common=@{Cycle=$Cycle;PackageRoot=$PackageRoot;RunRoot=$RunRoot;Transport=$Transport}
if($Credential){$common.Credential=$Credential}
$mutexBytes=[Text.Encoding]::UTF8.GetBytes($PSScriptRoot.ToLowerInvariant());$mutexSha=[Security.Cryptography.SHA256]::Create()
try{$mutexId=([BitConverter]::ToString($mutexSha.ComputeHash($mutexBytes))).Replace('-','')}finally{$mutexSha.Dispose()}
$menuMutex=New-Object Threading.Mutex($false,"Local\SqlPatchV3Menu_$mutexId")
if(-not$menuMutex.WaitOne(0)){Write-Host 'Another SQL Patch V3 menu is already running. Use that window or close it first.' -ForegroundColor Yellow;[void](Read-Host 'Press Enter to exit');$menuMutex.Dispose();return}
try{while($true){
    Clear-Host
    Write-Host 'SQL PATCH V3 REMOTE - STANDALONE ONLY'
    Write-Host '====================================='
    Write-Host "Cycle: $Cycle"
    Write-Host ("Remote account: {0}" -f $(if($common.ContainsKey('Credential')){$common.Credential.UserName}else{[Security.Principal.WindowsIdentity]::GetCurrent().Name+' (current Windows account)'}))
    Write-Host '1. Open target list (SERVER or SERVER\INSTANCE)'
    Write-Host '2. Inventory, backup review, and optional COPY_ONLY backup'
    Write-Host '3. Choose/download latest CUs, verify, and distribute (NO INSTALL)'
    Write-Host '4. Final remote preflight (READ ONLY)'
    Write-Host '5. Apply sequentially and always reboot patched targets'
    Write-Host '6. Post-patch verification (READ ONLY)'
    Write-Host '7. Show current status and open dashboard'
    Write-Host '8. Select or create another patch cycle'
    Write-Host '0. Exit'
    $choice=Read-Host 'Select'
    try{
        switch($choice){
            '1'{Start-Process notepad.exe -ArgumentList "`"$targets`"";Pause-Menu}
            '2'{
                & $engine -Mode Inventory @common
                $inventoryCode=$LASTEXITCODE
                Write-Host "Inventory exit code: $inventoryCode"
                $inventoryState=Get-CycleState
                if($inventoryCode-ne0-and(Test-InventoryAccessDenied $inventoryState)){
                    try{
                        Enable-TrustAllWinRmHosts
                        Write-Host ("Retrying Inventory with current account '{0}'..." -f [Security.Principal.WindowsIdentity]::GetCurrent().Name) -ForegroundColor Cyan
                        & $engine -Mode Inventory @common
                        $inventoryCode=$LASTEXITCODE
                        $inventoryState=Get-CycleState
                        Write-Host "Retry Inventory exit code: $inventoryCode"
                    }catch{Write-Host "Could not configure WinRM TrustedHosts: $($_.Exception.Message)" -ForegroundColor Red}
                }
                if($inventoryCode-eq0){
                    $statePath=Join-Path (Join-Path $RunRoot (Get-CycleStorageKey $Cycle)) 'state.json'
                    $inventoryState=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
                    $warningCount=@($inventoryState.Servers|ForEach-Object Instances|ForEach-Object BackupWarnings).Count
                    Write-Host "Backup warnings: $warningCount" -ForegroundColor $(if($warningCount){'Yellow'}else{'Green'})
                    Write-Host 'System backup action:' -ForegroundColor Cyan
                    Write-Host '0. Do not create new backups (default)'
                    Write-Host '1. Back up master, model, and msdb now on every selected instance'
                    Write-Host '   Uses COPY_ONLY + CHECKSUM + RESTORE VERIFYONLY; excludes tempdb and all user databases.' -ForegroundColor DarkGray
                    $backup=Read-Host 'Select [0]';if([string]::IsNullOrWhiteSpace($backup)){$backup='0'}
                    if($backup-eq'1'){& $engine -Mode Backup @common -ConfirmBackup -BackupChoice 1;Write-Host "Backup exit code: $LASTEXITCODE"}
                    elseif($backup-ne'0'){throw 'Backup choice must be 0 or 1.'}
                }else{
                    Show-InventoryBlockers $inventoryState
                    Write-Host 'System backup was not offered because inventory did not pass.' -ForegroundColor Yellow
                }
                Pause-Menu
            }
            '3'{
                $inventoryState=Get-CycleState
                if(-not$inventoryState-or$inventoryState.Stage-notin@('InventoryReady','Prepared','PreflightReady')){Show-InventoryBlockers $inventoryState;Pause-Menu;continue}
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
            '7'{& $engine -Mode Dashboard @common;$path=Join-Path (Join-Path $RunRoot (Get-CycleStorageKey $Cycle)) 'Dashboard.html';if(Test-Path $path){Start-Process $path};Pause-Menu}
            '8'{$Cycle=Select-PatchCycle ''; $common.Cycle=$Cycle;Write-Host "Active cycle: $Cycle" -ForegroundColor Green;Pause-Menu}
            '0'{return}
            default{Write-Host 'Select 0-8.' -ForegroundColor Yellow;Pause-Menu}
        }
    }
    catch{Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red;Pause-Menu}
}}
finally{if($common.ContainsKey('Credential')){$common.Remove('Credential')};$Credential=$null;$menuMutex.ReleaseMutex();$menuMutex.Dispose()}
