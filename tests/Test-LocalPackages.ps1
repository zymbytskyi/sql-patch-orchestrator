#Requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Invoke-SqlPatchV3Remote.ps1'),[ref]$t,[ref]$e)
foreach($name in @('Get-PackageMap','New-PackageRecord')){
    . ([scriptblock]::Create($ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-eq$name},$true).Extent.Text))
}
function Assert($Condition,$Message){if(-not$Condition){throw $Message}}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('LocalPackages-'+[guid]::NewGuid().ToString('N'))
$PackageRoot=$testRoot
New-Item -ItemType Directory $testRoot|Out-Null
$supported=@{16=2022;15=2019}
$script:versions=@{'SQLServer2022-KB9999999-x64.exe'='16.0.9.9';'SQLServer2022-KB1111111-x64.exe'='16.0.10.1';'SQLServer2019-KB2222222-x64.exe'='15.0.4000.1'}
foreach($name in $script:versions.Keys){[IO.File]::WriteAllText((Join-Path $testRoot $name),'fixture')}
# Real enumeration and hashing, controlled version/signature boundary.
$script:bad=$null
function Get-Item {param($LiteralPath);[pscustomobject]@{VersionInfo=[pscustomobject]@{ProductVersion=$script:versions[[IO.Path]::GetFileName($LiteralPath)]}}}
function Get-AuthenticodeSignature {param($LiteralPath);[pscustomobject]@{Status=$(if([IO.Path]::GetFileName($LiteralPath)-eq$script:bad){'HashMismatch'}else{'Valid'});SignerCertificate=[pscustomobject]@{Subject='CN=Microsoft Corporation'}}}
function Get-PackageReleaseMetadata {param($Path,$Major,$Version);[pscustomobject]@{UpdateName='Test';ReleaseDate='Unknown';PackageAgeDays='Unknown';MetadataSource='Test'}}
$state=[pscustomobject]@{Servers=@([pscustomobject]@{Instances=@([pscustomobject]@{Major=16},[pscustomobject]@{Major=15})})}
try{
    $map=Get-PackageMap $state
    Assert ($map['16'].Version-eq'16.0.10.1') 'Numeric ordering failed; KB ordering must not win.'
    Assert ($map['15'].Version-eq'15.0.4000.1') 'SQL major isolation failed.'
    Assert (@(Get-ChildItem $testRoot -File).Count-eq3) 'Old media was deleted.'
    $script:versions['SQLServer2022-KB9999999-x64.exe']='16.0.10.1'
    Assert ((Get-PackageMap $state)['16'].Name-eq'SQLServer2022-KB1111111-x64.exe') 'Equal-build selection is not deterministic.'
    foreach($case in @('signature','major','version')){
        $script:bad=$null
        $script:versions['SQLServer2022-KB9999999-x64.exe']='16.0.9.9'
        if($case-eq'signature'){$script:bad='SQLServer2022-KB9999999-x64.exe'}
        if($case-eq'major'){$script:versions['SQLServer2022-KB9999999-x64.exe']='15.0.9999.1'}
        if($case-eq'version'){$script:versions['SQLServer2022-KB9999999-x64.exe']='broken'}
        $blocked=$false;try{Get-PackageMap $state|Out-Null}catch{$blocked=$true}
        Assert $blocked "Invalid $case silently accepted or skipped."
    }
    $PackageRoot=Join-Path $testRoot 'empty';New-Item -ItemType Directory $PackageRoot|Out-Null
    $blocked=$false;try{Get-PackageMap $state|Out-Null}catch{$blocked=$true}
    Assert $blocked 'Missing media accepted.'
    Write-Output '[PASS] Numeric build selection, mixed majors, ties, retention and fail-closed validation.'
}finally{
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)-and(Split-Path $resolved -Leaf)-like'LocalPackages-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
