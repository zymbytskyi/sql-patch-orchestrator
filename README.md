# SQL Patch Orchestrator V3

PowerShell 5.1 controller for sequential remote patching of standalone SQL Server 2017, 2019, 2022, and 2025 instances. Express, Standard, Developer, and Enterprise editions are supported. WSFC, FCI, Always On, and Availability Group targets are blocked before distribution or installation.

## Install with one PowerShell command

Run Windows PowerShell as Administrator:

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$p=Join-Path $env:TEMP 'Install-SqlPatchOrchestrator-3.0.8.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/zymbytskyi/sql-patch-orchestrator/v3.0.8/Install-FromGitHub.ps1' -UseBasicParsing -OutFile $p
if((Get-FileHash $p -Algorithm SHA256).Hash-ne'861FCCA3DF6808366C90ED3A78D1F6642B83DC7A80B1A4B939DB3160ABF5156F'){throw 'Bootstrap SHA-256 mismatch.'}
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p -Version 3.0.8
```

The installer verifies the GitHub release SHA-256 digest and installs to `C:\SqlPatchOrchestrator`. V3.0.8 does not start a blocking Microsoft Defender custom scan. It does not disable Defender, create exclusions, or change endpoint security policy. Existing targets, packages, and runs are preserved during a non-interactive upgrade.

## Install from ZIP

Download `SqlPatchOrchestrator-v3.0.8.zip` from [Releases](https://github.com/zymbytskyi/sql-patch-orchestrator/releases/tag/v3.0.8), extract it to `C:\`, then run `C:\SqlPatchOrchestrator\Install.cmd` as administrator. The archive already contains the correct top-level folder.

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
3. Download the latest required Microsoft CUs or use DBA-supplied EXEs, validate them, and distribute them without installation.
4. Run final read-only preflight.
5. Apply sequentially and reboot each successfully patched remote server.
6. Run post-verification.
7. View console status and the HTML dashboard.
8. Switch to another monthly patch cycle.

Preparation never starts from `InventoryBlocked`. Every remote phase uses the same connection handler. If WinRM reports a TrustedHosts/implicit-credentials policy error, the engine adds only that approved target to the controller's TrustedHosts, preserves existing entries (including `*`), verifies the effective value, and retries that connection once with the same Windows identity. Controller changes are recorded in `Runs/<cycle>/winrm-client-changes.jsonl`. Run Windows PowerShell as Administrator; domain Group Policy may require an administrator to configure the setting centrally. An actual target `Access is denied` is reported as a permissions issue, not retried by changing trust.

Run from a domain account with local administrator and SQL sysadmin rights on every target. WinRM must be enabled between the controller and targets. V3 never scans the domain and never uses forced failover or data-loss operations.

Do not store update EXEs, backups, credentials, logs, or `Runs` data in Git.

The scope has no fixed 12-server limit. Inventory visits every listed server and reports all failures; preparation remains blocked until the entire approved scope passes. Backup history warnings remain informational. During inventory the console shows compact progress; the final review and dashboard include full backup details.

For remote, multi-server patching use this repository. The separate [SQL Server 2022 Express Self-Patch](https://github.com/zymbytskyi/sql-server-2022-express-self-patch) package is for local Express only.
