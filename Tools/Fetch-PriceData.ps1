# Fetches region-wide commodity prices from the Blizzard Game Data API and
# writes PriceData.lua into the Goldsmith addon folder. Run by a scheduled task
# (see Install-PriceTask.ps1). New data loads in game on the next login or /reload.
# Each run also compares the listings with the previous hour's to estimate what
# sold, and keeps that in the hourly snapshots (for sales history later).
#
#   .\Fetch-PriceData.ps1 -SetCredentials   # once: store client ID and secret
#   .\Fetch-PriceData.ps1                   # fetch now

param(
    [switch]$SetCredentials,
    [string]$Region = 'us',
    [switch]$Force,     # write even if Blizzard hasn't published new data
    [string]$FromFile,  # testing: read a saved commodities JSON instead of calling the API
    [string]$OutFile,   # testing: write somewhere other than the addon folder
    [string]$DataDir    # testing: keep snapshots and listings here (with -FromFile, also compares listings)
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest very slow in 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$dataDir   = if ($DataDir) { $DataDir } else { Join-Path $env:LOCALAPPDATA 'Goldsmith' }
$credFile  = Join-Path $env:LOCALAPPDATA 'Goldsmith\blizzard-api.xml'
$stateFile = Join-Path $dataDir 'last-modified.txt'
$logFile   = Join-Path $dataDir 'fetch.log'
$snapDir   = Join-Path $dataDir 'snapshots'
$listFile  = Join-Path $dataDir 'listings.tsv'   # the previous hour's listings
$addonDir  = Split-Path $PSScriptRoot -Parent
$outFile   = if ($OutFile) { $OutFile } else { Join-Path $addonDir 'PriceData.lua' }
$luac      = 'C:\Program Files (x86)\Lua\5.1\luac.exe'
$keepDays  = 14
$maxGap    = 180   # minutes; listings further apart than this aren't compared
$keepHistory = (-not $FromFile) -or $DataDir

New-Item -ItemType Directory -Force $dataDir, $snapDir | Out-Null

function Log($msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
    Add-Content -Path $logFile -Value $line
    Write-Host $line
}

if ($SetCredentials) {
    # Stored with Windows DPAPI: only this Windows user on this PC can read it.
    $cred = Get-Credential -Message 'Blizzard API: user name = Client ID, password = Client Secret'
    $cred | Export-Clixml $credFile
    Write-Host "Saved to $credFile"
    return
}

try {
  if ($FromFile) {
    $json = [IO.File]::ReadAllText($FromFile)
    $lastModified = (Get-Item $FromFile).LastWriteTimeUtc.ToString('r')
  } else {
    if (-not (Test-Path $credFile)) { throw "No credentials. Run: .\Fetch-PriceData.ps1 -SetCredentials" }
    $cred   = Import-Clixml $credFile
    $id     = $cred.UserName
    $secret = $cred.GetNetworkCredential().Password

    # 1. OAuth token (client credentials flow)
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${id}:${secret}"))
    $token = (Invoke-RestMethod -Method Post -Uri 'https://oauth.battle.net/token' `
        -Headers @{ Authorization = "Basic $basic" } `
        -Body @{ grant_type = 'client_credentials' }).access_token

    # 2. Region-wide commodities (tens of MB, updated about hourly)
    $uri = "https://$Region.api.blizzard.com/data/wow/auctions/commodities?namespace=dynamic-$Region&locale=en_US"
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers @{ Authorization = "Bearer $token" }
    $lastModified = $resp.Headers['Last-Modified']
    if (-not $Force -and (Test-Path $stateFile) -and (Get-Content $stateFile -Raw).Trim() -eq $lastModified) {
        Log "No new data (Last-Modified $lastModified)"
        return
    }
    $json = $resp.Content
    $resp = $null
  }

    # 3. Parse with a regex: ConvertFrom-Json in PowerShell 5.1 is very slow on files this size.
    #    Each auction: {"id":..,"item":{"id":ITEM},"quantity":QTY,"unit_price":PRICE,"time_left":".."}
    $rx = [regex]'\{"id":(\d+),"item":\{"id":(\d+)\},"quantity":(\d+),"unit_price":(\d+),"time_left":"(\w+)"\}'
    $timeLeft = @{ SHORT = 1; MEDIUM = 2; LONG = 3; VERY_LONG = 4 }
    #    Per item: price -> units at that price, kept sorted by price.
    $items = New-Object 'System.Collections.Generic.Dictionary[int,System.Collections.Generic.SortedDictionary[long,long]]'
    #    Per listing: auction ID -> { item, quantity, price, time left (1-4) }
    $listings = New-Object 'System.Collections.Generic.Dictionary[long,long[]]'
    $count = 0
    foreach ($m in $rx.Matches($json)) {
        $item = [int]$m.Groups[2].Value
        $qty = [long]$m.Groups[3].Value
        $price = [long]$m.Groups[4].Value
        $book = $null
        if (-not $items.TryGetValue($item, [ref]$book)) {
            $book = New-Object 'System.Collections.Generic.SortedDictionary[long,long]'
            $items[$item] = $book
        }
        $had = 0L
        [void]$book.TryGetValue($price, [ref]$had)
        $book[$price] = $had + $qty
        $listings[[long]$m.Groups[1].Value] = [long[]]@($item, $qty, $price, $timeLeft[$m.Groups[5].Value])
        $count++
    }
    $json = $null
    if ($count -eq 0) { throw 'No auctions found in the response (format changed?)' }

    # 4. What sold since the previous hour. Commodity buyers can't pick a listing:
    #    each purchase fills from the cheapest listings up. So, per item:
    #    - a listing still there with fewer units was partly bought (the surest sign)
    #    - the cheapest listing that's still there untouched is a ceiling: nothing
    #      above it was bought, so listings above it that went were cancelled
    #    - one that went with under 30 minutes left (SHORT) most likely expired
    #    - one that went while a new listing of the same quantity appeared at the
    #      same price or lower was most likely cancelled and reposted (undercutting)
    #    - anything else that went below the ceiling is counted as sold
    #    Listings posted and bought within the same hour are never seen, so sold
    #    is a floor. Each kind is kept separately so the rules can be tuned later.
    #    Per item: sold units, sold value (copper), of which partial, expired,
    #    cancelled, reposted, new units posted.
    $sales = New-Object 'System.Collections.Generic.Dictionary[int,long[]]'
    function SalesRow($item) {
        $row = $null
        if (-not $sales.TryGetValue($item, [ref]$row)) { $row = New-Object long[] 7; $sales[$item] = $row }
        return , $row
    }
    $minutes = ''
    if ($keepHistory -and (Test-Path $listFile)) {
        $lines = [IO.File]::ReadAllLines($listFile)
        $culture = [Globalization.CultureInfo]::InvariantCulture
        $gap = ([DateTimeOffset]::Parse($lastModified, $culture) - [DateTimeOffset]::Parse($lines[0].Substring(2), $culture)).TotalMinutes
        if ($gap -gt 0 -and $gap -le $maxGap) {
            $minutes = [int]$gap
            $prev = New-Object 'System.Collections.Generic.Dictionary[long,long[]]'
            for ($i = 1; $i -lt $lines.Length; $i++) {
                $f = $lines[$i].Split("`t")
                $prev[[long]$f[0]] = [long[]]@([long]$f[1], [long]$f[2], [long]$f[3], [long]$f[4])
            }
            $lines = $null

            $ceiling = New-Object 'System.Collections.Generic.Dictionary[int,long]'
            $gone = New-Object 'System.Collections.Generic.List[long[]]'
            foreach ($e in $prev.GetEnumerator()) {
                $p = $e.Value; $c = $null
                if (-not $listings.TryGetValue($e.Key, [ref]$c)) { $gone.Add($p); continue }
                if ($c[1] -lt $p[1]) {
                    $n = $p[1] - $c[1]; $row = SalesRow ([int]$p[0])
                    $row[0] += $n; $row[1] += $n * $p[2]; $row[2] += $n
                } else {
                    $low = 0L
                    if (-not $ceiling.TryGetValue([int]$p[0], [ref]$low) -or $p[2] -lt $low) { $ceiling[[int]$p[0]] = $p[2] }
                }
            }

            # New listings, by item and quantity, for spotting reposts.
            $posted = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[long]]'
            foreach ($e in $listings.GetEnumerator()) {
                if ($prev.ContainsKey($e.Key)) { continue }
                $c = $e.Value
                $row = SalesRow ([int]$c[0]); $row[6] += $c[1]
                $key = "$($c[0]):$($c[1])"; $list = $null
                if (-not $posted.TryGetValue($key, [ref]$list)) {
                    $list = New-Object 'System.Collections.Generic.List[long]'; $posted[$key] = $list
                }
                $list.Add($c[2])
            }

            foreach ($p in $gone) {
                $n = $p[1]; $row = SalesRow ([int]$p[0])
                if ($p[3] -eq 1) { $row[3] += $n; continue }
                $low = 0L
                if ($ceiling.TryGetValue([int]$p[0], [ref]$low) -and $p[2] -gt $low) { $row[4] += $n; continue }
                $list = $null
                if ($posted.TryGetValue("$($p[0]):$n", [ref]$list)) {
                    $at = -1
                    for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i] -le $p[2]) { $at = $i; break } }
                    if ($at -ge 0) { $list.RemoveAt($at); $row[5] += $n; continue }
                }
                $row[0] += $n; $row[1] += $n * $p[2]
            }
            $prev = $null
        }
    }

    # 5. Stats per item (copper): lowest price, median by quantity, and the
    #    quantity-weighted average of the cheapest 15% of units ("market"), plus units listed.
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $lua = New-Object Text.StringBuilder
    $csv = New-Object Text.StringBuilder
    [void]$lua.AppendLine('-- Generated by Tools\Fetch-PriceData.ps1. Do not edit.')
    [void]$lua.AppendLine("-- items[itemID] = { min, market, median, quantity }  (copper)")
    [void]$lua.AppendLine("GoldsmithPriceData = { region = `"$Region`", updated = $now, items = {")
    #    Snapshot columns after quantity: see step 4 (blank when there was nothing to
    #    compare with); minutes = time since the listings compared with.
    [void]$csv.AppendLine('item,min,market,median,quantity,sold,sold_value,partial,expired,cancelled,reposted,posted,minutes')
    $ids = New-Object 'System.Collections.Generic.List[int]' (, $items.Keys)
    $ids.Sort()
    foreach ($item in $ids) {
        $book = $items[$item]
        $total = 0L; foreach ($units in $book.Values) { $total += $units }
        $cut = [math]::Max(1, [math]::Ceiling($total * 0.15))
        $half = [math]::Ceiling($total / 2)
        $seen = 0L; $sum = 0.0; $taken = 0L; $median = $null; $min = $null
        foreach ($r in $book.GetEnumerator()) {
            if ($null -eq $min) { $min = $r.Key }
            if ($taken -lt $cut) {
                $n = [math]::Min($r.Value, $cut - $taken)
                $sum += $n * $r.Key; $taken += $n
            }
            $seen += $r.Value
            if ($null -eq $median -and $seen -ge $half) { $median = $r.Key; if ($taken -ge $cut) { break } }
        }
        $market = [long][math]::Round($sum / $taken)
        [void]$lua.AppendLine("[$item]={$min,$market,$median,$total},")
        $row = $null
        $diff = if ($sales.TryGetValue($item, [ref]$row)) { $row -join ',' } elseif ($minutes) { '0,0,0,0,0,0,0' } else { ',,,,,,' }
        [void]$csv.AppendLine("$item,$min,$market,$median,$total,$diff,$minutes")
    }
    #    Items with no listings left this hour (sold out, or cancelled).
    $gone = New-Object 'System.Collections.Generic.List[int]'
    foreach ($item in $sales.Keys) { if (-not $items.ContainsKey($item)) { $gone.Add($item) } }
    $gone.Sort()
    foreach ($item in $gone) { [void]$csv.AppendLine("$item,,,,0,$($sales[$item] -join ','),$minutes") }
    [void]$lua.AppendLine('} }')

    # 6. Write to a temp file, check it, then swap it in so WoW never loads half a file.
    $tmp = "$outFile.tmp"
    [IO.File]::WriteAllText($tmp, $lua.ToString(), (New-Object Text.UTF8Encoding $false))
    if (Test-Path $luac) {
        & $luac -p $tmp
        if ($LASTEXITCODE -ne 0) { throw 'Generated PriceData.lua failed the syntax check' }
    }
    Move-Item -Force $tmp $outFile

    if (-not $keepHistory) { Log "TEST: $count auctions, $($items.Count) items -> $outFile"; return }

    # Keep hourly snapshots for price and sales history later; drop old ones.
    $snap = Join-Path $snapDir ('{0:yyyy-MM-dd_HHmm}.csv' -f (Get-Date))
    [IO.File]::WriteAllText($snap, $csv.ToString())
    Get-ChildItem $snapDir -Filter *.csv | Where-Object LastWriteTime -lt (Get-Date).AddDays(-$keepDays) | Remove-Item

    # This hour's listings, for the next run to compare with. First line: "# <Last-Modified>".
    $tsv = New-Object Text.StringBuilder
    [void]$tsv.AppendLine("# $lastModified")
    foreach ($e in $listings.GetEnumerator()) {
        $c = $e.Value
        [void]$tsv.AppendLine("$($e.Key)`t$($c[0])`t$($c[1])`t$($c[2])`t$($c[3])")
    }
    [IO.File]::WriteAllText("$listFile.tmp", $tsv.ToString())
    Move-Item -Force "$listFile.tmp" $listFile

    Set-Content $stateFile $lastModified
    $sold = 0L; foreach ($row in $sales.Values) { $sold += $row[0] }
    $compared = if ($minutes) { ", $sold units sold over $minutes min" } else { ', no listings to compare with' }
    Log "OK: $count auctions, $($items.Count) items -> PriceData.lua (Last-Modified $lastModified)$compared"
}
catch {
    Log "FAILED: $($_.Exception.Message)"
    exit 1
}
