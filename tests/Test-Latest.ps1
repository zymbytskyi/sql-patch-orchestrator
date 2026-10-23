#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'SqlPatchV2Local/SqlPatchUpdates.ps1')
function Assert-Throws {param([scriptblock]$Action);$failed=$false;try{& $Action}catch{$failed=$true};if(-not$failed){throw 'Expected rejection'}}
$script:rows='<table><tr><td>16.0.4295.3</td><td>CU27</td><td>KB5000001</td><td>September 15, 2026</td></tr><tr><td>16.0.4305.5</td><td>CU27 + GDR</td><td>KB5126934</td><td>October 13, 2026</td></tr><tr><td>16.0.4275.2</td><td>CU26 + GDR</td><td>KB5122768</td><td>September 8, 2026</td></tr><tr><td>16.0.9999.1</td><td>CU99 + GDR</td><td>KB5999999</td><td>December 1, 2099</td></tr><tr><td>15.0.4500.2</td><td>CU32 + GDR</td><td>KB5128494</td><td>October 13, 2026</td></tr></table>'
if((Get-SqlSecurityUpdateRow $rows 16 ([datetime]'2026-10-23')).Version-ne'16.0.4305.5'){throw 'Wrong latest'}
if((Get-SqlSecurityUpdateRow $rows 15 ([datetime]'2026-10-23')).Version-ne'15.0.4500.2'){throw 'Wrong major'}
if((Get-SqlSecurityUpdateRow $rows 16 ([datetime]'2026-09-17')).Version-ne'16.0.4275.2'){throw 'Base CU selected'}
Assert-Throws {Get-SqlSecurityUpdateRow '<table>missing</table>' 16}
Assert-Throws {Get-SqlSecurityUpdateRow ($rows+$rows.Replace('KB5126934','KB5000002')) 16}
$script:mode='center'
function Invoke-WebRequest {
 param($Uri,$Method,$Body,$UserAgent,[switch]$UseBasicParsing,$TimeoutSec,$ErrorAction)
 $text=''
 if($Uri-match'kb321185'){$text=$script:rows}
 elseif($Uri-match'/help/'){$text='KB5126934 16.0.4305.5 <a href="https://www.microsoft.com/download/details.aspx?id=1">Download</a>';if($script:mode-eq'badbuild'){$text=$text.Replace('16.0.4305.5','16.0.4295.3')}}
 elseif($Uri-match'details.aspx'){if($script:mode-eq'catalog'){throw '404'};$text='https://download.microsoft.com/test/SQLServer2022-KB5126934-x64.exe';if($script:mode-eq'badfile'){$text='wrong.exe'}}
 elseif($Uri-match'Search.aspx'){$text='<a id="11111111-1111-1111-1111-111111111111_link">Security Update for SQL Server 2022 CU (KB5126934)</a>';if($script:mode-eq'badfile'){$text='missing'}}
 elseif($Uri-match'DownloadDialog'){if($Method-ne'Post'-or-not($Body.updateIDs|ConvertFrom-Json)){throw 'Bad catalog request'};$text="https://catalog.s.download.windowsupdate.com/test/SQLServer2022-KB5126934-x64_abcdef.exe"}
 else{throw "Unexpected request $Uri"}
 [pscustomobject]@{Content=$text}
}
if((Get-LatestSqlSecurityUpdate 16).Uri-notmatch'download.microsoft.com'){throw 'Center resolution failed'}
$script:mode='catalog'
if((Get-LatestSqlSecurityUpdate 16).Uri-notmatch'windowsupdate.com'){throw 'Catalog fallback failed'}
$script:mode='badbuild';Assert-Throws {Get-LatestSqlSecurityUpdate 16}
$script:mode='badfile';Assert-Throws {Get-LatestSqlSecurityUpdate 16}
Write-Output '[PASS] Security selection, dates, major, metadata rejection, Download Center and Catalog resolution.'
exit 0


