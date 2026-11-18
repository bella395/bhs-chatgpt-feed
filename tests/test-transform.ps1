Assert-Eq 'title: suffix + quotes' (Repair-Title '3/8" Heat Shrink End Cap | Adhesive Lined | BuyHeatShrink') '3/8" Heat Shrink End Cap | Adhesive Lined'
Assert-Eq 'title: repeated suffix' (Repair-Title '1" Pre-Cut Tubing | 250Pcs | BuyHeatShrink | BuyHeatShrink') '1" Pre-Cut Tubing | 250Pcs'
Assert-Eq 'title: dash suffix' (Repair-Title '1/2" Rope End Caps - Heat Shrink End Cap - BuyHeatShrink') '1/2" Rope End Caps - Heat Shrink End Cap'
Assert-Eq 'plain: tags+entities' (ConvertTo-PlainText 'Use <strong>End Caps</strong>&nbsp;to seal &amp; protect.<br>  Next') 'Use End Caps to seal & protect. Next'
Assert-Eq 'money: plain' (Format-Money '0.65') '0.65 USD'
Assert-Eq 'money: one decimal' (Format-Money '12.5') '12.50 USD'
Assert-Eq 'money: thousands' (Format-Money '1,234.50') '1234.50 USD'
Assert-Eq 'money: empty' (Format-Money '') $null
Assert-Eq 'money: zero' (Format-Money '0') $null
Assert-Eq 'avail: in stock' (ConvertTo-Availability 'in stock') 'in_stock'
Assert-Eq 'avail: preorder' (ConvertTo-Availability 'preorder') 'pre_order'
Assert-Eq 'avail: junk' (ConvertTo-Availability 'maybe') 'unknown'
Assert-Eq 'parent url' (Get-ParentUrl 'https://x.com/a/b?diameter=14&length=1356') 'https://x.com/a/b'
Assert-Eq 'url options' ((Get-UrlOptions 'https://x.com/a/b?diameter=14&length=1356').Keys -join ',') 'diameter,length'
$rows = ConvertFrom-GdfTsv ([IO.File]::ReadAllText("$PSScriptRoot/fixtures/sample.tsv", [Text.Encoding]::UTF8))
Assert-Eq 'tsv: row count' $rows.Count 4
Assert-Eq 'tsv: quotes repaired' ($rows[0].title.Contains('""')) $false
$it = ConvertTo-OpenAiItem $rows[0]
Assert-Eq 'item: price' $it.price '0.65 USD'
Assert-Eq 'item: seller' $it.seller_name 'BuyHeatShrink'
Assert-Eq 'item: countries' ($it.target_countries -join ',') 'US'
Assert-True 'item: mpn on BHS brand' ($it.Contains('mpn'))
Assert-True 'item: no mpn on Zeus' (-not (ConvertTo-OpenAiItem $rows[1]).Contains('mpn'))
Assert-True 'item: equal sale dropped' (-not (ConvertTo-OpenAiItem $rows[2]).Contains('sale_price'))
Assert-True 'item: lower sale kept' ((ConvertTo-OpenAiItem $rows[3]).Contains('sale_price'))
# extras
Assert-Eq 'item: key order' ((ConvertTo-OpenAiItem $rows[3]).Keys -join ',') 'item_id,title,description,url,brand,seller_name,image_url,price,sale_price,availability,condition,product_category,mpn,seller_url,return_policy,target_countries,store_country'
Assert-Eq 'item: category spacing' (ConvertTo-OpenAiItem $rows[1]).product_category 'Hardware > Power & Electrical Supplies > Electrical Wire & Cable'
Assert-True 'item: degree sign survives' ((ConvertTo-OpenAiItem $rows[1]).description.Contains([string][char]0x00B0))
Assert-True 'item: countries is array' ((ConvertTo-OpenAiItem $rows[0]).target_countries -is [array])
Assert-Eq 'item: zeus title inch mark' (ConvertTo-OpenAiItem $rows[1]).title '1" 1.3:1 FEP Heat Shrink Tubing (4ft/pc) - Clear'
Assert-Eq 'plain: truncates on word boundary' (ConvertTo-PlainText (('word ' * 2000))).Length 4999
Assert-Eq 'avail: out of stock' (ConvertTo-Availability 'out of stock') 'out_of_stock'
Assert-Eq 'avail: backorder' (ConvertTo-Availability 'backorder') 'backorder'
# mpn rule: id, only for brand exactly BuyHeatShrink
$mrow = $rows[0].PSObject.Copy()
$mrow.mpn = ''
Assert-Eq 'mpn: BHS blank mpn column still uses id' (ConvertTo-OpenAiItem $mrow).mpn $mrow.id
$mrow.mpn = 'SOMETHING-ELSE'
Assert-Eq 'mpn: BHS differing mpn column uses id' (ConvertTo-OpenAiItem $mrow).mpn $mrow.id
$mrow.brand = 'Raychem'
Assert-True 'mpn: third brand gets none' (-not (ConvertTo-OpenAiItem $mrow).Contains('mpn'))
$mrow.brand = 'buyheatshrink'
Assert-True 'mpn: brand match is case-exact' (-not (ConvertTo-OpenAiItem $mrow).Contains('mpn'))

