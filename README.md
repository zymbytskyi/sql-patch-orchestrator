# SQL Patch Orchestrator V3.1.1

## Open the menu — existing installation

Open **Windows PowerShell as Administrator** and paste this single command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\SqlPatchOrchestrator\Start-SqlPatchV3Menu.ps1" -ApplyConcurrency 1
```

This opens the interactive menu. It does not install SQL updates or restart servers. Enter the existing cycle name to continue that campaign, or a new name for a separate campaign.

The command works from any current directory. If you installed into a different folder (for example, a `SqlPatchOrchestrator-Clean-...` folder), replace `C:\SqlPatchOrchestrator` with that exact installation path. If the script is missing because the installation was removed, complete the installation section below first.

The installation bootstrap does **not** open the menu automatically. Run the command above after installation, and whenever you need to reopen the menu.

Install on one **controller** (an administration/jump server), define the approved SQL instances, prepare Microsoft updates, and apply them during the maintenance window.

Supports standalone SQL Server **2017, 2019, 2022, and 2025**, including **Express, Standard, Developer, and Enterprise** editions. WSFC, FCI, Always On, and Availability Group targets are blocked before distribution or installation.

## Contents

- [Prerequisites](#prerequisites)
- [Install on a new controller or update an existing installation](#install-on-a-new-controller-or-update-an-existing-installation)
- [Configure the target scope](#configure-the-target-scope)
- [Start the menu](#start-the-menu)
- [Prepare the latest security updates](#prepare-the-latest-security-updates)
- [Apply during the maintenance window](#apply-during-the-maintenance-window)
- [Menu reference](#menu-reference)
- [Files, evidence, and recovery](#files-evidence-and-recovery)
- [Troubleshooting](#troubleshooting)
- [Parallelism and controller protection](#parallelism-and-controller-protection)

## Prerequisites

| Requirement | Details |
|---|---|
| Controller | Windows with Windows PowerShell 5.1. Run PowerShell **as Administrator**. |
| Account | Use a domain account with local administrator and SQL sysadmin permissions on each target. The menu uses the current Windows identity. |
| Remote access | WinRM connectivity to targets. SMB/Robocopy also needs TCP 445 and access to administrative shares. |
| Internet access | Controller HTTPS access to GitHub API/raw content and Microsoft update metadata/package endpoints. Targets receive packages from the controller. |
| Capacity | Enough free space on controller and targets for update EXEs, staging, logs, and any requested backups. |
| Maintenance | Approved scope and downtime, current recoverable backups, application coordination, and a SQL recovery plan before Apply. |

No Git installation or repository clone is required on the controller. Install the orchestrator once on the controller; the remote workflow distributes its worker and packages to targets.

**Apply can restart entire remote Windows hosts.** Selecting one SQL instance does not limit the impact of a host reboot to that instance.

## Install on a new controller or update an existing installation

The same bootstrap handles both cases. It installs the reviewed **v3.1.1** program commit below, not an unreviewed moving branch. It downloads and verifies program files, preserves existing scope/media/run data, and backs up replaced program files.

For an existing installation, close all orchestrator menus and finish active operations first. Set **$destination** to the existing installation folder. The updater rejects an open menu or detected active patch process.

Open **Windows PowerShell as Administrator**, then paste:

```powershell
$ErrorActionPreference = 'Stop'
$commit = '0c4a50ca529379667053e46767d3664560a209e7'
$destination = 'C:\SqlPatchOrchestrator'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$file = Join-Path $env:TEMP "Update-SqlPatch-$([guid]::NewGuid()).ps1"
$url = "https://raw.githubusercontent.com/zymbytskyi/sql-patch-orchestrator/$commit/Update-FromGitHub.ps1"

Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $file

