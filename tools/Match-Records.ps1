<#
Match-Records.ps1 — attach the actual record scans to the people they document.

The scans in Thompson/ and Ingleby/ are Ancestry image downloads, and their
filenames carry the archive reference:

  WRYRG11_4710_4714-0183.jpg   class RG11, piece range 4710-4714, image 0183
  WRYHO107_1350_1352-0348.jpg  class HO107, pieces 1350-1352
  rg14_28345_0311_03.jpg       1911 census, piece 28345
  22216_0653.jpg               1921 census, Book 22216
  tna_r39_3478_3478b_006.jpg   1939 Register, RG101/3478B

A GEDCOM citation carries the exact reference:

  "Class: RG11; Piece: 4711; Folio: 24; Page: 43"
  "Reference: RG 15/22216, ED 5, Sch 321; Book: 22216"
  "Reference: RG 101/3478B"

So a scan is matched to a person by CLASS + PIECE (piece inside the file's range),
never by name or guesswork.

CAVEAT, and it is reported rather than hidden: a piece range covers several
folios, so a scan can match citations from more than one household. Where the
matching citations disagree on folio/page, the match is AMBIGUOUS — it is listed
in the report and NOT attached, because attaching the wrong census page to a
person is exactly the kind of quiet error this project exists to avoid.

    pwsh tools/Match-Records.ps1            # report only
    pwsh tools/Match-Records.ps1 -Write     # also copy scans into img/records/ and emit data/records.json
#>
param([switch]$Write)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$family = Split-Path -Parent $root
$G = Get-Content (Join-Path $root 'data/gedcom.json') -Raw | ConvertFrom-Json

# ---------------------------------------------------------------- the scans
# The full Ancestry media export lives in Roots/Thompson Family Tree_media (287
# images). The GEDCOM's OBJE records leave the FILE line EMPTY, so it cannot tell
# us which image belongs to whom — but the FILENAMES carry the archive reference,
# and the citations carry it too. That is the join.
$scanDirs = @(
  (Join-Path $family 'Thompson'),
  (Join-Path $family 'Ingleby'),
  (Join-Path $family 'Roots\Thompson Family Tree_media')
) | Where-Object { Test-Path $_ }

$scans = @()
foreach ($f in (Get-ChildItem $scanDirs -File -Filter *.jpg)) {
  $n = $f.Name
  $s = $null
  # census image bundles: <county><CLASS>_<lo>_<hi>-<image>.jpg
  if ($n -match '(?i)^[A-Z]{0,3}(HO\d+|RG\d+)_(\d+)_(\d+)-(\d+)\.jpg$') {
    $s = [ordered]@{ file = $f.FullName; name = $n; kind = 'census'; class = $matches[1].ToUpper(); lo = [int]$matches[2]; hi = [int]$matches[3] }
  }
  # 1911: rg14_<piece>_...
  elseif ($n -match '(?i)^rg14_(\d+)_') {
    $s = [ordered]@{ file = $f.FullName; name = $n; kind = 'census'; class = 'RG14'; lo = [int]$matches[1]; hi = [int]$matches[1] }
  }
  # 1939 Register: tna_r39_<piece>_<ref>_...
  elseif ($n -match '(?i)^tna_r39_\d+_(\w+)_') {
    $s = [ordered]@{ file = $f.FullName; name = $n; kind = 'reg1939'; ref = $matches[1].ToUpper() }
  }
  # 1921: <book>_<image>.jpg
  elseif ($n -match '^(\d{5})_(\d{4})\.jpg$') {
    $s = [ordered]@{ file = $f.FullName; name = $n; kind = 'census1921'; book = $matches[1] }
  }
  if ($s) { $scans += , $s }
}
Write-Host "record scans recognised: $($scans.Count)"

# ---------------------------------------------------------------- citations
function Parse-Cite {
  param([string]$page)
  $o = @{}
  if ($page -match '(?i)Class:\s*(HO\d+|RG\d+)') { $o.class = $matches[1].ToUpper() }
  if ($page -match '(?i)Piece:\s*(\d+)') { $o.piece = [int]$matches[1] }
  if ($page -match '(?i)Folio:\s*(\d+)') { $o.folio = $matches[1] }
  if ($page -match '(?i)Page:\s*(\d+)') { $o.pg = $matches[1] }
  if ($page -match '(?i)RG\s*15/(\d+)') { $o.class = 'RG15'; $o.piece = [int]$matches[1]; $o.book = $matches[1] }
  if ($page -match '(?i)Book:\s*(\d+)') { $o.book = $matches[1] }
  if ($page -match '(?i)RG\s*101/(\w+)') { $o.reg1939 = $matches[1].ToUpper() }
  if ($page -match '(?i)Reference:\s*RG\s*14[/\s]*(\d+)') { $o.class = 'RG14'; $o.piece = [int]$matches[1] }
  return $o
}

# every (person, event, citation)
$cites = @()
foreach ($id in $G.people.PSObject.Properties.Name) {
  $p = $G.people.$id
  foreach ($e in $p.events) {
    foreach ($c in @($e.cites)) {
      if (-not $c -or -not $c.page) { continue }
      $pc = Parse-Cite $c.page
      if (-not $pc.Count) { continue }
      $yr = if ($e.date -and $e.date -match '(\d{4})') { [int]$matches[1] } else { $null }
      $cites += , [ordered]@{
        pid = $id; name = "$($p.givn) $($p.surn)"; year = $yr; tag = $e.tag
        title = $c.sid; page = $c.page; parsed = $pc
      }
    }
  }
}
Write-Host "citations with a parseable reference: $($cites.Count)"
Write-Host ""

# ---------------------------------------------------------------- match
$attach = @{}          # pid -> list of scans
$ambiguous = @()
$unmatched = @()

foreach ($s in $scans) {
  $hits = @()
  foreach ($c in $cites) {
    $pc = $c.parsed
    $ok = $false
    switch ($s.kind) {
      'census' { $ok = ($pc.class -eq $s.class -and $pc.piece -and $pc.piece -ge $s.lo -and $pc.piece -le $s.hi) }
      'census1921' { $ok = ($pc.book -eq $s.book) }
      'reg1939' { $ok = ($pc.reg1939 -and ($pc.reg1939 -replace '[^A-Z0-9]', '') -eq ($s.ref -replace '[^A-Z0-9]', '')) }
    }
    if ($ok) { $hits += , $c }
  }

  if (-not $hits.Count) { $unmatched += $s.name; continue }

  # do all the hits describe ONE household (same folio+page)? if not, we cannot
  # tell which page of the piece this image actually is.
  $keys = @($hits | ForEach-Object { "$($_.parsed.folio)/$($_.parsed.pg)" } | Sort-Object -Unique)
  if ($keys.Count -gt 1) {
    $ambiguous += , [ordered]@{ scan = $s.name; households = $keys.Count; people = @($hits | ForEach-Object { $_.name } | Sort-Object -Unique) }
    continue
  }

  # One person can hit the same scan from several events: Ancestry hangs a census
  # source on the BIRTH as well as on the residence. Prefer the residence — that
  # is the event the census page actually documents — or the year comes out as the
  # birth year (Harry's 1921 census page was being labelled 1915).
  # Group-Object cannot read a key off an OrderedDictionary, so group by hand.
  $byPerson = @{}
  foreach ($h in $hits) {
    if (-not $byPerson[$h.pid]) { $byPerson[$h.pid] = @() }
    $byPerson[$h.pid] += , $h
  }
  foreach ($who in $byPerson.Keys) {
    $grp = @($byPerson[$who])
    $h = @($grp | Where-Object { $_.tag -eq 'RESI' })[0]
    if (-not $h) { $h = $grp[0] }
    if (-not $attach[$who]) { $attach[$who] = @() }
    if ($attach[$who] | Where-Object { $_.name -eq $s.name }) { continue }
    $attach[$who] += , [ordered]@{ name = $s.name; file = $s.file; year = $h.year; page = $h.page }
  }
}

Write-Host "=== MATCHED ==============================================="
foreach ($who in ($attach.Keys | Sort-Object { $G.people.$_.surn })) {
  $p = $G.people.$who
  Write-Host ("  {0,-28} {1}" -f "$($p.givn) $($p.surn)", (($attach[$who] | ForEach-Object { $_.name }) -join ', '))
}
Write-Host ""
Write-Host "  scans attached : $((($attach.Values | ForEach-Object { $_ }) | ForEach-Object { $_.name } | Sort-Object -Unique).Count)"
Write-Host "  people with a document: $($attach.Count)"

Write-Host ""
Write-Host "=== AMBIGUOUS (not attached — the piece covers several households) ==="
foreach ($a in $ambiguous) {
  Write-Host ("  {0,-32} {1} households: {2}" -f $a.scan, $a.households, (($a.people | Select-Object -First 4) -join ', ')) -ForegroundColor Yellow
}
Write-Host ""
Write-Host "=== NO CITATION MATCHES THESE SCANS ==="
$unmatched | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }

# ---------------------------------------------------------------- write
if ($Write) {
  $dst = Join-Path $root 'img/records'
  New-Item -ItemType Directory -Force $dst | Out-Null
  $out = [ordered]@{}
  foreach ($who in $attach.Keys) {
    $list = @()
    foreach ($d in $attach[$who]) {
      Copy-Item $d.file (Join-Path $dst $d.name) -Force
      $list += , [ordered]@{ img = "img/records/$($d.name)"; year = $d.year; page = $d.page }
    }
    $out[$who] = @($list | Sort-Object { $_.year })
  }
  [IO.File]::WriteAllText((Join-Path $root 'data/records.json'), ($out | ConvertTo-Json -Depth 6))
  Write-Host ""
  Write-Host "wrote data/records.json and copied $((Get-ChildItem $dst -File).Count) scans into img/records/"
}
