<#
Match-Media.ps1 — attach the photos and documents to the right people, using the
RootsMagic database as the authority.

Why this exists: Ancestry's GEDCOM lists 33 media objects but leaves every FILE
line EMPTY — you get the pixel width and nothing else. The images cannot be
matched to people from the GEDCOM at all. Matching them by filename against
archive references (Match-Records.ps1) works, but a census piece covers several
households, so 43 scans could not be resolved that way.

The RootsMagic file (Roots/Thompson Family Tree.rmtree) is a SQLite database and
it holds the links outright, because that is where they were made:

    MultimediaTable                 the 288 files
    MediaLinkTable  OwnerType=0     -> straight to a PERSON  (photos, graves, houses)
    MediaLinkTable  OwnerType=4     -> to a CITATION -> EVENT -> PERSON  (record scans)
    IsPrimary=1                     -> the portrait

The one join it cannot give us is RootsMagic PersonID -> Ancestry GEDCOM xref;
the two use different numbering. So people are matched on SURNAME + GIVEN + BIRTH
YEAR. Any name that is ambiguous (two people, same name, same year) is REPORTED
and skipped — a photograph on the wrong man is exactly the error this project
exists to avoid.

    pwsh tools/Match-Media.ps1           # report only
    pwsh tools/Match-Media.ps1 -Write    # copy files + emit data/media.json
