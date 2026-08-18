# SQL Patch V2 Local

Status: tested. V1 remains frozen separately in `tools\SqlExpressSelfPatch`.

V2 runs locally in Windows PowerShell 5.1 as Administrator. It supports SQL
Server 2017, 2019, 2022, and 2025 Database Engine instances whose edition is
Express, Standard, SQL Server 2025 Standard Developer, or Developer. Developer
support exists for safe non-production validation with Microsoft evaluation
media; the requested production targets remain Express and Standard.

```powershell
cd C:\SqlPatchV2Local
.\Invoke-SqlPatchV2Local.ps1
```

Before backup or download, V2 blocks the run when it finds an FCI, Windows
failover-cluster configuration/service, Always On enablement, or Availability
Group replica metadata. Clustered/AG patching belongs to a later dedicated
workflow and is never attempted by V2.

The remaining flow matches tested V1: report backup dates; optionally create
verified COPY_ONLY system-only or all-database backups; select the latest
major-version-specific CU from Microsoft Download Center or another local
Microsoft-signed package; patch only the selected instance; choose whether to
restart; then rerun the same script manually to verify.

Read-only preflight:

```powershell
.\Invoke-SqlPatchV2Local.ps1 -CheckOnly
```

The normal DBA experience remains interactive. Optional parameters
`-InstanceName`, `-BackupOnly`, `-BackupChoice`, `-LocalPackagePath`,
`-ConfirmInstall`, and `-Restart` exist
for controlled repeatable testing and later orchestration; they do not bypass
the standalone, edition, sysadmin, filename, or Microsoft-signature gates.

Lab acceptance completed on 2026-08-12: SQL Server 2022 moved from RTM to
CU24 build `16.0.4245.2`, and SQL Server 2025 moved from RTM to CU4 build
`17.0.4035.5`. Eight all-database backups and a separate three-system-database
BackupOnly run passed `RESTORE VERIFYONLY WITH CHECKSUM`. `SQL01` proved the
WSFC/Always On blocker before target-folder or media creation.
