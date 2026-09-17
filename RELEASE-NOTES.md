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
