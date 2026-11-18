$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

foreach ($f in (Get-ChildItem -Path (Join-Path $root 'lib') -Filter '*.ps1' -ErrorAction SilentlyContinue | Sort-Object Name)) {
    . $f.FullName
}
. (Join-Path $PSScriptRoot 'assert.ps1')
foreach ($f in (Get-ChildItem -Path $PSScriptRoot -Filter 'test-*.ps1' | Sort-Object Name)) {
    Write-Host "== $($f.Name)"
    . $f.FullName
}

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) failure(s)"
    exit 1
}
Write-Host 'all passed'
exit 0
