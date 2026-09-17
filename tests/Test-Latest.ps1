#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Invoke-SqlPatchV3Remote.ps1'),[ref]$tokens,[ref]$errors)
$fn=$ast.Find({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-eq'Assert-LatestCuMetadata'},$true)
Invoke-Expression $fn.Extent.Text
$buildHistoryPages=@{17='https://learn.microsoft.com/test'}
$script:html='<table><tr><td>CU9 (Latest)</td><td>17.0.5005.3</td><td>KB5122048</td></tr></table>'
function Invoke-WebRequest {param($Uri,[switch]$UseBasicParsing,$TimeoutSec,$ErrorAction);[pscustomobject]@{Content=$script:html}}
Assert-LatestCuMetadata 17 '17.0.5005.3' 'KB5122048'
$blocked=$false
try{Assert-LatestCuMetadata 17 '17.0.4065.4' 'KB5096981'}catch{$blocked=$_.Exception.Message-match'sources disagree'}
if(-not$blocked){throw 'Stale Download Center metadata was accepted as latest'}
$script:html='<html>unavailable</html>';$blocked=$false
try{Assert-LatestCuMetadata 17 '17.0.5005.3' 'KB5122048'}catch{$blocked=$_.Exception.Message-match'Could not verify'}
if(-not$blocked){throw 'Missing build history was accepted'}
Write-Output '[PASS] Latest CU cross-check: matching metadata, stale Download Center rejection, unavailable history rejection.'
exit 0
