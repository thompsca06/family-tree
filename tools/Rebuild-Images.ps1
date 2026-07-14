<#
Rebuild-Images.ps1 — rebuild site/img/ from the ORIGINAL photos on disk.

Why: DesignSync get_file caps a response at 256 KiB, so any image larger than
~192 KB comes back truncated and corrupt. But the design project's images turn
out to be byte-for-byte copies of the originals already in Thompson/ and
Ingleby/ — verified by hash on the three that fit under the cap.

So instead of guessing which original is which, this MATCHES them: a truncated
download must be an exact byte PREFIX of its original. That identifies each file
with certainty. Anything that cannot be matched is reported, never guessed.

    pwsh tools/Rebuild-Images.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$family = Split-Path -Parent $root

# every candidate original on disk
$candidates = @(
  Get-ChildItem (Join-Path $family 'Ingleby') -Recurse -File -Include *.jpg, *.jpeg, *.png
  Get-ChildItem (Join-Path $family 'Thompson') -Recurse -File -Include *.jpg, *.jpeg, *.png
)
Write-Host "candidate originals on disk: $($candidates.Count)"

# Pairings ESTABLISHED by byte-prefix match against the design project's own
# copies (see header). Not guesswork — each was confirmed by comparing the
# leading bytes of the design file with the original. Recorded so the mapping
# survives once the truncated downloads are cleaned away.
# Note mickley is M2, not M1 — which is exactly why this was matched, not assumed.
$VERIFIED = @{
  'img/places/azerley.jpg'      = 'Z1_azerley_mill_farm.jpg'
  'img/places/elland_road.jpg'  = 'A4_elland_road_leeds.jpg'
  'img/places/hunslet.jpg'      = 'B3_hunslet_moor_corner.jpg'
  'img/places/jack_lane.jpg'    = 'B1_jack_lane_holbeck.jpg'
  'img/places/mickley.jpg'      = 'M2_mickley_the_main_street.jpg'
  'img/places/bathley_st.jpg'   = 'A6_bathley_street_meadows_1.jpg'
  'img/places/dewsbury_road.jpg' = 'B2_dewsbury_road_leeds.jpg'
  'img/places/throstle_middleton.jpg' = 'A1_throstle_row_middleton.jpg'
  'img/war/brux_plant.jpg'      = '6a_brux_plant_NARA_884.jpg'
  'img/war/harry_mi9.jpg'       = 'Ingleby Harry - Page 1.jpg'
  'img/war/pow_capture_1942.jpg' = '5_pow_capture_desert_1942.jpg'
  'img/war/troopship_1941.jpg'  = '2_troopship_convoy_WS12_1941.jpg'
}

# what the page needs
$html = Get-Content (Join-Path $root 'Family Tree.dc.html') -Raw
$refs = [regex]::Matches($html, 'img/[A-Za-z0-9_/.-]*\.(?:png|jpg)') | ForEach-Object { $_.Value } | Sort-Object -Unique

$matched = 0; $already = 0
$unmatched = @()

foreach ($ref in $refs) {
  $dest = Join-Path $root $ref
  if (Test-Path $dest) {
    $b = [IO.File]::ReadAllBytes($dest)
    $isJpg = $ref -match '(?i)\.jpe?g$'
    $complete = if ($isJpg) { ($b[-2] -eq 0xFF -and $b[-1] -eq 0xD9) } else { $b.Length -ne 196608 }
    if ($complete) { $already++; continue }   # good file already there
  } else { $b = $null }

  # find the original whose leading bytes match the (possibly truncated) download
  $hit = $null
  if ($b) {
    foreach ($c in $candidates) {
      $cb = [IO.File]::ReadAllBytes($c.FullName)
      if ($cb.Length -lt $b.Length) { continue }
      $same = $true
      for ($i = 0; $i -lt $b.Length; $i++) { if ($cb[$i] -ne $b[$i]) { $same = $false; break } }
      if ($same) { $hit = $c; break }
    }
  }
  # nothing to match against (the corrupt copy was cleaned away) — fall back to the
  # pairing already established by byte-prefix in an earlier run
  if (-not $hit -and $VERIFIED.ContainsKey($ref)) {
    $hit = $candidates | Where-Object { $_.Name -eq $VERIFIED[$ref] } | Select-Object -First 1
  }

  if ($hit) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
    Copy-Item $hit.FullName $dest -Force
    $matched++
    Write-Host ("  {0,-36} <- {1}" -f $ref, $hit.Name) -ForegroundColor Green
  } else {
    $unmatched += $ref
    if ($b) { Remove-Item $dest -Force }   # never keep a corrupt image
  }
}

Write-Host ""
Write-Host "already complete : $already"
Write-Host "restored by match: $matched"
Write-Host "UNMATCHED        : $($unmatched.Count)"
$unmatched | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
