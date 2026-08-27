# SQL Patch Orchestrator V3.0.5

- Accepts any free-form cycle label without a date format or language requirement.
- Keeps the exact DBA label in menu, state, console, dashboard, and `cycle-name.txt`.
- Uses an internal SHA-256-derived directory key for arbitrary labels, preventing path traversal without restricting the operator's wording.
- Reads its UTF-8 runtime files explicitly so multilingual labels remain intact on Windows PowerShell 5.1.
- Preserves existing `MonthYYYY` runtime directories and all V3.0.4/V3.0.3 fixes.
- Retains all media, standalone-safety, backup, hash, signature, and endpoint-security boundaries.
