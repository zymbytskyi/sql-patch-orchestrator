# SQL Patch Orchestrator V3.0.1

- Prompts for a validated monthly patch cycle at startup and allows switching cycles from menu option 8.
- Makes menu option 2 explicitly offer verified `COPY_ONLY, CHECKSUM` backups of `master`, `model`, and `msdb` only.
- Requires all three system databases to be ONLINE and successfully verified; `tempdb` and user databases remain excluded.
- Uses the SQL 2017 registry fallback when `InstanceDefaultBackupPath` is unavailable.
- Reports backup type, checksum status, and path, while calculating backup age on each target to avoid time-zone errors.
- Prevents option 3 from downloading or distributing media while inventory is blocked and prints the exact server reasons.
- Accepts standalone Enterprise edition while retaining the WSFC, FCI, Always On, and AG safety block.
