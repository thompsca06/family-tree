<#
Apply-Theme.ps1 — one-shot: rewrite the page's colour literals to CSS custom
properties, so the palette lives in :root and nowhere else.

Run once. After this the theme is changed by editing :root in the <style> block.
Kept idempotent: re-running is a no-op because the literals are already gone.

    pwsh tools/Apply-Theme.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$file = Join-Path $root 'Family Tree.dc.html'
$t = [IO.File]::ReadAllText($file)

# The image lightbox keeps a DARK backdrop even on a light page — you view photos
# against black. Protect it from the sweep.
$KEEP = @{
  'rgba(10,8,5,.92)' = '__LIGHTBOX_SCRIM__'
}
foreach ($k in $KEEP.Keys) { $t = $t.Replace($k, $KEEP[$k]) }

# --- hex literals -> tokens -------------------------------------------------
$HEX = [ordered]@{
  # surfaces (dark -> light)
  '#221e17' = 'var(--bg)'
  '#272219' = 'var(--surface)'
  '#2c271f' = 'var(--surface)'
  '#1f1b14' = 'var(--surface)'
  '#191510' = 'var(--surface-2)'
  '#2d271e' = 'var(--surface-2)'
  '#302a21' = 'var(--surface-2)'
  '#14110c' = 'var(--surface-2)'
  '#1a1610' = 'var(--surface-2)'
  '#e9e2d2' = 'var(--surface-2)'
  '#372f25' = 'var(--hatch)'
  '#4a4336' = 'var(--line)'
  '#0e0c08' = 'var(--map-bg)'

  # text (light -> dark ink)
  '#efe9dd' = 'var(--ink)'
  '#e6ddcb' = 'var(--ink)'
  '#e8dcc6' = 'var(--ink)'
  '#cbc2af' = 'var(--ink-soft)'
  '#d8cfbd' = 'var(--ink-soft)'
  '#c9c0ad' = 'var(--ink-soft)'
  '#b7ad98' = 'var(--ink-soft)'
  '#a89e8a' = 'var(--ink-soft)'
  '#8a806c' = 'var(--ink-faint)'
  '#7a715f' = 'var(--ink-faint)'
  '#6d6455' = 'var(--ink-faint)'
  '#5c5344' = 'var(--ink-faint)'

  # accents
  '#c2542f' = 'var(--rust)'
  '#d67a54' = 'var(--rust)'
  '#e8926c' = 'var(--rust-dark)'
  '#b34a25' = 'var(--rust)'
  '#7fa87a' = 'var(--green)'
  '#5c8a6a' = 'var(--green)'
  '#4d7a52' = 'var(--green)'
  '#d8c9a0' = 'var(--sand)'
  '#c2b06a' = 'var(--sand)'
  '#9a7d3f' = 'var(--sand)'
  '#2b251c' = 'var(--ink)'
}

# --- rgba overlays ----------------------------------------------------------
# White overlays only read on a dark page. On cream they must become ink overlays.
$RGBA = [ordered]@{
  'rgba(255,255,255,.14)'  = 'rgba(43,37,28,.14)'
  'rgba(255,255,255,.12)'  = 'rgba(43,37,28,.12)'
  'rgba(255,255,255,.1)'   = 'rgba(43,37,28,.11)'
  'rgba(255,255,255,.09)'  = 'rgba(43,37,28,.10)'
  'rgba(255,255,255,.08)'  = 'rgba(43,37,28,.10)'
  'rgba(255,255,255,.07)'  = 'rgba(43,37,28,.09)'
  'rgba(255,255,255,.06)'  = 'rgba(43,37,28,.07)'
  'rgba(255,255,255,.05)'  = 'rgba(43,37,28,.06)'
  'rgba(255,255,255,.045)' = 'rgba(43,37,28,.05)'
  'rgba(255,255,255,.03)'  = 'rgba(43,37,28,.04)'

  # sticky nav + hero scrims: were near-black, now near-cream
  'rgba(23,20,15,.96)' = 'rgba(247,243,234,.96)'
  'rgba(23,20,15,.92)' = 'rgba(247,243,234,.92)'
  'rgba(23,20,15,.5)'  = 'rgba(247,243,234,.55)'
  # story-card photo scrim fades into the card, not out of it
  'rgba(34,30,23,.92)' = 'rgba(255,253,248,.94)'
  'rgba(34,30,23,.15)' = 'rgba(255,253,248,.10)'
  # selected-row tint
  'rgba(194,84,47,.22)' = 'rgba(179,74,37,.13)'

  # shadows: heavy black drop-shadows look filthy on cream
  'rgba(0,0,0,.6)'  = 'rgba(43,37,28,.28)'
  'rgba(0,0,0,.5)'  = 'rgba(43,37,28,.18)'
  'rgba(0,0,0,.4)'  = 'rgba(43,37,28,.13)'
  'rgba(0,0,0,.35)' = 'rgba(43,37,28,.10)'
  'rgba(0,0,0,.3)'  = 'rgba(43,37,28,.09)'
  'rgba(0,0,0,.15)' = 'rgba(43,37,28,.06)'
}

foreach ($k in $HEX.Keys) { $t = [regex]::Replace($t, [regex]::Escape($k), $HEX[$k], 'IgnoreCase') }
foreach ($k in $RGBA.Keys) { $t = $t.Replace($k, $RGBA[$k]) }

foreach ($k in $KEEP.Keys) { $t = $t.Replace($KEEP[$k], $k) }

[IO.File]::WriteAllText($file, $t)

# report anything the sweep missed
$left = [regex]::Matches($t, '#[0-9a-fA-F]{6}\b') | ForEach-Object { $_.Value.ToLower() } |
  Where-Object { $_ -notin '#ffffff', '#fff' } | Group-Object | Sort-Object Count -Desc
Write-Host "theme applied to Family Tree.dc.html"
if ($left) {
  Write-Host "remaining hex literals (check each is intentional):"
  $left | ForEach-Object { Write-Host ("  {0,3}x {1}" -f $_.Count, $_.Name) }
} else { Write-Host "no raw hex literals left" }
$white = ([regex]::Matches($t, 'rgba\(255,255,255')).Count
Write-Host "remaining white overlays: $white"
