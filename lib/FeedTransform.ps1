# Row conversion: GoDataFeed (Google Shopping TSV) -> OpenAI ChatGPT feed items.
# Valid in Windows PowerShell 5.1 and pwsh 7.

$script:SellerName   = 'BuyHeatShrink'
$script:SellerUrl    = 'https://buyheatshrink.com'
$script:ReturnPolicy = 'https://buyheatshrink.com/about-shipping-and-ordering-policies-buyheatshrink-com'

function ConvertFrom-GdfTsv {
    param([string]$Text)
    $lines = @($Text -split "`r?`n")
    $rows = @()
    $header = $null
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $cells = @($line -split "`t")
        if ($null -eq $header) {
            $header = @($cells | ForEach-Object { $_.Trim() })
            continue
        }
        $o = [ordered]@{}
        for ($i = 0; $i -lt $header.Count; $i++) {
            $v = ''
            if ($i -lt $cells.Count) { $v = $cells[$i].Replace('""', '"') }
            $o[$header[$i]] = $v
        }
        $rows += [pscustomobject]$o
    }
    return ,$rows
}

function Repair-Title {
    param([string]$Title)
    $t = $Title.Trim()
    while ($t -match '\s*[|-]\s*BuyHeatShrink\s*$') {
        $t = ($t -replace '\s*[|-]\s*BuyHeatShrink\s*$', '').TrimEnd()
    }
    if ($t.Length -gt 150) {
        $cut = $t.Substring(0, 150)
        if (-not [char]::IsWhiteSpace($t[150])) {
            $sp = $cut.LastIndexOf(' ')
            if ($sp -gt 0) { $cut = $cut.Substring(0, $sp) }
        }
        $t = $cut.TrimEnd()
    }
    return $t
}

function ConvertTo-PlainText {
    param([string]$Html)
    if ([string]::IsNullOrEmpty($Html)) { return '' }
    $t = $Html -replace '(?i)<br\s*/?>|</p>|</li>', ' '
    $t = $t -replace '<[^>]*>', ''
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = $t.Replace([string][char]0x00A0, ' ')
    $t = ($t -replace '\s+', ' ').Trim()
    if ($t.Length -gt 5000) {
        $cut = $t.Substring(0, 5000)
        $sp = $cut.LastIndexOf(' ')
        if ($sp -gt 0) { $cut = $cut.Substring(0, $sp) }
        $t = $cut.TrimEnd()
    }
    return $t
}

function ConvertTo-Decimal {
    # Returns [decimal] or $null when unparseable.
    param([string]$Amount)
    if ([string]::IsNullOrWhiteSpace($Amount)) { return $null }
    $m = [regex]::Match($Amount, '-?[\d,]*\.?\d+')
    if (-not $m.Success) { return $null }
    $clean = $m.Value.Replace(',', '')
    $d = [decimal]0
    $ok = [decimal]::TryParse($clean, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$d)
    if (-not $ok) { return $null }
    return $d
}

function Format-Money {
    param([string]$Amount)
    $d = ConvertTo-Decimal $Amount
    if ($null -eq $d -or $d -le 0) { return $null }
    return [string]::Format([cultureinfo]::InvariantCulture, '{0:F2} USD', $d)
}

function ConvertTo-Availability {
    param([string]$Value)
    $v = ([string]$Value).Trim().ToLowerInvariant().Replace('_', ' ')
    switch ($v) {
        'in stock'     { return 'in_stock' }
        'out of stock' { return 'out_of_stock' }
        'preorder'     { return 'pre_order' }
        'pre order'    { return 'pre_order' }
        'backorder'    { return 'backorder' }
        'back order'   { return 'backorder' }
        default        { return 'unknown' }
    }
}

function Get-ParentUrl {
    param([string]$Url)
    $u = $Url
    $i = $u.IndexOf('#'); if ($i -ge 0) { $u = $u.Substring(0, $i) }
    $i = $u.IndexOf('?'); if ($i -ge 0) { $u = $u.Substring(0, $i) }
    return $u
}

function Get-UrlOptions {
    param([string]$Url)
    $opts = [ordered]@{}
    $i = $Url.IndexOf('#'); if ($i -ge 0) { $Url = $Url.Substring(0, $i) }
    $q = $Url.IndexOf('?')
    if ($q -lt 0) { return $opts }
    foreach ($pair in $Url.Substring($q + 1).Split('&')) {
        if ($pair -eq '') { continue }
        $eq = $pair.IndexOf('=')
        if ($eq -lt 0) { $opts[$pair] = ''; continue }
        $opts[$pair.Substring(0, $eq)] = $pair.Substring($eq + 1)
    }
    return $opts
}

function Test-SaleWindow {
    # $true when $Window (Google 'start/end', ISO-8601) is empty or contains $Now; $false when outside or unparseable.
    param([string]$Window, [datetime]$Now)
    if ([string]::IsNullOrWhiteSpace($Window)) { return $true }
    $parts = @($Window.Trim() -split '/')
    if ($parts.Count -ne 2) { return $false }
    $bounds = @()
    foreach ($p in $parts) {
        $p = $p.Trim()
        $dto = [DateTimeOffset]::MinValue
        $ok = [DateTimeOffset]::TryParse($p, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dto)
        if (-not $ok) { return $false }
        $bounds += ,$dto
    }
    $start = $bounds[0]
    $end = $bounds[1]
    if ($parts[1].Trim() -match '^\d{4}-\d{2}-\d{2}$') { $end = $end.AddDays(1).AddTicks(-1) }
    $nowO = New-Object DateTimeOffset ($Now.ToUniversalTime())
    return ($nowO -ge $start -and $nowO -le $end)
}

function ConvertTo-OpenAiItem {
    param([pscustomobject]$Row, [datetime]$Now = [datetime]::UtcNow)
    $price = Format-Money $Row.price
    $sale = $null
    $salePrice = Format-Money $Row.sale_price
    if ($null -ne $salePrice) {
        $s = ConvertTo-Decimal $Row.sale_price
        $p = ConvertTo-Decimal $Row.price
        if ($null -ne $p -and $s -lt $p) { $sale = $salePrice }
    }
    if ($null -ne $sale -and -not (Test-SaleWindow ([string]$Row.sale_price_effective_date) $Now)) { $sale = $null }
    $item = [ordered]@{}
    $item['item_id']     = $Row.id
    $item['title']       = Repair-Title $Row.title
    $item['description'] = ConvertTo-PlainText $Row.description
    $item['url']         = $Row.link
    $item['brand']       = $Row.brand
    $item['seller_name'] = $script:SellerName
    $item['image_url']   = $Row.image_link
    $item['price']       = $price
    if ($null -ne $sale) { $item['sale_price'] = $sale }
    $item['availability']     = ConvertTo-Availability $Row.availability
    $cond = ([string]$Row.condition).Trim()
    if ($cond -ne '') { $item['condition'] = $cond }
    $cat = ([string]$Row.google_product_category -replace '\s*>\s*', ' > ').Trim()
    if ($cat -ne '') { $item['product_category'] = $cat }
    if ($Row.brand -ceq 'BuyHeatShrink' -and -not [string]::IsNullOrWhiteSpace($Row.id)) {
        $item['mpn'] = $Row.id.Trim()
    }
    $item['seller_url']       = $script:SellerUrl
    $item['return_policy']    = $script:ReturnPolicy
    $item['target_countries'] = [string[]]@('US')
    $item['store_country']    = 'US'
    return $item
}
