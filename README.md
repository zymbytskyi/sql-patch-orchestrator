# SQL Patch Orchestrator V3

PowerShell 5.1 controller for sequential remote patching of standalone SQL Server 2017, 2019, 2022, and 2025 instances. Express, Standard, Developer, and Enterprise editions are supported. WSFC, FCI, Always On, and Availability Group targets are blocked before distribution or installation.

## Install with one PowerShell command

Run Windows PowerShell as Administrator:

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$p=Join-Path $env:TEMP 'Install-SqlPatchOrchestrator-3.0.1.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/zymbytskyi/sql-patch-orchestrator/v3.0.1/Install-FromGitHub.ps1' -UseBasicParsing -OutFile $p
if((Get-FileHash $p -Algorithm SHA256).Hash-ne'647B114946F6B30DCA10AD9BBF99F48B63A0C4FB279E582DDA56CD2BBDC37E92'){throw 'Bootstrap SHA-256 mismatch.'}
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p -Version 3.0.1
```

The installer verifies the GitHub release SHA-256 digest, requests a Microsoft Defender scan when available, and installs to `C:\SqlPatchOrchestrator`.

## Install from ZIP

Download `SqlPatchOrchestrator-v3.0.1.zip` from [Releases](https://github.com/zymbytskyi/sql-patch-orchestrator/releases/tag/v3.0.1), extract it to `C:\`, then run `C:\SqlPatchOrchestrator\Install.cmd` as administrator. The archive already contains the correct top-level folder.

## Use

Run:

```powershell
cd C:\SqlPatchOrchestrator
.\Start-SqlPatchV3Menu.ps1
```

At startup, enter the monthly patch cycle in `MonthYYYY` format, such as `September2026`. Press Enter to use the current month. Each cycle has separate state and dashboard data under `Runs`.

Menu workflow:

1. Add targets to `targets.txt`: `SERVER`, `SERVER\MSSQLSERVER`, or `SERVER\INSTANCE`.
2. Inventory and review backup evidence. If inventory passes, optionally create new `COPY_ONLY, CHECKSUM` backups of `master`, `model`, and `msdb`; each file is checked by `RESTORE VERIFYONLY WITH CHECKSUM`. `tempdb` and user databases are excluded.
3. Download the latest required Microsoft CUs or use DBA-supplied EXEs, validate them, and distribute them without installation.
4. Run final read-only preflight.
5. Apply sequentially and reboot each successfully patched remote server.
6. Run post-verification.
7. View console status and the HTML dashboard.
8. Switch to another monthly patch cycle.

Preparation never starts from `InventoryBlocked`. The menu prints each blocked server and reason and asks the DBA to correct the issue and rerun inventory instead of starting a download.

Run from a domain account with local administrator and SQL sysadmin rights on every target. WinRM must be enabled between the controller and targets. V3 never scans the domain and never uses forced failover or data-loss operations.

Do not store update EXEs, backups, credentials, logs, or `Runs` data in Git.
