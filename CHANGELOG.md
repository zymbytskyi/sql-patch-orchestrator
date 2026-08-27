# Changelog

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
