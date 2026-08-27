# SQL Patch Orchestrator V3.0.7

- Detects WinRM `Access is denied` during inventory and sets controller-side `TrustedHosts = *`.
- Retries inventory with the same current Windows account and never requests another password.
- Displays the account used for remote operations.
- Preserves all V3.0.6 and V3.0.5 behavior except the alternate-credential prompt.
- Retains all media, standalone-safety, backup, hash, signature, and endpoint-security boundaries.
