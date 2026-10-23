#Requires -Version 5.1
# Shared resolver: highest released CU-branch build: base CU or CU + GDR; never RTM/GDR.
function ConvertFrom-SqlUpdateHtml {
    param([string]$Html)
    [regex]::Replace([Net.WebUtility]::HtmlDecode([regex]::Replace($Html,'<[^>]+>',' ')),'\s+',' ').Trim()
}
function Get-SqlLatestUpdateRow {
    param([string]$Html,[int]$Major,[datetime]$AsOf=[datetime]::UtcNow.Date)
    $years=@{14=2017;15=2019;16=2022;17=2025}
    if(-not$years.ContainsKey($Major)){throw "Unsupported SQL major $Major."}
    $candidates=@()
    foreach($row in [regex]::Matches($Html,'<tr\b[^>]*>[\s\S]*?</tr>','IgnoreCase')){
        $plain=ConvertFrom-SqlUpdateHtml $row.Value
        # Complete-version table rows begin with the engine build.
        $build=[regex]::Match($plain,('^({0}\.0\.\d+\.\d+)\s'-f$Major))
        $name=[regex]::Match($plain,'\b(CU\d+(?:\s*\+\s*GDR)?)\b','IgnoreCase')
        if(-not$build.Success-or-not$name.Success){continue}
        $kb=[regex]::Match($plain,'\bKB\d+\b','IgnoreCase')
        $date=[regex]::Match($plain,'\b[A-Z][a-z]+ \d{1,2}, \d{4}\b')
        if(-not$kb.Success-or-not$date.Success){throw "Incomplete CU update row: $plain"}
        $released=[datetime]::ParseExact($date.Value,'MMMM d, yyyy',[Globalization.CultureInfo]::GetCultureInfo('en-US'))
        if($released.Date-gt$AsOf.Date){continue}
        $candidates+=[pscustomobject]@{Major=$Major;Year=$years[$Major];Name=$name.Value;KB=$kb.Value.ToUpperInvariant();Version=$build.Groups[1].Value;ReleaseDate=$released.ToString('yyyy-MM-dd');FileName="SQLServer$($years[$Major])-$($kb.Value.ToUpperInvariant())-x64.exe"}
    }
    if(-not$candidates.Count){throw "No verified CU or CU + GDR update found for SQL Server $($years[$Major])."}
    $ordered=@($candidates|Sort-Object @{Expression={[version]$_.Version};Descending=$true},@{Expression={[datetime]$_.ReleaseDate};Descending=$true})
    $latest=$ordered[0]
    $conflicts=@($ordered|Where-Object{$_.Version-eq$latest.Version-and$_.KB-ne$latest.KB})
    if($conflicts.Count){throw 'Conflicting KB metadata for the selected build.'}
    $latest
}
function Get-SqlUpdateLinks {
    param([string]$Html,[uri]$BaseUri)
    foreach($m in [regex]::Matches($Html,'href\s*=\s*["'']([^"'']+)["'']','IgnoreCase')){
        $value=[Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
        try{$uri=[uri]::new($BaseUri,$value)}catch{continue}
        if($uri.Scheme-eq'https'){$uri.AbsoluteUri}
    }
}
function Get-SqlUpdateCatalogUrl {
    param($Update)
    $search=Invoke-WebRequest -Uri ("https://www.catalog.update.microsoft.com/Search.aspx?q="+$Update.KB) -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec 60 -ErrorAction Stop
    $ids=@()
    foreach($link in [regex]::Matches([string]$search.Content,'<a\b[^>]*id=["'']([a-f0-9-]{36})_link["''][^>]*>([\s\S]*?)</a>','IgnoreCase')){
        $title=ConvertFrom-SqlUpdateHtml $link.Groups[2].Value
        if($title-match("SQL Server "+$Update.Year+"\b")-and(($Update.Name-match'GDR'-and$title-match'Security Update'-and$title-match'\bCU\b')-or($Update.Name-notmatch'GDR'-and$title-match'Cumulative Update'))-and$title-match('\b'+$Update.KB+'\b')){$ids+=$link.Groups[1].Value}
    }
    $ids=@($ids|Sort-Object -Unique)
    if($ids.Count-ne1){throw "Expected one CU-branch catalog entry for $($Update.KB); found $($ids.Count)."}
    $payload=ConvertTo-Json -InputObject @(@{size=0;updateID=$ids[0];uidInfo=$ids[0]}) -Compress
    $dialog=Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method Post -Body @{updateIDs=$payload} -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec 60 -ErrorAction Stop
    $urls=@()
    foreach($m in [regex]::Matches([string]$dialog.Content,"https://[^'""\s<>]+",'IgnoreCase')){
        $u=[uri]$m.Value
        $filePattern='^SQLServer'+$Update.Year+'-'+$Update.KB+'-x64(?:_[a-f0-9]+)?\.exe$'
        if($u.Host-in@('catalog.s.download.windowsupdate.com','download.windowsupdate.com')-and[IO.Path]::GetFileName($u.AbsolutePath)-match$filePattern){$urls+=$u.AbsoluteUri}
    }
    $urls=@($urls|Sort-Object -Unique)
    if($urls.Count-ne1){throw "Expected one exact x64 EXE in the Microsoft catalog for $($Update.KB); found $($urls.Count)."}
    $urls[0]
}
function Get-LatestSqlUpdate {
    param([int]$Major)
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $indexUri='https://support.microsoft.com/en-us/servicing/sql/kb321185-download-and-install-latest-updates'
    $index=Invoke-WebRequest -Uri $indexUri -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec 60 -ErrorAction Stop
    $update=Get-SqlLatestUpdateRow -Html ([string]$index.Content) -Major $Major
    $kbUri="https://support.microsoft.com/en-us/help/$($update.KB.Substring(2))"
    $kbLinks=@(Get-SqlUpdateLinks -Html ([string]$index.Content) -BaseUri $indexUri | Where-Object { $u=[uri]$_; $u.Host-eq'support.microsoft.com'-and$u.AbsolutePath-match('(?i)/'+$update.KB+'(?:-|/|$)') } | Sort-Object -Unique)
    if($kbLinks.Count-eq1){$kbUri=$kbLinks[0]}
    $article=Invoke-WebRequest -Uri $kbUri -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec 60 -ErrorAction Stop
    $plain=ConvertFrom-SqlUpdateHtml ([string]$article.Content)
    if($plain-notmatch('\b'+[regex]::Escape($update.KB)+'\b')-or$plain-notmatch('(?<![\d.])'+[regex]::Escape($update.Version)+'(?![\d.])')){
        throw "Microsoft KB/build mismatch for $($update.KB) / $($update.Version)."
    }
    $centers=@(Get-SqlUpdateLinks -Html ([string]$article.Content) -BaseUri $kbUri|Where-Object{
        $u=[uri]$_; $u.Host-eq'www.microsoft.com'-and$u.AbsolutePath-match'/download/details\.aspx$'
    }|Sort-Object -Unique)
    $downloads=@()
    foreach($centerUri in $centers){
        try{$center=Invoke-WebRequest -Uri $centerUri -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec 60 -ErrorAction Stop}
        catch{Write-Warning 'Microsoft Download Center link unavailable; checking Microsoft Update Catalog.';continue}
        $centerHtml=[Net.WebUtility]::HtmlDecode([string]$center.Content)
        $pattern='https://download\.microsoft\.com/[^"''\s<>]+/'+[regex]::Escape($update.FileName)+'(?:\?[^"''\s<>]*)?'
        foreach($m in [regex]::Matches($centerHtml,$pattern,'IgnoreCase')){
            $uri=[uri]$m.Value
            if($uri.Host-eq'download.microsoft.com'){$downloads+=$uri.AbsoluteUri}
        }
    }
    $downloads=@($downloads|Sort-Object -Unique)
    if(-not$downloads.Count){$downloads=@(Get-SqlUpdateCatalogUrl -Update $update)}
    if($downloads.Count-ne1){throw "Expected one exact Microsoft EXE URL for $($update.FileName); found $($downloads.Count)."}
    $update|Add-Member NoteProperty Uri $downloads[0]
    $update|Add-Member NoteProperty Source $indexUri
    $update
}

