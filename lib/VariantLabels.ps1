# Variant labels and grouping: fetch option labels from Magento product pages and
# group size-option SKUs of the same page. Valid in Windows PowerShell 5.1 and pwsh 7.

function Get-OptionLabels {
    param([string]$Html)
    $result = @{}
    if ([string]::IsNullOrEmpty($Html)) { return $result }
    # Sources: selects with data-value="<code>", and per-parent "attfilt" selects keyed by name="<code>".
    # The same id with two different labels is a conflict and is stored as '' (the SKU goes standalone).
    $selects = [regex]::Matches($Html, '(?i)<select\b([^>]*)>([\s\S]*?)</select>')
    foreach ($s in $selects) {
        $attrs = $s.Groups[1].Value
        $code = $null
        $dv = [regex]::Match($attrs, '(?i)\bdata-value\s*=\s*"([^"]+)"')
        if ($dv.Success) {
            $code = $dv.Groups[1].Value
        } else {
            $cls = [regex]::Match($attrs, '(?i)\bclass\s*=\s*"([^"]*)"')
            $nm = [regex]::Match($attrs, '(?i)\bname\s*=\s*"([^"]+)"')
            if ($cls.Success -and $nm.Success -and ($cls.Groups[1].Value -match '(?i)\battfilt\b')) { $code = $nm.Groups[1].Value }
        }
        if ($null -eq $code) { continue }
        # attfilt blocks are also recorded per data-identity under "<name>|<identity>" (codes never contain '|').
        $scopedKey = $null
        if (-not $dv.Success) {
            $di = [regex]::Match($attrs, '(?i)\bdata-identity\s*=\s*"([^"]+)"')
            if ($di.Success) { $scopedKey = $code + '|' + $di.Groups[1].Value }
        }
        if ($null -ne $scopedKey) {
            if (-not $result.ContainsKey($scopedKey)) { $result[$scopedKey] = @{} }
            foreach ($o in [regex]::Matches($s.Groups[2].Value, '(?i)<option\b[^>]*(?<![\w-])value="(\d+)"[^>]*>([^<]*)</option>')) {
                $result[$scopedKey][$o.Groups[1].Value] = [System.Net.WebUtility]::HtmlDecode($o.Groups[2].Value).Replace([string][char]0x00A0, ' ').Trim()
            }
        }
        if (-not $result.ContainsKey($code)) { $result[$code] = @{} }
        $opts = [regex]::Matches($s.Groups[2].Value, '(?i)<option\b[^>]*(?<![\w-])value="(\d+)"[^>]*>([^<]*)</option>')
        foreach ($o in $opts) {
            $id = $o.Groups[1].Value
            $label = [System.Net.WebUtility]::HtmlDecode($o.Groups[2].Value).Replace([string][char]0x00A0, ' ').Trim()
            if ($result[$code].ContainsKey($id) -and $result[$code][$id] -cne $label) {
                $result[$code][$id] = ''
            } elseif (-not $result[$code].ContainsKey($id)) {
                $result[$code][$id] = $label
            }
        }
    }
    return $result
}

function Get-AttributeDisplayName {
    param([string]$Code)
    $map = @{
        'awgsize'            = 'AWG Size'
        'hole_terminal_size' = 'Hole/Terminal Size'
        'wirerange'          = 'Wire Range'
        'flagsize'           = 'Flag Size'
        'thermalcolor'       = 'Thermal Color'
        'walltype'           = 'Wall Type'
        'piece'              = 'Pieces'
    }
    if ($map.ContainsKey($Code)) { return $map[$Code] }
    $words = @($Code.Split('_') | Where-Object { $_ -ne '' } | ForEach-Object {
        $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1).ToLowerInvariant()
    })
    return ($words -join ' ')
}

