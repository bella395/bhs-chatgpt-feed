Assert-True 'gate: html body rejected' ($(try { Assert-SourceShape '<html><body>Error</body></html>' 1; $false } catch { $true }))
Assert-True 'gate: too few rows' ($(try { Assert-SourceShape "id`ttitle`tdescription`tprice`nA`tB`tC`t1.00" 1500; $false } catch { $true }))
$good = ConvertTo-OpenAiItem (ConvertFrom-GdfTsv ([IO.File]::ReadAllText("$PSScriptRoot/fixtures/sample.tsv", [Text.Encoding]::UTF8)))[1]
Assert-Eq 'validate: good row' (@(Test-OpenAiItem $good).Count) 0
$bad = [ordered]@{}
foreach ($k in $good.Keys) { $bad[$k] = $good[$k] }
$bad.price = $null
Assert-True 'validate: zero price' (@(Test-OpenAiItem $bad).Count -gt 0)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('feedtest-' + [guid]::NewGuid()); New-Item -ItemType Directory $tmp | Out-Null
Write-FeedFiles @($good) $tmp @{ rows = 1 }
$line = [IO.File]::ReadAllLines("$tmp/products.jsonl", [Text.Encoding]::UTF8)[0]
Assert-True 'jsonl: utf8 round trip' ($line.Contains([char]0x00B0))
Assert-Eq 'jsonl: countries array' (($line | ConvertFrom-Json).target_countries -join ',') 'US'
Assert-True 'jsonl: no BOM' ([IO.File]::ReadAllBytes("$tmp/products.jsonl")[0] -eq [byte][char]'{')
Assert-True 'csv: quotes escaped' ([IO.File]::ReadAllText("$tmp/products.csv").Contains('""'))
Remove-Item -Recurse -Force $tmp

# final fix wave: F4 header gate, F6 validator
$fullHeader = "id`ttitle`tdescription`tprice`tcondition`tbrand`tlink`timage_link`tgoogle_product_category`tavailability`tsale_price"
$rowsText = @(1..3 | ForEach-Object { "r$_`tt`td`t1.00`tnew`tb`thttps://x`thttps://y`tc`tin stock`t" }) -join "`n"
Assert-True 'gate: full header passes' ($(try { Assert-SourceShape ($fullHeader + "`n" + $rowsText) 3; $true } catch { $false }))
$noAvail = $fullHeader.Replace("`tavailability", '')
$msg = ''
try { Assert-SourceShape ($noAvail + "`n" + $rowsText) 3 } catch { $msg = $_.Exception.Message }
Assert-True 'gate: missing availability throws naming it' ($msg -like '*availability*')
$nc = [ordered]@{}
foreach ($k in $good.Keys) { if ($k -ne 'condition' -and $k -ne 'product_category') { $nc[$k] = $good[$k] } }
Assert-Eq 'validate: condition/category optional' (@(Test-OpenAiItem $nc).Count) 0
$bc = [ordered]@{}
foreach ($k in $good.Keys) { $bc[$k] = $good[$k] }
$bc['condition'] = 'broken'
Assert-True 'validate: bad condition flagged' (@(Test-OpenAiItem $bc).Count -gt 0)
