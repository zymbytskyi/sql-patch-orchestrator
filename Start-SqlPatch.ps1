<# .SYNOPSIS Opens the interactive menu with elevation; never starts patching automatically. #>
#Requires -Version 5.1
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    $arguments='-NoExit -NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'"'
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -WindowStyle Normal -ArgumentList $arguments
    return
}
& (Join-Path $PSScriptRoot 'Start-SqlPatchV3Menu.ps1') -ApplyConcurrency 1
