## 3.1.6 - 2026-11-02

- Default to eight concurrent remote Apply hosts in the desktop launcher, menu and command-line engine. Additional targets queue; explicit overrides remain supported.
- Preserve three concurrent copies, controller-last/manual restart behavior, resource admission gates and fail-stop dispatch.

## 3.1.5 - 2026-11-02

- Keep controller SQL last with automatic restart disabled; refresh observed local builds and show a persistent manual-restart instruction after successful Setup.
- Retry atomic state replacement for transient Windows sharing/lock violations for up to five seconds. Persistent or unrelated errors still stop the operation; no non-atomic overwrite fallback.
- Include instance failures in host PostVerify status and display exact failure details. Allow read-only PostVerify to resume an interrupted PostVerifying stage while retaining the original campaign stage.

## 3.1.4 - 2026-11-02

- Select the highest numeric ProductVersion for each SQL major from reviewed local Microsoft EXEs. Validate all candidates and stop on invalid signatures or mismatched majors; retain older packages and report selection. Equal builds use filename order deterministically.
- Add offline installation/update instructions, an elevated menu launcher, and a desktop shortcut (all users by default, optional opt-out). The launcher defaults to serial Apply and only opens the menu.
- Include the offline guide and launchers in release ZIPs and program updates. Existing targets, packages, and run evidence are preserved.

## 3.1.3 — 2026-10-25

- ApplyConcurrency 0 (new default) runs all eligible remote hosts concurrently. Positive values provide an explicit cap; the former four-host maximum is removed.
- Controller-last order, resource gates, and failure handling remain enabled. This permits concurrent downtime across the approved scope.
- Verified overlap of six real local worker processes using simulated targets.

## 3.1.2

- Automatic selection now chooses the highest released CU-branch build, whether CU or CU + GDR, within the installed SQL major.
- Menu labels clarify CU-or-security selection; Update Catalog supports cumulative update titles as well as security titles.
- Added regression coverage for newer CUs, later security releases on older CU branches, RTM/GDR exclusion, and base-CU catalog resolution.

## 3.1.1 — 2026-10-23

- Select the latest released CU-branch security update instead of the base CU, in both V3 and the bundled V2 worker. Fail closed on missing/ambiguous metadata.
- Add commit-pinned program updater with Git blob verification, backups and rollback; preserve targets, packages and runs.
- Re-run Prepare after upgrading to replace previously selected media. No SQL installation is started by the updater.

# SQL Patch Orchestrator V3.1.0

- Bounded parallel distribution (3 hosts) and standalone Apply (2 hosts), configurable independently.
- CPU/RAM admission checks, 20 MiB/s per-stream default, progress, verified partial resume, and existing-file reuse.
- No local self-copy. Controller SQL runs last; its reboot is manual, followed by PostVerify.
- One Apply failure stops new dispatch; in-flight operations finish. Unknown installer outcomes require review.
- SQL Setup executes on targets; instances on a host remain sequential. Duplicate physical-host aliases are rejected.
- Real two-host SQL 2022 Express/Developer CU27 parallel Apply, reboot and post-verification passed on 2026-09-17. SQL 2025 already-current package skip passed. SQL 2017/2019 and production Standard/Enterprise editions were not live-patched in this run; this is not production certification.
- Existing standalone, permissions, Microsoft signature, SHA-256, and backup checks remain enabled. No Defender exclusions or security-policy bypasses are added.
- SMB/Robocopy is the default package transfer; three transfers may run concurrently. PowerShell fallback is an explicit choice.
- Option 4 always summarizes readiness per host for inventoried/prepared scopes; missing preparation is an actionable NOT READY result.
- Dashboard exposes destination paths and verified hash/time. No green success on an unverified package.
- Cross-VM SMB transfer of a 490 MB package, target SHA-256, and already-present reuse passed. This is not a WAN throughput guarantee.
- Latest-CU lookup rejects disagreement between Microsoft Download Center and build history; reviewed local media remains available.
- All menu routes are regression-tested, including system backups, cycle switching and pauses. ZIP upgrades must be extracted separately before installation.