function Get-ParentLabels {
    # Returns url -> labels hashtable (or $null when not fetched / failed). Stops fetching when the
    # time budget is spent or after $MaxConsecutiveFailures failed parents in a row.
    param([string[]]$ParentUrls, [int]$DelayMs = 1000, [int]$BudgetSec = 480)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
    $MaxConsecutiveFailures = 6
    $out = @{}
    $first = $true
    $consecutive = 0
    $script:LabelPagesSkipped = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($url in $ParentUrls) {
        if ($sw.Elapsed.TotalSeconds -ge $BudgetSec -or $consecutive -ge $MaxConsecutiveFailures) {
            $out[$url] = $null
            $script:LabelPagesSkipped++
            continue
        }
        if (-not $first -and $DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
        $first = $false
        $labels = $null
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $threw = $false
            try {
                $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -UserAgent $ua
                $html = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
                $parsed = Get-OptionLabels $html
                if ($parsed.Count -gt 0) { $labels = $parsed }
            } catch {
                $threw = $true
            }
            if ($null -ne $labels -or -not $threw) { break }
            if ($attempt -lt 2 -and $DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
        }
        if ($null -eq $labels) { $consecutive++ } else { $consecutive = 0 }
        $out[$url] = $labels
    }
    return $out
}

function Add-VariantGroups {
    param($Items, [hashtable]$LabelsByParent)

    # Bucket items by parent URL, keeping first-seen order.
    $parents = New-Object System.Collections.Generic.List[string]
    $byParent = @{}
    foreach ($item in $Items) {
        $pu = Get-ParentUrl ([string]$item['url'])
        if (-not $byParent.ContainsKey($pu)) { $byParent[$pu] = New-Object System.Collections.ArrayList; [void]$parents.Add($pu) }
        [void]$byParent[$pu].Add($item)
    }

    # Decide which items of each parent group.
    $plans = New-Object System.Collections.ArrayList
    foreach ($pu in $parents) {
        $members = $byParent[$pu]
        if ($members.Count -lt 2) { continue }
        if (-not $LabelsByParent.ContainsKey($pu) -or $null -eq $LabelsByParent[$pu]) { continue }
        $labels = $LabelsByParent[$pu]

        $infos = @()
        foreach ($m in $members) {
            $opts = Get-UrlOptions ([string]$m['url'])
            $keys = @($opts.Keys)
            $ok = ($keys.Count -gt 0)
            $dict = [ordered]@{}
            $itemId = [string]$m['item_id']
            foreach ($k in $keys) {
                $oid = [string]$opts[$k]
                $label = $null
                if ($labels.ContainsKey($k) -and $labels[$k].ContainsKey($oid)) { $label = $labels[$k][$oid] }
                if ([string]::IsNullOrWhiteSpace($label) -and $keys.Count -gt 0) {
                    $sk = $k + '|' + [string]$opts[$keys[0]]
                    if ($labels.ContainsKey($sk) -and $labels[$sk].ContainsKey($oid)) { $label = $labels[$sk][$oid] }
                }
                if (-not [string]::IsNullOrWhiteSpace($label) -and $itemId -ne '') {
                    $suffix = '-' + $itemId
                    if ($label.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
                        $label = $label.Substring(0, $label.Length - $suffix.Length).Trim()
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($label)) {
                    $dict[(Get-AttributeDisplayName $k)] = $label
                } else { $ok = $false }
            }
            $infos += [pscustomobject]@{ Item = $m; KeySet = ($keys -join ','); Ok = $ok; Dict = $dict }
        }

        # Most common key set; ties go to the one seen first.
        $best = $null; $bestCount = 0
        foreach ($ks in @($infos | ForEach-Object { $_.KeySet } | Select-Object -Unique)) {
            $c = @($infos | Where-Object { $_.KeySet -ceq $ks }).Count
            if ($c -gt $bestCount) { $best = $ks; $bestCount = $c }
        }
        $cands = @($infos | Where-Object { $_.Ok -and $_.KeySet -ceq $best })

        # Drop every SKU whose label combination is shared with another SKU.
        $combos = @{}
        foreach ($c in $cands) {
            $sig = (($c.Dict.Keys | ForEach-Object { $_ + '=' + $c.Dict[$_] }) -join '|')
            $c | Add-Member -NotePropertyName Sig -NotePropertyValue $sig -Force
            if ($combos.ContainsKey($sig)) { $combos[$sig]++ } else { $combos[$sig] = 1 }
        }
        $survivors = @($cands | Where-Object { $combos[$_.Sig] -eq 1 })
        if ($survivors.Count -ge 2) {
            [void]$plans.Add([pscustomobject]@{ Parent = $pu; Survivors = $survivors })
        }
    }

    # Group ids: last path segment, or the full path with / -> - on collisions.
    $segCount = @{}
    foreach ($pl in $plans) {
        $seg = (($pl.Parent -replace '/+$', '') -split '/')[-1]
        if ($segCount.ContainsKey($seg)) { $segCount[$seg]++ } else { $segCount[$seg] = 1 }
    }
    $grouped = 0
    foreach ($pl in $plans) {
        $trimmed = ($pl.Parent -replace '/+$', '')
        $seg = ($trimmed -split '/')[-1]
        if ($segCount[$seg] -gt 1) {
            $path = ($trimmed -replace '^[A-Za-z][A-Za-z0-9+.-]*://[^/]*', '').Trim('/')
            $gid = $path.Replace('/', '-')
        } else { $gid = $seg }
        foreach ($s in $pl.Survivors) {
            $s.Item['group_id'] = $gid
            $s.Item['listing_has_variations'] = $true
            $s.Item['variant_dict'] = $s.Dict
            $grouped++
        }
    }
    return $grouped
}
