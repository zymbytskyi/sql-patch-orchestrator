# SQL Patch Orchestrator V3.1.1

PowerShell 5.1 controller for bounded-parallel remote patching of standalone SQL Server 2017, 2019, 2022, and 2025 instances. Express, Standard, Developer, and Enterprise editions are supported. WSFC, FCI, Always On, and Availability Group targets are blocked before distribution or installation.

## Update to v3.1.1 from GitHub

Use `Update-FromGitHub.ps1 -Commit <reviewed-full-commit-SHA>` from Windows PowerShell 5.1 as Administrator, after closing the patch menu and finishing any active operation. The updater downloads an immutable commit, verifies each program file against its Git blob hash, backs up replaced program files and preserves targets.txt, Packages and Runs. It does not install SQL updates or reboot hosts. It rolls program files back if replacement or verification fails.

After updating, reopen the menu, run Inventory, then choose option 3 and source 2 to resolve and distribute the latest CU-branch security updates. Existing prepared cycles keep their old selected media until Prepare is rerun. Inspect the selected KB and full target build, run Readiness, then approve Apply separately.

The earlier v3.1.0 release installer still installs v3.1.0. Use the commit-pinned updater for this change; no v3.1.1 ZIP release is implied.

## Use

Run:

```powershell
cd C:\SqlPatchOrchestrator
.\Start-SqlPatchV3Menu.ps1
```

At startup, enter any descriptive cycle name, such as `September production`, `Emergency KB123`, or `Migration test`. There is no naming format or language requirement; press Enter to use the suggested current month. The exact label is shown in the menu, state, console, and dashboard. A deterministic internal storage key keeps arbitrary labels from becoming unsafe filesystem paths. Each cycle has separate data under `Runs`.

Menu workflow:

1. Add targets to `targets.txt`: `SERVER`, `SERVER\MSSQLSERVER`, or `SERVER\INSTANCE`.
2. Inventory and review backup evidence. If inventory passes, optionally create new `COPY_ONLY, CHECKSUM` backups of `master`, `model`, and `msdb`; each file is checked by `RESTORE VERIFYONLY WITH CHECKSUM`. `tempdb` and user databases are excluded.
3. Download the latest required Microsoft CU-branch security updates or use DBA-supplied EXEs. Choose SMB/Robocopy (default) or the explicit slower PowerShell fallback; distribute to up to 3 hosts without installation.
4. Check readiness: one READY / NOT READY line per host. Before preparation, it explains that option 3 is required. Details are in the dashboard; a failed host does not stop checks on others.
5. Apply with bounded parallelism and reboot successfully patched remote servers. Controller SQL runs last and requires a manual controller restart.
6. Run post-verification.
7. View console status and the HTML dashboard.
8. Switch to another monthly patch cycle.

Preparation never starts from `InventoryBlocked`. Every remote phase uses the same connection handler. If WinRM reports a TrustedHosts/implicit-credentials policy error, the engine adds only that approved target to the controller's TrustedHosts, preserves existing entries (including `*`), verifies the effective value, and retries that connection once with the same Windows identity. Controller changes are recorded in `Runs/<cycle>/winrm-client-changes.jsonl`. Run Windows PowerShell as Administrator; domain Group Policy may require an administrator to configure the setting centrally. An actual target `Access is denied` is reported as a permissions issue, not retried by changing trust.

Run from a domain account with local administrator and SQL sysadmin rights on every target. WinRM must be enabled between the controller and targets. V3 never scans the domain and never uses forced failover or data-loss operations.

Do not store update EXEs, backups, credentials, logs, or `Runs` data in Git.

The scope has no fixed 12-server limit. Inventory visits every listed server and reports all failures; preparation remains blocked until the entire approved scope passes. Backup history warnings remain informational. During inventory the console shows compact progress; the final review and dashboard include full backup details.

For remote, multi-server patching use this repository. The separate [SQL Server 2022 Express Self-Patch](https://github.com/zymbytskyi/sql-server-2022-express-self-patch) package is for local Express only.

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


