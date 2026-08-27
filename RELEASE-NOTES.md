# SQL Patch Orchestrator V3.0.3

- Automatically falls back to HTTPS when BITS is unavailable in a remote or non-interactive PowerShell session.
- Shows GitHub installer stages and elapsed time instead of appearing to stop after SHA-256 verification.
- Performs safe non-interactive upgrades while preserving `targets.txt`, downloaded packages, and campaign runs.
- Retains the V3.0.2 Defender behavior: no explicit custom scan, no exclusion, and no endpoint-security policy change.
- Retains release SHA-256, archive manifest, Microsoft Authenticode, SQL-version, standalone-safety, and controller-to-target hash validation.
