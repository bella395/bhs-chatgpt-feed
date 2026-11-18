$labels = Get-OptionLabels ([IO.File]::ReadAllText("$PSScriptRoot/fixtures/page-cut.html", [Text.Encoding]::UTF8))
Assert-Eq 'labels: lookup' $labels['length']['1356'] '4mm'
Assert-Eq 'labels: entities decoded' $labels['length']['99'] '3/8" Nipple end'
Assert-Eq 'display: awg' (Get-AttributeDisplayName 'awgsize') 'AWG Size'
Assert-Eq 'display: generic' (Get-AttributeDisplayName 'terminal_type') 'Terminal Type'
function New-I($id, $url) { [ordered]@{ item_id = $id; url = $url } }
$p = 'https://x.com/c/2-1-cut'
$items = @( (New-I 'A' "$p`?diameter=14&length=1356"), (New-I 'A2' "$p`?diameter=57&length=1356"),
            (New-I 'B' "$p`?diameter=57&length=91"), (New-I 'C' "$p`?diameter=57&length=91"),
            (New-I 'D' 'https://x.com/c/solo') )
$n = Add-VariantGroups $items @{ $p = $labels }
Assert-Eq 'variants: grouped count' $n 2
Assert-Eq 'variants: dict' ($items[0].variant_dict | ConvertTo-Json -Compress) '{"Diameter":"1/8\"","Length":"4mm"}'
Assert-Eq 'variants: group id' $items[0].group_id '2-1-cut'
Assert-Eq 'variants: flag' $items[0].listing_has_variations $true
Assert-True 'variants: duplicate combo -> standalone' (-not $items[2].Contains('group_id') -and -not $items[3].Contains('group_id'))
Assert-True 'variants: single parent -> standalone' (-not $items[4].Contains('group_id'))
$items2 = @( (New-I 'E' "$p`?diameter=14&length=1356"), (New-I 'F' "$p`?diameter=57&length=1356") )
Assert-Eq 'variants: missing labels -> standalone' (Add-VariantGroups $items2 @{ $p = $null }) 0
$bad = Get-ParentLabels @('http://127.0.0.1:9/nope') 0
Assert-True 'labels: failed fetch -> null, no throw' ($bad.ContainsKey('http://127.0.0.1:9/nope') -and $null -eq $bad['http://127.0.0.1:9/nope'])

# fix round 1: fallback and collision paths
$q = 'https://x.com/c/q-cut'
$lq = @{ size = @{ '1' = 'S'; '2' = 'L'; '3' = '' ; '4' = '   ' } }
$it = @( (New-I 'G' "$q`?size=1"), (New-I 'H' "$q`?size=2"), (New-I 'I' "$q`?size=3"), (New-I 'J' "$q`?size=4") )
Assert-Eq 'variants: empty/whitespace label -> standalone, others grouped' (Add-VariantGroups $it @{ $q = $lq }) 2
Assert-True 'variants: empty label item has no group_id' (-not $it[2].Contains('group_id') -and -not $it[3].Contains('group_id'))
Assert-Eq 'variants: labeled sibling grouped' $it[0].group_id 'q-cut'

$it = @( (New-I 'K' "$q`?size=1"), (New-I 'L' "$q`?size=2"), (New-I 'M' "$q`?size=9") )
Assert-Eq 'variants: unknown option id dropped, rest grouped' (Add-VariantGroups $it @{ $q = $lq }) 2
Assert-True 'variants: unknown option id item standalone' (-not $it[2].Contains('group_id'))

$it = @( (New-I 'N' "$q`?size=1"), (New-I 'O' "$q`?size=2"), (New-I 'P' "$q`?color=5&size=1") )
$lk = @{ size = @{ '1' = 'S'; '2' = 'L' }; color = @{ '5' = 'Red' } }
Assert-Eq 'variants: minority key set dropped' (Add-VariantGroups $it @{ $q = $lk }) 2
Assert-True 'variants: minority key set item standalone' (-not $it[2].Contains('group_id'))

$it = @( (New-I 'Q' "$q`?size=1"), (New-I 'R' "$q`?size=9") )
Assert-Eq 'variants: fewer than 2 survivors -> none grouped' (Add-VariantGroups $it @{ $q = $lq }) 0
Assert-True 'variants: lone survivor stays standalone' (-not $it[0].Contains('group_id') -and -not $it[0].Contains('variant_dict'))

$a = 'https://x.com/c/one/cut'; $b = 'https://x.com/d/two/cut'; $s = 'https://x.com/e/solo'
$ls = @{ size = @{ '1' = 'S'; '2' = 'L' } }
$it = @( (New-I 'a1' "$a`?size=1"), (New-I 'a2' "$a`?size=2"), (New-I 'b1' "$b`?size=1"), (New-I 'b2' "$b`?size=2"),
         (New-I 's1' "$s`?size=1"), (New-I 's2' "$s`?size=2") )
