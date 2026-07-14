<#
Archive-Unused.ps1 — move the images the site never uses out of the branch folders.

Nothing is deleted. Everything moves to  Family\_Archive\  keeping its folder, so
any of it can be put straight back.

An image is KEPT in place if the built site publishes it (matched by content, not by
name). Everything else goes: the place photos that never made the cut, and the loose
record scans that RootsMagic already holds its own copy of.

The site does not read these folders at all — documents come from the RootsMagic media
library and live in site/img/ — so archiving them cannot break the build.

    pwsh tools/Archive-Unused.ps1            # dry run: say what would move
    pwsh tools/Archive-Unused.ps1 -Apply     # move it

NOTE ON POWERSHELL, because both of these bit me writing it:
  * variables are CASE-INSENSITIVE. $f as a loop variable silently overwrites $F.
    Names here are long and distinct on purpose.
  * a single-element array unrolls to a scalar, so $x[0] on a one-item list of
    strings returns the first CHARACTER. Every list is wrapped in @().
#>
param([switch]$Apply)

$ErrorActionPreference = 'Stop'
$siteDir = Split-Path -Parent $PSScriptRoot
$familyDir = Split-Path -Parent $siteDir
$archiveDir = Join-Path $familyDir '_Archive'
$mediaDir = Join-Path $familyDir 'Roots\Thompson Family Tree_media'

# every image the built site actually publishes, by content hash
$published = @{}
foreach ($img in @(Get-ChildItem (Join-Path $siteDir 'img') -Recurse -File -EA SilentlyContinue)) {
  $published[(Get-FileHash $img.FullName -Algorithm MD5).Hash] = $img.Name
}
Write-Host "site publishes $($published.Count) images"

$inRoots = @{}
foreach ($img in @(Get-ChildItem $mediaDir -Recurse -File -EA SilentlyContinue)) {
  $inRoots[$img.Name.ToLower()] = $true
}

$candidates = @(
  Get-ChildItem (Join-Path $familyDir 'Thompson'), (Join-Path $familyDir 'Ingleby') -Recurse -File -EA SilentlyContinue |
    Where-Object { $_.Extension -match '(?i)\.(jpg|jpeg|png|gif)$' }
)

$toMove = [System.Collections.Generic.List[object]]::new()
$keep = 0
foreach ($item in $candidates) {
  $hash = (Get-FileHash $item.FullName -Algorithm MD5).Hash
  if ($published.ContainsKey($hash)) { $keep++; continue }
  $toMove.Add($item)
}

$mb = [Math]::Round((($toMove | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host ""
Write-Host "keep (published by the site) : $keep"
Write-Host "archive                      : $($toMove.Count) files, $mb MB"
Write-Host ""

foreach ($grp in ($toMove | Group-Object { Split-Path (Split-Path $_.FullName -Parent) -Leaf } | Sort-Object Name)) {
  $inRootsCount = @($grp.Group | Where-Object { $inRoots.ContainsKey($_.Name.ToLower()) }).Count
  Write-Host ("  {0,-12} {1,3} files   ({2} of them RootsMagic already has)" -f $grp.Name, $grp.Count, $inRootsCount)
}

if (-not $Apply) {
  Write-Host ""
  Write-Host "dry run — re-run with -Apply to move them" -ForegroundColor Yellow
  return
}

$prefixLen = $familyDir.Length + 1
foreach ($item in $toMove) {
  $rel = $item.FullName.Substring($prefixLen)          # e.g. Ingleby\pics\B5_....jpg
  $dest = Join-Path $archiveDir $rel
  New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
  Move-Item $item.FullName $dest -Force
}
Write-Host ""
Write-Host "moved $($toMove.Count) files to _Archive\ — nothing deleted"