$expected = 'DD7BA4C7337C35BD77B08976C26BDDEBC404C810C10B1FF7FE7E73A94AC97AC4'
if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $expected) {
    throw 'Updater SHA-256 mismatch. Installation stopped.'
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file `
    -Commit $commit -Destination $destination

if ($LASTEXITCODE -ne 0) {
    throw 'Orchestrator installation/update failed. Review the error before continuing.'
}

Get-Content -LiteralPath (Join-Path $destination 'VERSION')
```

Expected result: version **3.1.1**, the installed commit, and a **ProgramBackups** path. No SQL installation or reboot starts here.

- **New installation:** creates program files, Packages, Runs, and a comment-only targets.txt. Add your approved targets next.
- **Existing installation:** keeps targets.txt, Packages, and Runs. Program files are backed up before replacement.
- If file replacement or verification fails, the updater attempts to restore the previous program files and reports the error.
- The old v3.1.0 release installer still installs v3.1.0. Use the bootstrap above for this version.
- The commit and SHA-256 form a matched pair. Do not change just one. A future program release needs its own reviewed commit and updater hash.
- This pinned commit predates this expanded README; the current GitHub README is the installation guide.

After updating an existing campaign, rerun **Inventory** and **Prepare with source 2**. Updating program files alone does not replace packages already selected in saved run state.

## Configure the target scope

Open the installed target list:

```powershell
notepad.exe 'C:\SqlPatchOrchestrator\targets.txt'
```

Save one approved target per line. Empty lines and lines starting with # are ignored.

| Entry | Scope |
|---|---|
| SQLHOST01\MSSQLSERVER | Default instance only |
| SQLHOST02\APPDB | Named instance APPDB only |
| SQLHOST03 | All discovered SQL instances on this host |

**A bare hostname does not mean default instance only.** Use an explicit instance name when the approved scope is limited.

Example contents (replace these example names with your real targets):

```text
# Approved instances for this campaign
SQLHOST01\MSSQLSERVER
SQLHOST02\APPDB
```

Do not include Markdown table pipes, duplicate entries, or both a bare hostname and named-instance entries for the same host. Instance names are identifiers: a name containing “2016” does not establish the actual SQL Server version. Inventory determines the engine version and edition.

For a different group of servers, save the new target list and create a **separate cycle**. Cycle state is separate, but targets.txt is shared by this installation: switching cycles does not restore an older target list automatically. Restore the matching approved scope before resuming an older cycle. Do not change scope during an active operation or run overlapping campaigns against the same hosts.

## Start the menu

Run from an elevated Windows PowerShell window:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File 'C:\SqlPatchOrchestrator\Start-SqlPatchV3Menu.ps1' `
    -ApplyConcurrency 1
```

Change the path if you installed elsewhere. This command starts the menu; it does not start SQL installation.

Enter a descriptive cycle name, for example **Production Standard October 2026**. Use the same name to resume that campaign. Pressing Enter uses the suggested month. Separate groups should have separate cycle names. This launch command explicitly limits Apply to **one host at a time**; the script's default when omitted is two.

## Prepare the latest security updates

Preparation can be completed before the approved downtime window.

1. **Option 1 — Open target list:** confirm the saved scope.
2. **Option 2 — Inventory:** inspect actual instances, editions, versions, standalone checks, and backup evidence. All scoped targets must pass before Prepare.
   - At the backup prompt, **0** (default) creates no new backup.
   - **1** creates COPY_ONLY + CHECKSUM backups of master, model, and msdb on selected instances, followed by RESTORE VERIFYONLY. This is a write operation and consumes disk space. It excludes tempdb and user databases.
   - Backup warnings are informational. They do not prove that recovery prerequisites are satisfied.
3. **Option 3 — Choose/download updates:** at the package-source prompt, explicitly choose **2 — Download latest CU-branch security updates from Microsoft automatically**.
   - Pressing Enter chooses **1 — Use reviewed EXEs already in Packages**. It does **not** request a fresh automatic selection.
   - At the transfer prompt, choose **1 — SMB/Robocopy** (default), or explicitly choose **2 — PowerShell** if that transport is required.
   - Wait for download, package verification, distribution, and target hash verification to finish. This phase does not install SQL updates.
4. **Option 4 — Check readiness:** review every host, resolve failures, and rerun the check.
5. **Option 7 — Status/dashboard:** review full current and target builds, selected KB/package, signature/hash results, backup evidence, and any blocked or failed state.

**Automatic download shortcut: 2 → 3 → source 2 → transfer 1 → 4 → 7.**

Automatic selection targets the latest released **CU + GDR security update** for each SQL major. It is not a selector for the latest base CU or the RTM/GDR-only branch. The selection and verification rules are described below.

Inventory and other remote phases may add a specific target to the controller's WinRM TrustedHosts after a matching implicit-credentials error. Existing entries are preserved, the change is logged, and the connection is retried once. An actual “Access is denied” is not fixed this way. Domain policy may require administrator intervention.

## Apply during the maintenance window

Before continuing, confirm scope, readiness, backups and recovery plan, approved downtime, application coordination, and the selected update's known issues.

1. Choose **5 — Apply**.
2. Type **5** again at the confirmation prompt.
3. Select backup choice **0** (none) or **1** (system databases) according to the approved plan.
4. Monitor status. Successfully patched remote hosts are restarted. Other services on those hosts are affected.
5. If the controller is also a target, it runs last and requires a **manual controller restart** when the state says AwaitingControllerRestart.
6. After hosts return, run **6 — Post-patch verification**, then **7 — Status/dashboard**. Inspect instance-level results and errors as well as the overall stage.
7. Perform application/service checks with the relevant owners before closing the maintenance change.

An interrupted or unknown SQL Setup result requires investigation before retrying. Do not blindly repeat Apply. An Apply failure stops new dispatch; already active target operations finish.

## Menu reference

| Option | Action | Operational effect |
|---|---|---|
| 0 | Exit | Closes the menu |
| 1 | Open target list | Opens targets.txt for editing |
| 2 | Inventory and backup review | Queries targets; optional system backups write files |
| 3 | Prepare | Downloads/reuses and distributes files; no SQL installation |
| 4 | Readiness | Checks prepared targets and updates local evidence |
| 5 | Apply | Installs updates and restarts successfully patched remote hosts |
| 6 | PostVerify | Checks SQL after patching and records results |
| 7 | Dashboard | Shows saved status and opens the HTML report |
| 8 | Select/create cycle | Switches run state; does not restore a different targets.txt |

## Files, evidence, and recovery

| Location under the installation folder | Purpose |
|---|---|
| targets.txt | Current approved target list |
| Packages | Downloaded or DBA-supplied Microsoft update EXEs |
| Runs | Per-cycle state, reports, logs, and worker evidence |
| Runs/<cycle-folder>/state.json | Campaign state; folder name may be hashed |
| Runs/<cycle-folder>/Dashboard.html | HTML status report; option 7 opens it |
| Runs/<cycle-folder>/winrm-client-changes.jsonl | Recorded TrustedHosts changes, when applicable |
| ProgramBackups | Previous program files saved by the updater |

Cycle names are retained in the state and menu. Many cycle names use a hashed folder name; use option 7 to find the correct report instead of guessing the directory.

For a regression in the **orchestrator program update**, close menus and finish active operations, then restore backed-up program files from the updater's printed ProgramBackups directory to their original relative paths. Preserve targets, packages, and run evidence. Revalidate Inventory/Prepare before continuing.

This program-file recovery does **not** uninstall SQL updates or restore databases. SQL rollback/recovery is a separate operation requiring an approved, update-specific recovery plan.

Do not commit customer targets, update EXEs, backups, credentials, or run logs to this public repository.

## Troubleshooting

| Symptom | Next action |
|---|---|
| Git is not recognized | Git is not required. Use the installation bootstrap above. |
| Script execution is blocked | Use the documented powershell.exe launch command with process-scoped ExecutionPolicy Bypass. Domain policy may still require administrator action. |
| Updater says a menu/operation is active | Finish the operation and close its menu, then rerun the updater. |
| GitHub download, API, or hash check fails | Stop; check HTTPS/proxy access and GitHub rate limits. Keep the commit/hash pair unchanged. |
| Inventory blocks preparation | Read the listed host/instance reason, correct scope/access/standalone issues, and rerun option 2. |
| Wrong or missing instance | Check targets.txt. Use SERVER\MSSQLSERVER for default-only scope; verify named instances using Inventory. |
| Old update is still selected | Rerun Inventory, then option 3 and explicitly choose source 2. Existing prepared state is not refreshed by updating scripts. |
| Download Center warning | The resolver tries Microsoft Update Catalog. Continue only if exact KB/file resolution and package checks succeed. |
| Microsoft metadata cannot be verified | Preparation stops. Check connectivity and published metadata; do not bypass signature or build checks. |
| SMB copy fails | Check TCP 445, admin shares, permissions, capacity, and copy logs. Choose PowerShell transfer explicitly if approved. |
| Readiness fails | Inspect option 7 and logs, resolve the reported cause, then rerun option 4. |
| Apply is interrupted or fails | Preserve state and SQL Setup logs; establish the actual outcome before deciding whether to resume. |


## Parallelism and controller protection

Defaults: **3 concurrent copies**, **2 concurrent target hosts in Apply**, and a **requested 20 MiB/s per-stream I/O limit**. SMB uses Robocopy /IORATE when available; older versions use /IPG pacing, which is not a strict bandwidth cap. Instances on one Windows host are patched sequentially; aliases resolving to the same host are rejected. This workflow supports standalone SQL only; it is not a parallel AG/cluster patcher.

```powershell
# Lower limits for a busy SQL/jump server or a slow shared WAN link:
.\Start-SqlPatchV3Menu.ps1 -CopyConcurrency 2 -ApplyConcurrency 1 -CopyLimitMBps 10
```

- New work waits when controller CPU is at least 75% or available RAM is below 2 GiB. After five minutes, queued work is deferred. Already running SQL Setup is never killed to reduce load. These are admission checks, not reserved resources or a guarantee against load spikes.
- Installers execute on targets. The controller holds only bounded transfer chunks and worker processes. Final SHA-256 verification reads each whole file; verification time remains visible and cannot safely be skipped.
- SMB copies run on the controller using the current Windows account and TCP 445/admin-share access. No shares, firewall exceptions, credentials, or signing/encryption policies are changed. PowerShell Direct lab transport uses the PowerShell transfer path. SMB failure never silently falls back.
- Matching packages are reused. Robocopy uses restartable staging (/Z), bounded retries, and /J. PowerShell fallback verifies partial prefixes before byte-offset resume. Transfers show transport, progress and elapsed time; per-transfer Robocopy logs are saved under the worker run's TransferLogs. Final target SHA-256 must match before the package is promoted out of staging. Failed copies do not stop unrelated preparation.
- When the controller is itself a target, its original local package and worker paths are reused: no self-copy. Its SQL is patched after remote targets finish. The run stays `AwaitingControllerRestart`; restart the controller manually and run menu **6** (PostVerify).
- An Apply failure stops new dispatch; already active targets finish. Interrupted/unknown installer outcomes require manual review, not a blind retry. Do not run separate campaigns/controllers against overlapping targets.
- Prepare and Apply write isolated worker state; only the parent updates the main state/dashboard. A cycle lock prevents two menu operations modifying the same run simultaneously.

Concurrent Apply means concurrent downtime on independent targets. Start with `ApplyConcurrency 1` if application dependencies require serial maintenance. Distribution limits do not change SQL/backup/signature/standalone safety checks. On 2026-09-17, real parallel SQL 2022 Express/Developer CU27 installation, remote reboots, and post-verification passed on two lab hosts. SQL 2025 was verified as an already-current selected package and was not reinstalled. SQL 2017/2019 and Standard/Enterprise production editions were not live-patched in this acceptance run; validate your own environment before production.

Automatic selection reads Microsoft's complete build history and chooses the newest released **CU + GDR security update** for each SQL major, ordered by release date then build. Pure RTM/GDR and base CU rows are excluded. It verifies the KB/build pairing, follows that KB's Microsoft Download Center link or resolves the exact CU package through Microsoft Update Catalog, and selects only the exact Microsoft EXE. Missing or conflicting metadata stops preparation; there is no silent base-CU fallback. Microsoft signature, package build and transfer SHA-256 checks remain required. This mode targets the CU servicing branch; review applicability before changing a GDR-only baseline. A newer base CU is not selected by this security-only mode. Instances already above the selected security build are not downgraded.

As of 2026-10-23, SQL 2022 resolves to KB5126934 / 16.0.4305.5 and SQL 2019 to KB5128494 / 15.0.4500.2. These are examples, not hardcoded selections. Review each update's known issues before approving Apply.

The dashboard shows the target folder, full file path, transfer method, SHA-256 and verification UTC. Media is green only after a matching hash, never merely because a file exists. A readiness check clears prior verification before rechecking. Update scripts on the controller to use these changes; an installed 3.0.8 menu does not gain them automatically.


