# Next steps

- v3.1.4 adds local highest-build selection and offline installation with desktop launchers. Use the release ZIP; the README labels the historical v3.1.3 online bootstrap. Qualify certificate trust in each isolated environment; numeric highest-build selection does not establish servicing-branch suitability.

- Local elevated menu option 5 acceptance with WinRM stopped passed on 2026-10-28 for SQL2025 Enterprise Developer CU10, including backup, installation, manual reboot, database validation and PostVerify. Extend live coverage to workgroup HTTP/HTTPS, non-built-in local administrators/UAC, other editions and remote staging before claiming those paths are qualified.

- Completed two-target SQL 2022 Express/Developer CU27 parallel Apply/reboot/post-verification acceptance on 2026-09-17. Extend live installation coverage to SQL 2017/2019/2025 and production Standard/Enterprise editions before claiming that matrix is tested.
- Confirm controller admission thresholds and network limits against actual jump-server SQL workload.
- Keep runtime evidence outside Git. Never run overlapping campaigns against the same targets.
- Clustered, FCI, Always On, and Availability Group orchestration remains outside the V3 standalone boundary.

- Cross-VM SMB/hash/reuse acceptance passed (490 MB, approximately 116 seconds including verification). Benchmark each customer WAN separately; configured pacing is not guaranteed throughput.
- Microsoft Download Center and build history can disagree. Automatic latest selection now blocks this case; use explicitly reviewed local media or retry after Microsoft sources converge.
- v3.1.4 validation passed: repository checks, full regression suite, real temporary offline install/upgrade and shortcut inspection, ZIP manifest/tamper rejection, and signature/version/hash validation of existing SQL 2022/2025 Microsoft media. Multiple-build ranking used controlled fixtures; no new SQL Apply was performed for this release.

- v3.1.5: controller manual-restart guidance, bounded state-file lock retries and consistent PostVerify aggregation. Preserve fail-stop behavior for remote Apply failures and unknown installer outcomes.
- v3.1.5 validation passed: full repository suite, real transient/persistent Windows file locks, actual PostVerify engine with SQL fixtures, controller no-reboot/build refresh fixtures, and installation from the release ZIP. No live SQL Apply was performed for this revision.
- v3.1.6 sets the requested default Apply cap to eight remote hosts; monitor real controller capacity and concurrent application downtime as the target list grows.
- v3.1.6 validation passed: full regression suite and offline ZIP installation; ten simulated remote targets reached an observed peak of eight real worker processes, with controller execution last. No SQL installation was run.