# final fix wave: F4 availability, F5 sale window, F6 optional fields
Assert-Eq 'avail: in_stock' (ConvertTo-Availability 'in_stock') 'in_stock'
Assert-Eq 'avail: out_of_stock' (ConvertTo-Availability 'out_of_stock') 'out_of_stock'
Assert-Eq 'avail: pre_order' (ConvertTo-Availability 'pre_order') 'pre_order'
Assert-Eq 'avail: mixed case' (ConvertTo-Availability '  In Stock ') 'in_stock'
$srow = $rows[3].PSObject.Copy()
$srow | Add-Member -NotePropertyName sale_price_effective_date -NotePropertyValue '' -Force
$now = [datetime]::SpecifyKind([datetime]'2026-11-25T12:00:00', [DateTimeKind]::Utc)
$win = '2026-11-20T00:00-05:00/2026-11-30T23:59-05:00'
Assert-True 'sale window: empty keeps' ((ConvertTo-OpenAiItem $srow $now).Contains('sale_price'))
$srow.sale_price_effective_date = $win
Assert-True 'sale window: inside keeps' ((ConvertTo-OpenAiItem $srow $now).Contains('sale_price'))
Assert-True 'sale window: before start drops' (-not (ConvertTo-OpenAiItem $srow ([datetime]::SpecifyKind([datetime]'2026-11-10T00:00:00', [DateTimeKind]::Utc))).Contains('sale_price'))
Assert-True 'sale window: after end drops' (-not (ConvertTo-OpenAiItem $srow ([datetime]::SpecifyKind([datetime]'2026-12-05T00:00:00', [DateTimeKind]::Utc))).Contains('sale_price'))
$srow.sale_price_effective_date = '2026-11-20/2026-11-30'
Assert-True 'sale window: date-only inside keeps' ((ConvertTo-OpenAiItem $srow $now).Contains('sale_price'))
$srow.sale_price_effective_date = 'garbage'
Assert-True 'sale window: garbage drops' (-not (ConvertTo-OpenAiItem $srow $now).Contains('sale_price'))
$srow.sale_price_effective_date = 'a/b'
Assert-True 'sale window: unparseable pair drops' (-not (ConvertTo-OpenAiItem $srow $now).Contains('sale_price'))
$crow = $rows[0].PSObject.Copy()
$crow.condition = ''
$crow.google_product_category = ''
$ci = ConvertTo-OpenAiItem $crow
Assert-True 'optional: empty condition omitted' (-not $ci.Contains('condition'))
Assert-True 'optional: empty category omitted' (-not $ci.Contains('product_category'))
Assert-Eq 'optional: item with neither validates' (@(Test-OpenAiItem $ci).Count) 0
$lt = ('abcdefghi ' * 20).Trim()
Assert-Eq 'title: 200 chars truncated at word boundary' (Repair-Title $lt).Length 149
Assert-True 'title: truncated ends on a whole word' ((Repair-Title $lt).EndsWith('abcdefghi'))
$lrow = $rows[0].PSObject.Copy(); $lrow.title = $lt
Assert-Eq 'title: long title item validates' (@(Test-OpenAiItem (ConvertTo-OpenAiItem $lrow)).Count) 0
$nospace = 'x' * 200
Assert-Eq 'title: no spaces hard cut at 150' (Repair-Title $nospace).Length 150
