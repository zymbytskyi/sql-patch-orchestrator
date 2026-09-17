# SQL Patch Orchestrator V3.0.8

- Fixes the unhandled WinRM error "Default credentials with Negotiate over HTTP" in every remote phase.
- Adds only the affected approved target to controller TrustedHosts, preserving existing entries and recording the previous value.
- Verifies effective settings and retries once with the same identity; Group Policy and target permission failures remain actionable blockers.
- Removes the 12-server limit and reduces repeated backup output during inventory.
- Displays the installed version; fresh ZIP installations include the GitHub updater.
- Retains all media, standalone-safety, backup, hash, signature, and endpoint-security boundaries.