Assert-Eq 'ids: collision grouped count' (Add-VariantGroups $it @{ $a = $ls; $b = $ls; $s = $ls }) 6
Assert-Eq 'ids: collision first parent' $it[0].group_id 'c-one-cut'
Assert-Eq 'ids: collision second parent' $it[2].group_id 'd-two-cut'
Assert-Eq 'ids: non-colliding keeps last segment' $it[4].group_id 'solo'

# attfilt option blocks (second attribute lives in per-parent selects)
$la = Get-OptionLabels ([IO.File]::ReadAllText("$PSScriptRoot/fixtures/page-attfilt.html", [Text.Encoding]::UTF8))
Assert-Eq 'attfilt: label found' $la['length']['92'] '3/8"'
Assert-Eq 'attfilt: label from second block' $la['length']['93'] '1/2"'
Assert-Eq 'attfilt: shared id, same label' $la['length']['91'] '1/4"'
Assert-Eq 'attfilt: conflicting id -> empty' $la['length']['500'] ''
Assert-Eq 'attfilt: data-value select still read' $la['diameter']['57'] '3/64"'
$pa = 'https://x.com/c/att-cut'
$ia = @( (New-I 'S1' "$pa`?diameter=14&length=91"), (New-I 'S2' "$pa`?diameter=57&length=93"), (New-I 'S3' "$pa`?diameter=57&length=500") )
Assert-Eq 'attfilt: grouped, conflict item standalone' (Add-VariantGroups $ia @{ $pa = $la }) 2
Assert-True 'attfilt: conflict item has no group_id' (-not $ia[2].Contains('group_id'))

# scoped attfilt labels + SKU suffix stripping (spool structure)
$ls = Get-OptionLabels ([IO.File]::ReadAllText("$PSScriptRoot/fixtures/page-spool.html", [Text.Encoding]::UTF8))
Assert-Eq 'scoped: global feet 1059 conflict -> empty' $ls['feet']['1059'] ''
Assert-Eq 'scoped: block 38 label' $ls['feet|38']['1059'] '100 feet-SKU-A'
Assert-Eq 'scoped: block 39 label' $ls['feet|39']['1059'] '100 feet-SKU-B'
$ps = 'https://x.com/c/spools'
$is = @( (New-I 'SKU-A' "$ps`?diameter=38&feet=1059"), (New-I 'SKU-B' "$ps`?diameter=39&feet=1059"), (New-I 'SKU-C' "$ps`?diameter=39&feet=1061") )
Assert-Eq 'scoped: all three grouped' (Add-VariantGroups $is @{ $ps = $ls }) 3
Assert-Eq 'scoped: SKU-A feet stripped' $is[0].variant_dict['Feet'] '100 feet'
Assert-Eq 'scoped: SKU-B feet stripped' $is[1].variant_dict['Feet'] '100 feet'
Assert-Eq 'scoped: same group' $is[0].group_id $is[1].group_id
Assert-Eq 'scoped: non-matching suffix kept' $is[2].variant_dict['Feet'] '25 feet-OTHER'
Assert-Eq 'scoped: diameter label unchanged' $is[0].variant_dict['Diameter'] '7"'

# final fix wave: F1 budget / consecutive failures, F8 option regex
$sw = [Diagnostics.Stopwatch]::StartNew()
$b0 = Get-ParentLabels @('http://127.0.0.1:9/a', 'http://127.0.0.1:9/b') 0 0
$sw.Stop()
Assert-True 'budget 0: both keys present' ($b0.ContainsKey('http://127.0.0.1:9/a') -and $b0.ContainsKey('http://127.0.0.1:9/b'))
Assert-True 'budget 0: both values null' ($null -eq $b0['http://127.0.0.1:9/a'] -and $null -eq $b0['http://127.0.0.1:9/b'])
Assert-True 'budget 0: returns quickly' ($sw.Elapsed.TotalSeconds -lt 2)
$u8 = @(1..8 | ForEach-Object { "http://127.0.0.1:9/p$_" })
$b8 = Get-ParentLabels $u8 0 480
Assert-Eq 'consecutive failures: all 8 keys present' @($u8 | Where-Object { $b8.ContainsKey($_) }).Count 8
Assert-Eq 'consecutive failures: all 8 values null' @($u8 | Where-Object { $null -eq $b8[$_] }).Count 8
$ob = Get-OptionLabels '<select data-value="size"><option value="91" data-value="5">1/4"</option></select>'
Assert-Eq 'option regex: ignores data-value attr' $ob['size']['91'] '1/4"'
Assert-True 'option regex: data-value not used as key' (-not $ob['size'].ContainsKey('5'))
