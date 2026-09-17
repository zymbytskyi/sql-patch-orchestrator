#Requires -Version 5.1
# Shared coordinator helpers. Only the parent writes the campaign state/dashboard.
function Copy-VerifiedSmb {
    param([string]$LocalPath,[string]$RemotePath,$Session,[string]$ExpectedHash,[string]$Server)
    if($ExpectedHash-notmatch '^[A-Fa-f0-9]{64}$'){throw 'Missing frozen SHA-256.'}
    if($RemotePath-notmatch '^([A-Za-z]):\\(.+)$'){throw 'SMB staging requires an absolute drive path.'}
    $drive=$matches[1];$relative=$matches[2]
    if($Server-notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$'){throw 'Invalid SMB host name.'}
    $existing=Invoke-Command -Session $Session -ArgumentList $RemotePath -ScriptBlock {
        param($Path);if(Test-Path -LiteralPath $Path -PathType Leaf){(Get-FileHash -LiteralPath $Path).Hash}
    }
    if($existing-eq$ExpectedHash){return 'AlreadyPresent'}
    if($ExpectedHash-notmatch '^[A-Fa-f0-9]{64}$'){throw 'Missing frozen SHA-256.'}
    $folder=Split-Path $RemotePath -Parent
    $staging=Join-Path $folder ('.staging\'+$ExpectedHash)
    $name=[IO.Path]::GetFileName($LocalPath)
    $candidate=Join-Path $staging $name
    # Never expose an unverified file at the final package path.
    Invoke-Command -Session $Session -ArgumentList $staging -ScriptBlock {param($Path);New-Item -ItemType Directory -Path $Path -Force|Out-Null}
    $unc='\\'+$Server+'\'+$drive+'$\'+$staging.Substring(3)
    if(-not(Test-Path -LiteralPath $unc)){
        throw "SMB destination unavailable: $unc. Check TCP 445 and share permissions for the current Windows account, or explicitly choose PowerShell transfer. No automatic slow fallback."
    }
    $logRoot=Join-Path $cycleRoot 'TransferLogs'
    New-Item -ItemType Directory -Path $logRoot -Force|Out-Null
    $log=Join-Path $logRoot ($Server+'-'+[guid]::NewGuid().ToString('N')+'.log')
    $help=(& robocopy.exe /? | Out-String)
    $options=@('/Z','/J','/R:2','/W:3','/COPY:DAT','/DCOPY:T','/BYTES','/ETA')
    if($help-match '/IORATE'){$options+=('/IORATE:'+([long]$CopyLimitMBps*1MB));$pacing="limit $CopyLimitMBps MiB/s"}
    else{
        $gap=[math]::Max(1,[int][math]::Ceiling(1000.0/(16*$CopyLimitMBps)))
        $options+=('/IPG:'+$gap);$pacing="legacy pacing $gap ms (not a strict bandwidth cap)"
    }
    $arguments=@((Split-Path ([IO.Path]::GetFullPath($LocalPath)) -Parent),$unc,$name)+$options+@('/UNILOG:'+$log)
    foreach($argument in $arguments){if($argument-match '["\r\n]'){throw 'Unsupported quote or newline in copy argument.'}}
    $commandLine=($arguments|ForEach-Object{if($_.EndsWith('\')){'"'+$_+'\'+'"'}else{'"'+$_+'"'}})-join' '
    $process=$null;$timer=[Diagnostics.Stopwatch]::StartNew()
    try{
        $process=Start-Process -FilePath robocopy.exe -ArgumentList $commandLine -WindowStyle Hidden -PassThru
        $null=$process.Handle
        do{
            $finished=$process.WaitForExit(2000)
            $progress=''
            if(Test-Path -LiteralPath $log){
                $tail=Get-Content -LiteralPath $log -Tail 12 -Encoding Unicode -ErrorAction SilentlyContinue|Out-String
                $percent=[regex]::Matches($tail,'\d+(?:[.,]\d+)?%')
                if($percent.Count){$progress=$percent[$percent.Count-1].Value}
            }
            Set-ServerState $state $Server 'Copying' ("SMB $progress -> $RemotePath; $pacing; elapsed $([int]$timer.Elapsed.TotalSeconds)s")
        }while(-not$finished)
        $process.Refresh()
        if($null-eq$process.ExitCode){throw "Robocopy result is unavailable; see $log. Package remains unverified."}
        if($process.ExitCode-ge8){throw "Robocopy exit $($process.ExitCode); see $log. Partial data retained for restart."}
        Set-ServerState $state $Server 'Copying' "SMB completed; verifying SHA-256 on target: $RemotePath"
        $actual=Invoke-Command -Session $Session -ArgumentList $candidate -ScriptBlock {param($Path);(Get-FileHash -LiteralPath $Path).Hash}
        if($actual-ne$ExpectedHash){
            # Do not repeatedly reuse a completed-but-corrupt candidate.
            Invoke-Command -Session $Session -ArgumentList $candidate -ScriptBlock {param($Path);Remove-Item -LiteralPath $Path -Force}
            throw 'SMB SHA-256 mismatch. Invalid staging copy removed; final package was not replaced.'
        }
        Invoke-Command -Session $Session -ArgumentList $candidate,$RemotePath -ScriptBlock {param($Source,$Final);Move-Item -LiteralPath $Source -Destination $Final -Force}
        return 'Copied (SMB verified)'
    }finally{
        if($process){if(-not$process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()}
    }
}
function Show-PreflightSummary {
    param($State)
    foreach($entry in $State.Servers){
        $ready=(Get-PropertyValue $entry PreflightStatus 'Not ready')-eq'Ready'
        $label=if($ready){'READY'}else{'NOT READY'}
        $reason=Get-PropertyValue $entry PreflightDetails $entry.Message
        if($reason.Length-gt110){$reason=$reason.Substring(0,107)+'...'}
        Write-Host ("{0}: {1} - {2}"-f$entry.Server,$label,$reason) -ForegroundColor $(if($ready){'Green'}else{'Yellow'})
    }
    Write-Host "Details: $dashboardPath"
}
function Get-ControllerCapacity {
    $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cpu=@(Get-CimInstance Win32_Processor -ErrorAction Stop | ForEach-Object LoadPercentage)
    if(-not$cpu.Count-or$null-eq$cpu[0]){throw 'Controller CPU measurement unavailable.'}
    [pscustomobject]@{FreeGB=[double]$os.FreePhysicalMemory/1MB;Cpu=[double]($cpu|Measure-Object -Average).Average}
}
function Resolve-ExecutionHosts {
    param($State)
    $controllerId=[string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -ErrorAction Stop).MachineGuid
    $seen=@{}
    foreach($entry in $State.Servers){
        $session=$null
        try{
            $session=New-TargetSession $entry.Server
            $identity=Invoke-Command -Session $session -ScriptBlock {
                [pscustomobject]@{Id=[string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid;Name=$env:COMPUTERNAME}
            }
            if([string]::IsNullOrWhiteSpace($identity.Id)){throw "Cannot establish physical identity of '$($entry.Server)'."}
            if($seen.ContainsKey($identity.Id)){throw "Targets '$($seen[$identity.Id])' and '$($entry.Server)' refer to the same Windows host. Use one server entry with its selected instances."}
            $seen[$identity.Id]=$entry.Server
            $previous=Get-PropertyValue $entry HostIdentity ''
            if($previous-and$previous-ne$identity.Id){throw "Target host identity changed for '$($entry.Server)'. Start a new inventory before continuing."}
            Set-PropertyValue $entry HostIdentity $identity.Id
            Set-PropertyValue $entry IsController ($identity.Id-eq$controllerId)
        }finally{if($session){Remove-PSSession $session}}
    }
}
function Invoke-ParallelPhase {
    param($State,[ValidateSet('Prepare','Apply')][string]$Phase,[string]$EnginePath=(Join-Path $PSScriptRoot 'Invoke-SqlPatchV3Remote.ps1'))
    Resolve-ExecutionHosts $State
    $limit=if($Phase-eq'Prepare'){$CopyConcurrency}else{$ApplyConcurrency}
    $queue=New-Object Collections.Queue
    foreach($entry in $State.Servers|Where-Object {-not(Get-PropertyValue $_ IsController $false)}){
        if($Phase-eq'Apply'-and$entry.Status-eq'Complete'){continue}
        $queue.Enqueue($entry)
    }
    # Controller SQL is always last and never automatically rebooted.
    $local=@($State.Servers|Where-Object {Get-PropertyValue $_ IsController $false})
    $running=New-Object Collections.ArrayList
    $failed=$false;$pausedSince=$null;$lastMessage=''
    $State.Stage=if($Phase-eq'Prepare'){'Preparing'}else{'Applying'}
    Save-State $State
    try{
        while($queue.Count-or$running.Count){
            $changed=$false
            foreach($task in @($running)){
                if(Test-Path -LiteralPath $task.StatePath){
                    try{
                        $snapshot=Get-Content -LiteralPath $task.StatePath -Raw -Encoding UTF8|ConvertFrom-Json
                        $updated=$snapshot.Servers[0]
                        if($task.LastSeen-ne$snapshot.UpdatedUtc){
                            $index=[array]::IndexOf($State.Servers,$task.Entry)
                            $State.Servers[$index]=$updated;$task.Entry=$updated;$task.LastSeen=$snapshot.UpdatedUtc;$changed=$true
                        }
                    }catch{} # Atomic snapshots can be briefly absent before the first worker write.
                }
                if($task.Job.State-in@('Completed','Failed','Stopped')){
                    $result=@(Receive-Job $task.Job -ErrorAction SilentlyContinue)
                    $snapshotValid=$false
                    try{
                        $snapshot=Get-Content -LiteralPath $task.StatePath -Raw -Encoding UTF8|ConvertFrom-Json
                        if($snapshot.Servers[0].Server-ne$task.Entry.Server){throw 'Worker snapshot target mismatch.'}
                        $index=[array]::IndexOf($State.Servers,$task.Entry)
                        $State.Servers[$index]=$snapshot.Servers[0];$task.Entry=$State.Servers[$index]
                        $expected=if($Phase-eq'Prepare'){'Prepared'}else{'Complete'}
                        $snapshotValid=$task.Entry.Status-eq$expected
                    }catch{}
                    $ok=$snapshotValid-and$task.Job.State-eq'Completed'-and$result.Count-and$result[-1].ExitCode-eq0
                    Set-PropertyValue $task.Entry DispatchPending ($task.Job.State-ne'Completed')
                    if(-not$ok){
                        $failed=$true
                        if($task.Entry.Status-ne'Failed'){$task.Entry.Status='Failed';$task.Entry.Message='Worker failed or was interrupted. Review worker state before retrying.'}
                    }
                    Remove-Job $task.Job -Force
                    [void]$running.Remove($task);$changed=$true
                }
            }
            if($changed){Save-State $State}
            if($queue.Count-and$running.Count-lt$limit-and-not($failed-and$Phase-eq'Apply')){
                try{
                    $capacity=Get-ControllerCapacity
                    $canStart=$capacity.Cpu-lt$ControllerCpuLimit-and$capacity.FreeGB-ge$MinimumControllerFreeGB
                    $message='Controller CPU {0:n0}%; free memory {1:n1} GiB; active {2}/{3}; queued {4}' -f $capacity.Cpu,$capacity.FreeGB,$running.Count,$limit,$queue.Count
                }catch{$canStart=$false;$message="Controller monitoring unavailable: $($_.Exception.Message)"}
                if($message-ne$lastMessage){Write-Host $message;$lastMessage=$message}
                if($canStart){
                    $pausedSince=$null
                    $entry=$queue.Dequeue()
                    $key=Get-ScopeHash @($entry.Server)
                    $workerRoot=Join-Path $cycleRoot ('Workers\'+$key.Substring(0,16))
                    $workerCycle=Join-Path $workerRoot (Get-CycleStorageKey $Cycle)
                    New-Item -ItemType Directory -Path $workerCycle -Force|Out-Null
                    $seed=$State|ConvertTo-Json -Depth 12|ConvertFrom-Json
                    $seed.Servers=@($entry|ConvertTo-Json -Depth 12|ConvertFrom-Json)
                    $seed.Stage=if($Phase-eq'Prepare'){'InventoryReady'}else{'PreflightReady'}
                    $names=if(@($entry.RequestedInstances).Count){@($entry.RequestedInstances|ForEach-Object{"$($entry.Server)\$_"})}else{@($entry.Server)}
                    $seed.ScopeHash=Get-ScopeHash $names
                    $workerPath=Join-Path $workerCycle 'state.json'
                    # Journal dispatch before a child can start. A hard controller crash must
                    # never turn an in-flight installer into a fresh retry.
                    if($Phase-eq'Apply'){
                        $entry.Status='Dispatching'
                        $entry.Message='Worker dispatched; interruption requires review of target setup.'
                        Set-PropertyValue $entry DispatchPending $true
                        Set-PropertyValue $seed.Servers[0] DispatchPending $true
                        Save-State $State
                    }
                    [IO.File]::WriteAllText($workerPath,($seed|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
                    $arguments=@{Mode=$Phase;Cycle=$Cycle;TargetListPath=$TargetListPath;PackageRoot=$PackageRoot;RunRoot=$workerRoot;Transport=$Transport;V2SourcePath=$V2SourcePath;WorkerTarget=$entry.Server;ConfirmApply=$true;BackupChoice=$BackupChoice;ReadyTimeoutSeconds=$ReadyTimeoutSeconds;CopyLimitMBps=$CopyLimitMBps}
                    $arguments.CopyMethod=$CopyMethod
                    if($Credential){$arguments.Credential=$Credential}
                    $job=Start-Job -ScriptBlock {
                        param($Engine,$Arguments)
                        & $Engine @Arguments *> $null
                        [pscustomobject]@{ExitCode=$LASTEXITCODE}
                    } -ArgumentList $EnginePath,$arguments
                    [void]$running.Add([pscustomobject]@{Job=$job;Entry=$entry;StatePath=$workerPath;LastSeen=''})
                }else{
                    if($null-eq$pausedSince){$pausedSince=[datetime]::UtcNow}
                    if(([datetime]::UtcNow-$pausedSince).TotalSeconds-ge$ControllerWaitSeconds){
                        $failed=$true
                        while($queue.Count){$pending=$queue.Dequeue();$pending.Status='Deferred';$pending.Message='Controller resource gate timed out; retry when load is lower.'}
                        Save-State $State
                    }
                }
            }
            if($failed-and$Phase-eq'Apply'-and$queue.Count){
                while($queue.Count){$pending=$queue.Dequeue();$pending.Status='Deferred';$pending.Message='Not started because another Apply failed.'}
                Save-State $State
            }
            if($queue.Count-or$running.Count){Start-Sleep -Milliseconds 1000}
        }
        if($local.Count){
            if($failed-and$Phase-eq'Apply'){
                $local[0].Status='Deferred';$local[0].Message='Controller SQL deferred until all remote targets succeed.'
            }else{
                # Reuse the same bounded worker path with a single remaining controller entry.
                $entry=$local[0];$session=$null
                try{
                    $deadline=[datetime]::UtcNow.AddSeconds($ControllerWaitSeconds)
                    do{
                        $capacity=Get-ControllerCapacity
                        if($capacity.Cpu-lt$ControllerCpuLimit-and$capacity.FreeGB-ge$MinimumControllerFreeGB){break}
                        if([datetime]::UtcNow-ge$deadline){throw 'Controller resource gate timed out before local SQL operation.'}
                        Write-Host 'Waiting for controller load to fall before local SQL operation...'
                        Start-Sleep -Seconds 5
                    }while($true)
                    $session=New-TargetSession $entry.Server
                    if($Phase-eq'Prepare'){Prepare-OneServer $State $entry $session}
                    else{Apply-OneServer $State $entry $session}
                }catch{$failed=$true;Set-ServerState $State $entry.Server 'Failed' $_.Exception.Message}
                finally{if($session){Remove-PSSession $session -ErrorAction SilentlyContinue}}
            }
        }
        $State.Stage=if($failed){if($Phase-eq'Prepare'){'PrepareFailed'}else{'Failed'}}elseif($Phase-eq'Prepare'){'Prepared'}elseif(@($State.Servers|Where-Object Status -eq 'AwaitingControllerRestart').Count){'AwaitingControllerRestart'}else{'Complete'}
        Save-State $State
        if($failed){throw "$Phase did not complete on every target. Successful target results were preserved."}
    }finally{
        # Never restart or blindly re-run a SQL installer after a controller interruption.
        foreach($task in @($running)){
            $task.Entry.Status='NeedsReview';$task.Entry.Message='Controller interrupted while worker was active. Check SQL Setup on target before resuming.'
            Stop-Job $task.Job -ErrorAction SilentlyContinue
            Remove-Job $task.Job -Force -ErrorAction SilentlyContinue
        }
        if($running.Count){$State.Stage='NeedsReview';Save-State $State}
    }
}
function Get-PrefixHash {
    param([string]$Path,[long]$Length)
    $stream=[IO.File]::OpenRead($Path);$sha=[Security.Cryptography.SHA256]::Create()
    try{
        $buffer=New-Object byte[] 1048576;$remaining=$Length
        while($remaining-gt0){$read=$stream.Read($buffer,0,[int][math]::Min($buffer.Length,$remaining));if($read-eq0){throw 'Source file truncated.'};[void]$sha.TransformBlock($buffer,0,$read,$buffer,0);$remaining-=$read}
        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0)
        ([BitConverter]::ToString($sha.Hash)).Replace('-','')
    }finally{$stream.Dispose();$sha.Dispose()}
}
function Prepare-OneServer {
    param($State,$Entry,$Session)
    $local=[bool](Get-PropertyValue $Entry IsController $false)
    $server=$Entry.Server
    Set-PropertyValue $Entry PreflightStatus 'Not checked'
    Set-PropertyValue $Entry PreflightDetails 'Run option 4 after preparation'
    foreach($instance in $Entry.Instances){
        $instance.PackageHashVerified='Not checked';$instance.PackageState='Not verified'
        $instance.DistributionState='Pending'
    }
    Set-ServerState $State $Entry.Server 'Copying' 'Verifying existing media and staging required bytes'
    if(-not$local){
        Invoke-Command -Session $Session -ScriptBlock {New-Item -ItemType Directory -Path 'C:\SqlPatchV3Remote\V2','C:\SqlPatchV3Remote\Packages' -Force|Out-Null}
        foreach($worker in Get-ChildItem -LiteralPath $V2SourcePath -File){
            [void](Copy-VerifiedToSession $worker.FullName ("C:\SqlPatchV3Remote\V2\"+$worker.Name) $Session)
        }
    }
    $staged=@{}
    foreach($instance in $Entry.Instances){
        $package=@($State.Packages|Where-Object Major -eq $instance.Major)[0]
        if(-not$package){throw "Package metadata missing for SQL major $($instance.Major)."}
        $path=if($local){$package.Path}else{"C:\SqlPatchV3Remote\Packages\$($package.Name)"}
        Set-PropertyValue $instance RemotePackagePath $path
        Set-PropertyValue $instance CopyMethod $(if($local){'Local reuse'}elseif($Transport-eq'PowerShellDirect'){'PowerShellDirect'}else{$CopyMethod})
        if(-not$staged.ContainsKey($package.Name)){
            if($local){
                if((Get-FileHash -LiteralPath $path).Hash-ne$package.Hash){throw 'Local package changed after verification.'}
                $staged[$package.Name]='LocalExisting'
            }elseif($CopyMethod-eq'SMB'-and$Transport-ne'PowerShellDirect'){
                $staged[$package.Name]=Copy-VerifiedSmb $package.Path $path $Session $package.Hash $Entry.Server
            }else{$staged[$package.Name]=Copy-VerifiedToSession $package.Path $path $Session $package.Hash}
        }
        $instance.TargetVersion=$package.Version;$instance.PackageName=$package.Name
        foreach($field in @('UpdateName','ReleaseDate','PackageAgeDays','MetadataSource')){Set-PropertyValue $instance $field $package.$field}
        Set-PropertyValue $instance RemotePackagePath $path
        $instance.DistributionState=$staged[$package.Name];$instance.PackageState='Staged';$instance.PackageHashVerified='Yes'
        Set-PropertyValue $instance PackageVerifiedUtc ([datetime]::UtcNow.ToString('o'))
        Set-PropertyValue $instance PackageSha256 $package.Hash
        Save-State $State
    }
    Set-PropertyValue $Entry WorkerPath $(if($local){Join-Path $V2SourcePath 'Invoke-SqlPatchV2Local.ps1'}else{'C:\SqlPatchV3Remote\V2\Invoke-SqlPatchV2Local.ps1'})
    Set-ServerState $State $Entry.Server 'Prepared' $(if($local){'Using existing local packages and worker; no self-copy'}else{'Required packages staged and SHA-256 verified'})
}
function Apply-OneServer {
    param($State,$Entry,$Session)
    $server=$Entry.Server
    $facts=Invoke-Command -Session $Session -ScriptBlock {
        [pscustomobject]@{Id=[string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid;Boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o');SetupRunning=[bool](Get-Process setup,ScenarioEngine,SQLSetupBootstrapper -ErrorAction SilentlyContinue)}
    }
    if($facts.Id-ne(Get-PropertyValue $Entry HostIdentity '')){throw 'Target host identity changed; run Inventory/Prepare again.'}
    if($facts.SetupRunning){throw 'Another setup process is running; no installer was started.'}
    $controllerId=[string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
    $local=$facts.Id-eq$controllerId
    $fresh=Get-RemoteInventory $Session
    if($fresh.ClusterRegistry-or$fresh.ClusterService-notin@('Absent','Stopped')){throw 'WSFC detected before Apply.'}
    $workerPath=Get-PropertyValue $Entry WorkerPath 'C:\SqlPatchV3Remote\V2\Invoke-SqlPatchV2Local.ps1'
    $workerHash=(Get-FileHash (Join-Path $V2SourcePath 'Invoke-SqlPatchV2Local.ps1')).Hash
    $remoteWorkerHash=Invoke-Command -Session $Session -ArgumentList $workerPath -ScriptBlock {param($Path);(Get-FileHash -LiteralPath $Path).Hash}
    if($remoteWorkerHash-ne$workerHash){throw 'Target worker changed after preparation.'}
    foreach($instance in $Entry.Instances){
        if((Get-PropertyValue $instance InstallOutcome '')-eq'Started'){throw 'Previous installer outcome is unknown. Review SQL Setup logs before resetting the run.'}
        $actual=@($fresh.Instances|Where-Object InstanceName -eq $instance.InstanceName)
        if($actual.Count-ne1-or$actual[0].PSObject.Properties.Name-contains'Error'){throw "SQL instance '$($instance.InstanceName)' is not query ready."}
        $actual=$actual[0]
        if($actual.IsClustered-or$actual.IsHadrEnabled-or$actual.ReplicaCount-or-not$actual.IsSysadmin){throw 'Standalone/sysadmin checks failed immediately before Apply.'}
        if([version]$actual.Version-ge[version]$instance.TargetVersion){$instance.Version=$actual.Version;continue}
        $package=@($State.Packages|Where-Object Major -eq $instance.Major)[0]
        $packagePath=Get-PropertyValue $instance RemotePackagePath "C:\SqlPatchV3Remote\Packages\$($package.Name)"
        $hash=Invoke-Command -Session $Session -ArgumentList $packagePath -ScriptBlock {param($Path);(Get-FileHash -LiteralPath $Path).Hash}
        if($hash-ne$package.Hash){throw 'Target package hash changed after preparation.'}
        if($BackupChoice-ne'0'){
            Set-ServerState $State $server 'BackingUp' "Creating system COPY_ONLY backups for $($instance.InstanceName)"
            $backup=Invoke-Command -Session $Session -ArgumentList $workerPath,$instance.InstanceName -ScriptBlock {
                param($Worker,$Instance)
                $lines=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Worker -InstanceName $Instance -BackupOnly -BackupChoice 1)
                [pscustomobject]@{Code=$LASTEXITCODE;Output=$lines-join"\n"}
            }
            if($backup.Code-ne0){throw "System backup failed: $($backup.Output)"}
        }
        Set-PropertyValue $instance InstallOutcome 'Started'
        Set-PropertyValue $Entry NeedsReboot $true
        Set-ServerState $State $server 'Patching' "Installing $($instance.InstanceName); target executes SQL Setup"
        $installed=Invoke-Command -Session $Session -ArgumentList $workerPath,$instance.InstanceName,$packagePath -ScriptBlock {
            param($Worker,$Instance,$Package)
            $mutex=New-Object Threading.Mutex($false,'Global\SqlPatchStandaloneInstall')
            $acquired=$mutex.WaitOne(0)
            if(-not$acquired){$mutex.Dispose();throw 'Another SQL patch operation is active on this Windows host.'}
            try{
                $lines=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Worker -InstanceName $Instance -BackupChoice 0 -LocalPackagePath $Package -ConfirmInstall -Restart No)
                [pscustomobject]@{Code=$LASTEXITCODE;Output=$lines-join"\n"}
            }finally{$mutex.ReleaseMutex();$mutex.Dispose()}
        }
        Set-PropertyValue $instance InstallOutcome $(if($installed.Code-eq0){'Success'}else{'Failed'})
        Save-State $State
        if($installed.Code-ne0){throw "SQL Setup failed: $($installed.Output)"}
    }
    if(Get-PropertyValue $Entry NeedsReboot $false){
        if($local){
            Set-PropertyValue $Entry BootBeforeReboot $facts.Boot
            Set-ServerState $State $server 'AwaitingControllerRestart' 'Controller SQL updated last. Restart this machine manually, then run PostVerify; remote targets are finished.'
            return
        }
        $before=Get-PropertyValue $Entry BootBeforeReboot ''
        if(-not$before-or$before-eq$facts.Boot){
            Set-PropertyValue $Entry BootBeforeReboot $facts.Boot
            Set-ServerState $State $server 'Rebooting' 'SQL Setup finished; requesting graceful restart'
            Invoke-Command -Session $Session -ScriptBlock {shutdown.exe /r /t 5 /d p:4:2 /c 'SQL patch complete';if($LASTEXITCODE-ne0){throw 'Restart request failed.'}}
        }
        Set-ServerState $State $server 'WaitingForOS' 'Waiting for a changed Windows boot time and two SQL-ready probes'
        $deadline=[datetime]::UtcNow.AddSeconds($ReadyTimeoutSeconds);$ready=0;$candidate=$null
        try{
            while([datetime]::UtcNow-lt$deadline-and$ready-lt2){
                if($candidate){Remove-PSSession $candidate;$candidate=$null}
                try{
                    $candidate=New-TargetSession $server
                    $boot=Invoke-Command -Session $candidate -ScriptBlock {(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')}
                    if($boot-eq$Entry.BootBeforeReboot){$ready=0}else{
                        $probe=Get-RemoteInventory $candidate
                        $selected=@($probe.Instances|Where-Object {$_.InstanceName-in@($Entry.Instances|ForEach-Object InstanceName)})
                        if($selected.Count-eq$Entry.Instances.Count-and-not@($selected|Where-Object {$_.PSObject.Properties.Name-contains'Error'}).Count){$ready++}else{$ready=0}
                    }
                }catch{$ready=0}
                if($ready-lt2){Start-Sleep -Seconds 10}
            }
            if($ready-lt2){throw 'Timed out waiting for confirmed reboot and SQL readiness.'}
            $final=Get-RemoteInventory $candidate
        }finally{if($candidate){Remove-PSSession $candidate}}
        Set-PropertyValue $Entry NeedsReboot $false
    }else{$final=Get-RemoteInventory $Session}
    foreach($instance in $Entry.Instances){
        $actual=@($final.Instances|Where-Object InstanceName -eq $instance.InstanceName)
        if($actual.Count-ne1-or$actual[0].PSObject.Properties.Name-contains'Error'-or[version]$actual[0].Version-lt[version]$instance.TargetVersion){throw 'SQL build validation failed.'}
        $instance.Version=$actual[0].Version
    }
    Set-ServerState $State $server 'Complete' 'Selected SQL builds verified; required remote reboot confirmed'
}
