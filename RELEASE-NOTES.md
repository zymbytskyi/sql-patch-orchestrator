# SQL Patch Orchestrator V3.0.6

- Detects WinRM `Access is denied` during inventory and offers one interactive retry with another domain account.
- Keeps the entered credential only in the running menu process and reuses it for preparation, preflight, apply, reboot, and post-verification.
- Displays the account used for remote operations without exposing its password.
- Preserves all V3.0.5 free-form cycle-name behavior.
- Retains all media, standalone-safety, backup, hash, signature, and endpoint-security boundaries.
