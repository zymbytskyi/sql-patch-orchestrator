# SQL Patch Orchestrator V3.0.2

- Removes all explicit `Start-MpScan` custom scans that could block installation, preparation, or target-side Apply.
- Does not disable Microsoft Defender, create exclusions, or change Azure/Microsoft Defender for Endpoint policy.
- Retains GitHub release SHA-256 verification, archive manifest verification, Microsoft Authenticode validation, SQL major-version validation, and controller-to-target hash verification.
- Aligns the target worker with the controller's standalone Enterprise edition support.
- Includes all V3.0.1 monthly cycle, inventory gate, system backup, time-zone, and evidence fixes.
