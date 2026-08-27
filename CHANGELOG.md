# Changelog

## 3.0.5 - 2026-08-27

- Removed all cycle-name format and language requirements; the DBA can use any descriptive label for production, emergency, test, or other work.
- Separated the exact display label from a deterministic SHA-256-derived storage key so arbitrary names remain safe filesystem inputs.
- Preserved legacy `MonthYYYY` run-directory compatibility and added `cycle-name.txt` beside runtime state for easy identification.
- Added explicit UTF-8 reads for state, metadata, targets, and cycle labels so non-ASCII names remain intact on Windows PowerShell 5.1.

## 3.0.4 - 2026-08-27

- Removed the English-language requirement from patch-cycle input.
- Added language-neutral `YYYY-MM`, Enter-for-current-month, and localized full-month-name input while retaining existing `MonthYYYY` compatibility and normalized safe run-directory names.

## 3.0.3 - 2026-08-27

- Added an automatic HTTPS fallback when BITS cannot run in a remote or non-interactive PowerShell session.
- Added visible GitHub installer stages and elapsed time, and made safe upgrades non-interactive while preserving targets, packages, and runs.

## 3.0.2 - 2026-08-27

- Removed explicit blocking Microsoft Defender custom scans from GitHub installation, controller package validation, and the target worker.
- Retained release SHA-256 validation, per-file manifest verification, Microsoft Authenticode validation, product-major validation, and remote hash verification.
- Did not disable Defender, add exclusions, or alter any endpoint security policy.
- Aligned the target worker with the controller's existing standalone Enterprise edition support.

## 3.0.1 - 2026-08-27

- Added interactive monthly cycle selection and menu-based cycle switching.
- Corrected the system-database backup workflow and evidence reporting.
- Added SQL Server 2017 default backup path compatibility.
- Added time-zone-safe backup age calculation.
- Added a non-mutating inventory gate before package download and distribution.
- Added standalone Enterprise edition recognition.
- Corrected SQL `bit` and `DBNull` mapping so COPY_ONLY and CHECKSUM evidence remains accurate after remote inventory serialization.

## 3.0.0 - 2026-08-18

- Initial public V3 release for remote standalone SQL Server patch orchestration.