#>
param(
  [switch]$Write,
  [string]$Sqlite = "C:\Users\Chris\AppData\Local\Android\Sdk\platform-tools\sqlite3.exe"
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$family = Split-Path -Parent $root
$db = Join-Path $family 'Roots\Thompson Family Tree.rmtree'
$mediaDir = Join-Path $family 'Roots\Thompson Family Tree_media'

if (-not (Test-Path $Sqlite)) { throw "sqlite3.exe not found at $Sqlite" }
if (-not (Test-Path $db)) { throw "RootsMagic file not found: $db" }

# never work on the live tree
$tmp = Join-Path $env:TEMP 'rm_readonly.rmtree'
Copy-Item $db $tmp -Force

function Q([string]$sql) { & $Sqlite -separator "`t" $tmp $sql }

# ---------------------------------------------------------------- RootsMagic
# people, with birth year pulled out of RM's "D.+18960928.." date format
$rmPeople = @{}
foreach ($r in (Q @"
SELECT p.PersonID, coalesce(n.Surname,''), coalesce(n.Given,''),
       coalesce((SELECT substr(e.Date,4,4) FROM EventTable e
                 WHERE e.OwnerType=0 AND e.OwnerID=p.PersonID AND e.EventType IN (1,2)
                 ORDER BY e.EventType LIMIT 1),'')
FROM PersonTable p LEFT JOIN NameTable n ON n.OwnerID=p.PersonID AND n.IsPrimary=1;
"@)) {
  $c = $r -split "`t"
  if ($c.Count -lt 4) { continue }
  $rmPeople[$c[0]] = @{ sur = $c[1].Trim(); giv = $c[2].Trim(); by = ($c[3] -replace '\D', '') }
}

# every media link, resolved to a PersonID
#   OwnerType 0 = person   OwnerType 4 = citation -> event -> person
$links = @()
# the record half also brings the EVENT YEAR, so a document can be dated
foreach ($r in (Q @"
SELECT ml.OwnerID, m.MediaFile, coalesce(m.Caption,''), ml.IsPrimary, 'person', '', ''
FROM MediaLinkTable ml JOIN MultimediaTable m ON m.MediaID=ml.MediaID
WHERE ml.OwnerType=0
UNION ALL
SELECT e.OwnerID, m.MediaFile, coalesce(m.Caption,''), 0, 'record', coalesce(s.Name,''), substr(coalesce(e.Date,''),4,4) || '#' || e.EventType
FROM MediaLinkTable ml
JOIN MultimediaTable m   ON m.MediaID=ml.MediaID
JOIN CitationLinkTable cl ON cl.CitationID=ml.OwnerID AND cl.OwnerType=2
JOIN EventTable e         ON e.EventID=cl.OwnerID AND e.OwnerType=0
JOIN CitationTable ct     ON ct.CitationID=ml.OwnerID
LEFT JOIN SourceTable s   ON s.SourceID=ct.SourceID
WHERE ml.OwnerType=4;
"@)) {
  $c = $r -split "`t"
  if ($c.Count -lt 7) { continue }
  $srcName = $c[5]
  $evParts = $c[6] -split '#'
  $evYear = ($evParts[0] -replace '[^0-9]', '')
  $evType = if ($evParts.Count -gt 1) { $evParts[1] } else { '' }

  # Dating a document, in order of trust:
  #  1. a source whose name BEGINS with a year — "1921 England Census". Definitive.
  #  2. otherwise the event the citation hangs on — UNLESS that event is the birth
  #     or baptism, because Ancestry hangs unrelated sources there as a catch-all.
  #  3. otherwise no year at all.
  #
  # Not "any year in the source name": "Electoral Registers, 1840-1962" is a range,
  # and taking 1840 from it dated Harry's 1949 register to 1840. Not the event
  # alone either: his POW questionnaire and his medal card both hang off his birth,
  # and came out as 1915. Tommy's eleven service-record pages came out as 1919.
  # A wrong date on a document is worse than no date.
  $isBirth = ($evType -eq '1' -or $evType -eq '2')
  $yr = ''
  if ($srcName -match '^\s*(1[6-9]\d\d|20\d\d)\b') { $yr = $matches[1] }
  elseif ($evYear -and -not $isBirth) { $yr = $evYear }

  $links += , @{ rmid = $c[0]; file = $c[1]; caption = $c[2]; primary = ($c[3] -eq '1'); kind = $c[4]; year = $yr; source = $srcName }
}
Write-Host "RootsMagic: $($rmPeople.Count) people, $($links.Count) media links"
if ($env:FTDEBUG) {
  Write-Host "  sample rmPeople:"
  foreach ($k in @('1', '4', '8', '44', '46')) { Write-Host "    [$k] = $($rmPeople[$k].giv) $($rmPeople[$k].sur) b.$($rmPeople[$k].by)" }
  Write-Host "  sample links:"
  $links | Select-Object -First 5 | ForEach-Object { Write-Host "    rmid=$($_.rmid) kind=$($_.kind) file=$($_.file)" }
  Write-Host "  distinct rmids in links: $((@($links | ForEach-Object { $_.rmid }) | Sort-Object -Unique).Count)"
}

# ---------------------------------------------------------------- GEDCOM side
$G = Get-Content (Join-Path $root 'data/gedcom.json') -Raw | ConvertFrom-Json
$byKey = @{}
foreach ($id in $G.people.PSObject.Properties.Name) {
  $p = $G.people.$id
  $b = ($p.events | Where-Object { $_.tag -in 'BIRT', 'BAPM', 'CHR' } | Select-Object -First 1).date
  $by = if ($b -and $b -match '(\d{4})') { $matches[1] } else { '' }
  $key = (("$($p.surn)|$($p.givn)|$by") -replace '\s+', ' ').ToLower()
  if (-not $byKey[$key]) { $byKey[$key] = @() }
  $byKey[$key] += $id
}

# ---------------------------------------------------------------- match
$photos = @{}; $docs = @{}
$ambiguous = @(); $noPerson = @(); $noFile = @()

foreach ($l in $links) {
  $rm = $rmPeople[$l.rmid]
  if (-not $rm) { continue }
  $key = (("$($rm.sur)|$($rm.giv)|$($rm.by)") -replace '\s+', ' ').ToLower()
  # Two PowerShell traps in one line, both of which silently corrupt the match:
  #   * @($null) is a ONE-element array holding null, so always check the key exists
  #   * an `if` expression UNROLLS a single-element array to a scalar, so $hit would
  #     become the id STRING and $hit[0] would index its first CHARACTER ("I"),
  #     putting every photo on a person called "I".
  # Wrap the whole conditional in @( ) to keep it an array.
  $hit = @( if ($byKey.ContainsKey($key)) { , @($byKey[$key]) } else { , @() } )
  $hit = @($hit[0])

  if ($hit.Count -eq 0) { $noPerson += "$($rm.giv) $($rm.sur) (b.$($rm.by)) -> $($l.file)"; continue }
  if ($hit.Count -gt 1) { $ambiguous += "$($rm.giv) $($rm.sur) (b.$($rm.by)) matches $($hit.Count) people -> $($l.file)"; continue }
  $gid = [string]$hit[0]
  if ($env:FTDEBUG -and $dbgN -lt 5) { Write-Host "    MATCH rm=$($l.rmid) '$key' -> $gid"; $dbgN++ }

  $src = Join-Path $mediaDir $l.file
  if (-not (Test-Path $src)) { $noFile += $l.file; continue }
  if ($l.file -notmatch '(?i)\.(jpg|jpeg|png)$') { continue }   # a .doc is in there

  # Ancestry's filenames carry spaces and commas ("UK, WWII, British Army Medal
  # Cards, 1939-1945 Ingleby, Harr.jpg"). Those are a nuisance in a URL, so the
  # published copy gets a safe name. The caption keeps the human wording.
  $ext = [IO.Path]::GetExtension($l.file)
  $stem = [IO.Path]::GetFileNameWithoutExtension($l.file)
  $safe = ((($stem -replace '[^A-Za-z0-9._-]', '_') -replace '_+', '_').Trim('_')) + $ext.ToLower()
  $cap = if ($l.source) { $l.source } elseif ($l.caption) { $l.caption } else { $stem }

  $entry = [ordered]@{ img = "img/media/$safe"; caption = $cap; primary = $l.primary; year = $l.year; src = $src; safe = $safe }
  if ($l.kind -eq 'person') {
    if (-not $photos[$gid]) { $photos[$gid] = @() }
    if (-not ($photos[$gid] | Where-Object { $_.img -eq $entry.img })) { $photos[$gid] += , $entry }
  } else {
    if (-not $docs[$gid]) { $docs[$gid] = @() }
    if (-not ($docs[$gid] | Where-Object { $_.img -eq $entry.img })) { $docs[$gid] += , $entry }
  }
}

$allPeople = @($photos.Keys) + @($docs.Keys) | Sort-Object -Unique
Write-Host ""
Write-Host "  people with photos    : $($photos.Count)"
Write-Host "  people with documents : $($docs.Count)"
Write-Host "  people with anything  : $($allPeople.Count)"
Write-Host "  distinct files used   : $((@($photos.Values) + @($docs.Values) | ForEach-Object { $_ } | ForEach-Object { $_.img } | Sort-Object -Unique).Count)"
Write-Host ""
Write-Host "  AMBIGUOUS (same name + year, skipped): $($ambiguous.Count)" -ForegroundColor Yellow
$ambiguous | Select-Object -Unique -First 12 | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkYellow }
Write-Host "  RM person not in the GEDCOM         : $(@($noPerson | Sort-Object -Unique).Count)" -ForegroundColor Yellow
Write-Host "  media file missing from disk        : $(@($noFile | Sort-Object -Unique).Count)" -ForegroundColor Yellow

# ---------------------------------------------------------------- write
# These are full-resolution archive scans — 185 MB across 248 files, up to 3 MB
# each. Shipping them as-is would bloat the repo and make every card a 3 MB
# download. So each one is written twice:
#   <name>.jpg     max 1600px  — readable in the lightbox
#   <name>_t.jpg   max 420px   — the card thumbnail
Add-Type -AssemblyName System.Drawing

function Save-Scaled {
  param([string]$src, [string]$dest, [int]$max, [int]$quality)
  $img = [Drawing.Image]::FromFile($src)
  try {
    $scale = [Math]::Min(1.0, $max / [Math]::Max($img.Width, $img.Height))
    $w = [int]([Math]::Round($img.Width * $scale)); $h = [int]([Math]::Round($img.Height * $scale))
    $bmp = [Drawing.Bitmap]::new($w, $h)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($img, 0, 0, $w, $h)
    $g.Dispose()
    $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
    $pars = [Drawing.Imaging.EncoderParameters]::new(1)
    $pars.Param[0] = [Drawing.Imaging.EncoderParameter]::new([Drawing.Imaging.Encoder]::Quality, [int64]$quality)
    $bmp.Save($dest, $enc, $pars)
    $bmp.Dispose()
  } finally { $img.Dispose() }
}

if ($Write) {
  $out = Join-Path $root 'img/media'
  New-Item -ItemType Directory -Force $out | Out-Null
  $doc = [ordered]@{}
  foreach ($gid in $allPeople) {
    $ph = @($photos[$gid]); $dc = @($docs[$gid])
    foreach ($e in ($ph + $dc)) {
      if (-not $e) { continue }
      $full = Join-Path $out $e.safe
      $thumb = Join-Path $out ([IO.Path]::GetFileNameWithoutExtension($e.safe) + '_t.jpg')
      if (-not (Test-Path $full)) { Save-Scaled $e.src $full 1600 80 }
      if (-not (Test-Path $thumb)) { Save-Scaled $e.src $thumb 420 72 }
    }
    $doc[$gid] = [ordered]@{
      photos = @($ph | Where-Object { $_ } | ForEach-Object { [ordered]@{ img = $_.img; thumb = ($_.img -replace '\.\w+$', '_t.jpg'); caption = $_.caption; primary = $_.primary } })
      docs   = @($dc | Where-Object { $_ } | Sort-Object { $_.year } | ForEach-Object { [ordered]@{ img = $_.img; thumb = ($_.img -replace '\.\w+$', '_t.jpg'); caption = $_.caption; year = $_.year } })
    }
  }
  [IO.File]::WriteAllText((Join-Path $root 'data/media.json'), ($doc | ConvertTo-Json -Depth 6))
  $sz = [Math]::Round((Get-ChildItem $out -File | Measure-Object Length -Sum).Sum / 1MB, 1)
  Write-Host ""
  Write-Host "wrote data/media.json; $((Get-ChildItem $out -File).Count) files in img/media/ ($sz MB, was 185 MB)"
}
