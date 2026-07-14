<#
Verify-Images.ps1 — check every referenced image is a COMPLETE file, and delete
any that is truncated so the repair scripts will rebuild it.

A file pulled through DesignSync is capped at 256 KiB, so large images arrive
cut in half. They still open in some viewers (showing half a photo) which is
worse than an obvious failure — hence this check on the terminating marker:
  JPEG must end FF D9      PNG must end with the IEND chunk

    pwsh tools/Verify-Images.ps1          # report + delete corrupt
    pwsh tools/Verify-Images.ps1 -Report  # report only
#>
param([switch]$Report)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$html = Get-Content (Join-Path $root 'Family Tree.dc.html') -Raw
$refs = [regex]::Matches($html, 'img/[A-Za-z0-9_/.-]*\.(?:png|jpg)') | ForEach-Object { $_.Value } | Sort-Object -Unique

$ok = 0; $bad = @(); $absent = @()
foreach ($ref in $refs) {
  $p = Join-Path $root $ref
  if (-not (Test-Path $p)) { $absent += $ref; continue }
  $b = [IO.File]::ReadAllBytes($p)
  $good = $false
  if ($ref -match '(?i)\.jpe?g$') {
    $good = ($b.Length -gt 4 -and $b[-2] -eq 0xFF -and $b[-1] -eq 0xD9)
  } else {
    # PNG: last 8 bytes are the IEND chunk -> 49 45 4E 44 AE 42 60 82
    $good = ($b.Length -gt 12 -and $b[-8] -eq 0x49 -and $b[-7] -eq 0x45 -and $b[-6] -eq 0x4E -and $b[-5] -eq 0x44)
  }
  if ($good) { $ok++ } else { $bad += $ref }
}

Write-Host "referenced : $($refs.Count)"
Write-Host "complete   : $ok"
Write-Host "TRUNCATED  : $($bad.Count)"
Write-Host "absent     : $($absent.Count)"
foreach ($f in $bad) {
  Write-Host "  corrupt: $f" -ForegroundColor Red
  if (-not $Report) { Remove-Item (Join-Path $root $f) -Force }
}
foreach ($f in $absent) { Write-Host "  absent : $f" -ForegroundColor Yellow }
if (-not $Report -and $bad.Count) { Write-Host "`ndeleted the corrupt files — now run Rebuild-Images.ps1 and Extract-PdfImages.ps1" }

# non-zero exit so a build can refuse to publish a broken image
if ($bad.Count -or $absent.Count) { exit 1 }
exit 0
