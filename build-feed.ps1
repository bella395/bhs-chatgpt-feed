# Builds products.jsonl / products.csv / last-run.json from the GoDataFeed export.
# Usage: pwsh -NoProfile -File build-feed.ps1 [-SourceFile <path>] [-OutDir <path>] [-SkipLabels]
# The source URL comes only from $env:GDF_FEED_URL and is never printed or written.
param(
    [string]$SourceFile,
    [string]$OutDir,
    [switch]$SkipLabels
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = $root }
foreach ($f in (Get-ChildItem -Path (Join-Path $root 'lib') -Filter '*.ps1' | Sort-Object Name)) { . $f.FullName }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# 1. Read the source as bytes, decode UTF-8, strip BOM.
$bytes = $null
if (-not [string]::IsNullOrEmpty($SourceFile)) {
    $bytes = [IO.File]::ReadAllBytes($SourceFile)
} elseif (-not [string]::IsNullOrEmpty($env:GDF_FEED_URL)) {
    try {
        $resp = Invoke-WebRequest -Uri $env:GDF_FEED_URL.Trim() -UseBasicParsing -TimeoutSec 180
        $bytes = $resp.RawContentStream.ToArray()
    } catch {
        # Never include the URL or the exception message (it can contain the URL).
        $diag = $_.Exception.GetType().Name
        $status = $null
        try { if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) { $status = [int]$_.Exception.Response.StatusCode } } catch { }
        if ($null -ne $status) { $diag += " HTTP $status" }
        throw "source download failed: $diag"
    }
} else {
    throw 'no source: pass -SourceFile or set GDF_FEED_URL'
}
$text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }

# 2. Gate, convert.
Assert-SourceShape $text 1500
$rows = ConvertFrom-GdfTsv $text
$items = @($rows | ForEach-Object { ConvertTo-OpenAiItem $_ })

# 3. Variant labels (only parents with 2+ SKUs).
$byParent = @{}
foreach ($it in $items) {
    $pu = Get-ParentUrl ([string]$it['url'])
    if ($byParent.ContainsKey($pu)) { $byParent[$pu]++ } else { $byParent[$pu] = 1 }
}
$multi = @($byParent.Keys | Where-Object { $byParent[$_] -ge 2 } | Sort-Object)
$requested = 0; $failed = 0; $skipped = 0
$labels = @{}
if (-not $SkipLabels -and $multi.Count -gt 0) {
    $requested = $multi.Count
    $labels = Get-ParentLabels $multi 1000 480
    $failedUrls = @($multi | Where-Object { $null -eq $labels[$_] })
    $failed = $failedUrls.Count
    foreach ($fu in $failedUrls) { Write-Host "label fetch failed (parent page): $fu" }

    $skipped = $script:LabelPagesSkipped
}
$grouped = Add-VariantGroups $items $labels
$groupIds = @{}
foreach ($it in $items) { if ($it.Contains('group_id')) { $groupIds[$it['group_id']] = $true } }

# 4. Validate everything before writing anything.
$problems = New-Object System.Collections.Generic.List[string]
$seen = @{}
foreach ($it in $items) {
    foreach ($p in @(Test-OpenAiItem $it)) { $problems.Add("$($it['item_id']): $p") }
    $id = [string]$it['item_id']
    if ($seen.ContainsKey($id)) { $problems.Add("${id}: duplicate item_id") } else { $seen[$id] = $true }
}
if ($problems.Count -gt 0) {
    $first = @($problems | Select-Object -First 20) -join "`n"
    throw "Validation failed: $($problems.Count) problem(s). Nothing written. First 20:`n$first"
}

# 5. Write.
$stats = @{
    rows = $items.Count
    items_grouped = $grouped
    groups = $groupIds.Count
    standalone = $items.Count - $grouped
    label_pages_requested = $requested
    label_pages_failed = $failed
    label_pages_skipped = $skipped
}
Write-FeedFiles $items $OutDir $stats
Write-Host "rows=$($stats.rows) problems=0 grouped=$grouped groups=$($stats.groups) standalone=$($stats.standalone) label_pages=$requested failed=$failed skipped=$skipped"
