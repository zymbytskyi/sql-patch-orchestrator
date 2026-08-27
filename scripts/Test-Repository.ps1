<# .SYNOPSIS Runs the public repository validation. #>
#Requires -Version 5.1
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Test-Package.ps1')
exit $LASTEXITCODE
