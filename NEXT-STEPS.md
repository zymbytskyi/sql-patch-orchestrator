# Next steps

- Validate local elevated execution with WinRM disabled and remote workgroup HTTP/HTTPS access on disposable Windows servers, including media staging, SQL permissions, and manual controller restart. Automated transport tests do not establish live server acceptance.

- Completed two-target SQL 2022 Express/Developer CU27 parallel Apply/reboot/post-verification acceptance on 2026-09-17. Extend live installation coverage to SQL 2017/2019/2025 and production Standard/Enterprise editions before claiming that matrix is tested.
- Confirm controller admission thresholds and network limits against actual jump-server SQL workload.
- Keep runtime evidence outside Git. Never run overlapping campaigns against the same targets.
- Clustered, FCI, Always On, and Availability Group orchestration remains outside the V3 standalone boundary.

- Cross-VM SMB/hash/reuse acceptance passed (490 MB, approximately 116 seconds including verification). Benchmark each customer WAN separately; configured pacing is not guaranteed throughput.
- Microsoft Download Center and build history can disagree. Automatic latest selection now blocks this case; use explicitly reviewed local media or retry after Microsoft sources converge.
