# Validation gate and file writers. Valid in Windows PowerShell 5.1 and pwsh 7.

$script:CsvColumns = @(
    'item_id', 'title', 'description', 'url', 'brand', 'seller_name', 'image_url',
    'price', 'sale_price', 'availability', 'condition', 'product_category', 'mpn',
    'seller_url', 'return_policy', 'target_countries', 'store_country',
    'group_id', 'listing_has_variations', 'variant_dict'
)

function Test-OpenAiItem {
    param($Item)
    $problems = New-Object System.Collections.Generic.List[string]
    $required = @('item_id', 'title', 'description', 'url', 'brand', 'seller_name', 'image_url',
        'price', 'availability', 'seller_url', 'return_policy', 'store_country')
    foreach ($k in $required) {
        $v = $null
        if ($Item.Contains($k)) { $v = $Item[$k] }
        if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)) { $problems.Add("missing or empty $k") }
    }
    if ($Item.Contains('condition') -and $null -ne $Item['condition'] -and @('new', 'refurbished', 'used') -cnotcontains [string]$Item['condition']) {
        $problems.Add("bad condition '$($Item['condition'])'")
    }
    $price = $null
    if ($Item.Contains('price') -and $null -ne $Item['price']) { $price = [string]$Item['price'] }
    if ($null -ne $price -and $price -notmatch '^\d+\.\d{2} USD$') { $problems.Add("bad price format '$price'") }
    $enum = @('in_stock', 'out_of_stock', 'pre_order', 'backorder', 'unknown')
    if ($Item.Contains('availability') -and $null -ne $Item['availability'] -and $enum -cnotcontains [string]$Item['availability']) {
        $problems.Add("bad availability '$($Item['availability'])'")
    }
    foreach ($k in @('url', 'image_url', 'return_policy')) {
        if ($Item.Contains($k) -and $null -ne $Item[$k] -and -not ([string]$Item[$k]).StartsWith('https://')) {
            $problems.Add("$k does not start with https://")
        }
    }
    if ($Item.Contains('title') -and $null -ne $Item['title'] -and ([string]$Item['title']).Length -gt 150) { $problems.Add('title longer than 150') }
    if ($Item.Contains('description') -and $null -ne $Item['description'] -and ([string]$Item['description']).Length -gt 5000) { $problems.Add('description longer than 5000') }
    if ($Item.Contains('sale_price') -and $null -ne $Item['sale_price']) {
        $s = ConvertTo-Decimal ([string]$Item['sale_price'])
        $p = $null
        if ($null -ne $price) { $p = ConvertTo-Decimal $price }
        if ($null -eq $s -or $null -eq $p -or $s -ge $p) { $problems.Add('sale_price is not less than price') }
    }
    return $problems.ToArray()
}

function Assert-SourceShape {
    param([string]$Text, [int]$MinRows = 1500)
    if ([string]::IsNullOrEmpty($Text)) { throw 'source is empty' }
    $lines = @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0 -or -not $lines[0].StartsWith("id`ttitle`tdescription`tprice")) {
        throw 'source does not look like the product TSV (unexpected header)'
    }
    $have = @($lines[0].TrimEnd("`r") -split "`t" | ForEach-Object { $_.Trim() })
    $need = @('id', 'title', 'description', 'price', 'condition', 'brand', 'link', 'image_link', 'google_product_category', 'availability', 'sale_price')
    $missing = @($need | Where-Object { $have -cnotcontains $_ })
    if ($missing.Count -gt 0) { throw ('source header is missing column(s): ' + ($missing -join ', ')) }
    $rows = $lines.Count - 1
    if ($rows -lt $MinRows) { throw "source has only $rows rows (minimum $MinRows)" }
}

function ConvertTo-CsvField {
    param($Value)
    $s = ''
    if ($null -eq $Value) { $s = '' }
    elseif ($Value -is [bool]) { if ($Value) { $s = 'true' } else { $s = 'false' } }
    elseif ($Value -is [System.Collections.IDictionary]) { $s = (ConvertTo-Json -InputObject $Value -Compress -Depth 5) }
    elseif ($Value -is [System.Array]) { $s = (@($Value) -join ',') }
    else { $s = [string]$Value }
    if ($s.IndexOfAny([char[]]@(',', '"', "`r", "`n")) -ge 0) { $s = '"' + $s.Replace('"', '""') + '"' }
    return $s
}

function Write-FeedFiles {
    param($Items, [string]$OutDir, [hashtable]$Stats)
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    # Build everything in memory first so a failure writes nothing.
    $jsonl = New-Object System.Text.StringBuilder
    $csv = New-Object System.Text.StringBuilder
    [void]$csv.Append(($script:CsvColumns -join ',') + "`r`n")
    foreach ($item in $Items) {
        [void]$jsonl.Append((ConvertTo-Json -InputObject $item -Compress -Depth 5) + "`n")
        $cells = @()
        foreach ($c in $script:CsvColumns) {
            $v = $null
            if ($item.Contains($c)) { $v = $item[$c] }
            $cells += (ConvertTo-CsvField $v)
        }
        [void]$csv.Append(($cells -join ',') + "`r`n")
    }
    $run = [ordered]@{}
    $run['generated_at'] = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture)
    foreach ($k in @('rows', 'items_grouped', 'groups', 'standalone', 'label_pages_requested', 'label_pages_failed', 'label_pages_skipped')) {
        if ($Stats.ContainsKey($k)) { $run[$k] = $Stats[$k] }
    }
    $runJson = (ConvertTo-Json -InputObject $run -Depth 3) + "`n"

    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    [IO.File]::WriteAllText((Join-Path $OutDir 'products.jsonl'), $jsonl.ToString(), $utf8)
    [IO.File]::WriteAllText((Join-Path $OutDir 'products.csv'), $csv.ToString(), $utf8)
    [IO.File]::WriteAllText((Join-Path $OutDir 'last-run.json'), $runJson, $utf8)
    [IO.File]::WriteAllText((Join-Path $OutDir '.nojekyll'), '', $utf8)
}
