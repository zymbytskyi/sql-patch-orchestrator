# Offline installation and patching (v3.1.6)

Supports standalone SQL Server 2017 and later, not AG/FCI.
Use Windows PowerShell 5.1 as Administrator with SQL sysadmin access.
Git and internet downloads are not required for offline installation.
Microsoft update EXEs are not included in the ZIP.

## Transfer and install

Download SqlPatchOrchestrator-v3.1.6.zip and its SHA-256 file from the
[v3.1.6 release](https://github.com/zymbytskyi/sql-patch-orchestrator/releases/tag/v3.1.6).
Separately obtain approved Microsoft update EXEs for the installed SQL versions
and servicing branches. Transfer these files into the isolated environment.

Compare the archive hash with the release checksum:

    Get-FileHash 'C:\Staging\SqlPatchOrchestrator-v3.1.6.zip' -Algorithm SHA256

Extract into a fresh staging folder, not over the installed program:

    Expand-Archive 'C:\Staging\SqlPatchOrchestrator-v3.1.6.zip' 'C:\Staging\v3.1.6'

Double-click C:\Staging\v3.1.6\SqlPatchOrchestrator\Install.cmd and accept UAC,
or run this in elevated Windows PowerShell:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Staging\v3.1.6\SqlPatchOrchestrator\Install-SqlPatchOrchestrator.ps1"

Default destination: C:\SqlPatchOrchestrator. The installer verifies the
included file manifest and creates **SQL Patch Orchestrator** on the public
desktop (visible to all users). It does not install SQL updates or open the menu.

For a different destination, add -Destination "D:\Tools\SqlPatchOrchestrator".
To skip the shortcut, add -NoDesktopShortcut. To use another existing desktop
folder, add -DesktopDirectory "D:\YourDesktop".
If shortcut creation fails, installation reports a warning; use the launcher
inside the installation folder.

## Upgrade an existing installation

Finish active patch operations and close all patch menus before replacement.
Preserve a copy of the existing program files for rollback.
Run the new staged installer with the same destination and confirm replacement.
It preserves existing targets.txt, Packages and Runs. Do not extract the
archive directly over these folders.

Check C:\SqlPatchOrchestrator\VERSION: it must say **3.1.6**.
For a campaign not yet applied, repeat Inventory, Prepare (source 1) and Readiness.
Existing campaign state does not automatically select a newly added EXE.
For an interrupted Apply/PostVerify, preserve Runs and use the original cycle
name with option 6 first. Do not reset an in-flight campaign with Inventory.
If remote targets verify successfully and only the controller remains below
target, review prior Setup outcomes before resuming option 5 in that same cycle.
Unknown outcomes remain blocked and require investigation.

## Add update files and targets

Copy original Microsoft EXEs directly into:

    C:\SqlPatchOrchestrator\Packages\

Keep original filenames, for example SQLServer2022-KB<number>-x64.exe.
Do not extract them or place them in subfolders.
Multiple releases may remain. For each SQL major in inventory, Prepare validates
every matching candidate and chooses the highest numeric ProductVersion,
not the newest timestamp or largest KB number. It reports the chosen and
unselected files. Equal builds use filename order.
Invalid signatures, malformed versions or mismatched SQL majors block Prepare;
there is no silent fallback. All candidates must be reviewed media.
Highest build does not establish servicing-branch suitability; review the
selected KB/build before Apply.

Edit C:\SqlPatchOrchestrator\targets.txt, one approved instance per line:

    YOURSERVER\MSSQLSERVER
    YOURSERVER\APPDB

Replace examples with real names. MSSQLSERVER means the default instance.
A bare hostname selects **all** discovered instances on that host.

## Open the menu

**With shortcut:** double-click SQL Patch Orchestrator, accept UAC and enter
the cycle name, for example Offline November 2026. Enter the same name after
restarting. The shortcut opens the menu only and defaults to up to eight remote hosts in parallel.

**Without shortcut:** double-click C:\SqlPatchOrchestrator\Start-SqlPatch.cmd.
This uses the same elevated launcher.

**From an elevated console**, with a fixed cycle name:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\SqlPatchOrchestrator\Start-SqlPatchV3Menu.ps1" -Cycle "Offline November 2026" -ApplyConcurrency 8

Domain execution policies may require approved script signing; the launcher
does not override centrally enforced policies.

## Prepare, apply and verify

1. **2 - Inventory:** review exact instances and recovery evidence. Optional
   backup choice 1 creates and verifies COPY_ONLY/CHECKSUM backups of
   master/model/msdb only. Arrange user-database backups separately.
2. **3 - Prepare**, then **source 1** (EXEs already in Packages). Do not choose
   source 2 offline. Choose SMB or PowerShell for remote distribution according
   to existing access. This does not install updates.
3. **4 - Readiness:** resolve all blockers.
4. **7 - Dashboard:** review selected KB, target build and verified hashes.
5. **5 - Apply**, confirm 5 again, review the backup choice. Start only in the
   approved downtime window with recovery backups ready. Remote hosts may
   reboot, affecting other applications.
6. Local controller patching waits for a **manual restart**. Restart when
   requested, wait for SQL services to start, reopen the same cycle and select
   **6 - PostVerify**, then **7 - Dashboard**.

Evidence stays under Runs; preserve it. Do not start overlapping campaigns.

## Offline access and troubleshooting

Local execution needs no WinRM. Remote execution requires configured WinRM and
administrator/SQL permissions; SMB also requires TCP 445/admin shares.
For workgroup HTTPS credentials, see the README. Installation does not configure
remote access or firewall rules.

Prepare may try Microsoft Learn for descriptive release metadata (up to
30 seconds per uncached package). Failure shows release date/age as Unknown;
local selection remains possible. Microsoft Authenticode signature validation
is still required. If isolated certificate trust cannot validate the EXE,
resolve trusted roots/revocation infrastructure; do not bypass the gate.

- No package found: check SQL year, original filename and direct placement.
- Invalid candidate: inspect the reported EXE; retain trusted, applicable media.
- Old dashboard selection: rerun Inventory, Prepare/source 1 and Readiness.

## Controller installation and interrupted verification (v3.1.6)

The controller is patched after remote targets succeed. SQL services stop during
installation, but the tool never automatically reboots the controller. After
SQL Setup completes, the menu displays AwaitingControllerRestart. Restart Windows
manually, reopen the same cycle and run option 6. A failed remote operation can
defer controller patching; do not treat Deferred as an installed update.

If PostVerify was interrupted, option 6 can safely repeat its read-only checks.
An instance below its target build now makes the host PostVerifyFailed and its
exact reason appears in the dashboard. PostVerify does not install missing updates.
Transient state-file locks are retried for five seconds. Persistent file locks
still require diagnosis; do not delete state or blindly repeat Apply.
