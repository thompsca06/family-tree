<#
Build-Site.ps1 — produce docs/, the standalone site for GitHub Pages.

    pwsh tools/Build-Site.ps1            # public build: living people redacted
    pwsh tools/Build-Site.ps1 -Private   # full build, for local use only

The .dc.html is a Claude design component: it uses React but never loads it,
because the claude.ai design host injects React/ReactDOM for it. docs/index.html
is the same page with those two script tags added, so it runs anywhere.

PRIVACY: the public build strips every fact about anyone who may still be living
(no death record + born within 100 years). Their records are not in the published
file at all — they are not merely hidden in the browser.
#>
param([switch]$Private)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'docs'   # GitHub Pages only serves / or /docs

# refuse to publish half a photo
Write-Host "== verifying images"
pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Verify-Images.ps1') -Report | Out-Host
if ($LASTEXITCODE -ne 0) { throw "refusing to build: images are missing or truncated (see above)" }

Write-Host "== rebuilding data"
& (Join-Path $PSScriptRoot 'Parse-Gedcom.ps1') | Out-Host

# rebuild the FULL data and prove nothing in the sources was lost, BEFORE the
# old docs/ is touched. The public build is this same data minus the deliberate
# living-people redaction, so a pass here covers what is about to be published.
Write-Host "== verifying nothing in the sources is lost"
& (Join-Path $PSScriptRoot 'Build-FamilyData.ps1') | Out-Host
pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Verify-Content.ps1') | Out-Host
if ($LASTEXITCODE -ne 0) { throw "refusing to build: content from the sources is missing from the site (see above)" }

# TRACKER.md and problems.txt are regenerated from the same fresh export, so they
# can never sit there stale telling you to do something you have already done.
# They are notes for the research, not part of the published site — a failure here
# must not stop a publish, so it is reported and stepped over.
Write-Host "== refreshing the tracker and the problem report"
try {
  & (Join-Path $PSScriptRoot 'New-Tracker.ps1') | Out-Host
  & (Join-Path $PSScriptRoot 'Find-Problems.ps1') | Out-Null
  Write-Host "  wrote data/problems.txt"
} catch {
  Write-Host "  !! report refresh failed (the site build is unaffected): $($_.Exception.Message)" -ForegroundColor Yellow
}

if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Force $dist | Out-Null

if ($Private) {
  & (Join-Path $PSScriptRoot 'Build-FamilyData.ps1') -Out 'docs/familydata.js' | Out-Host
} else {
  & (Join-Path $PSScriptRoot 'Build-FamilyData.ps1') -Public -Out 'docs/familydata.js' | Out-Host
}

Write-Host "== assembling docs/"
$html = [IO.File]::ReadAllText((Join-Path $root 'Family Tree.dc.html'))
# React is VENDORED, not pulled from unpkg. The design host injects React for the
# .dc.html; the published page has to bring its own. It used to fetch it from a CDN,
# which meant the entire site rendered as a BLANK PAGE if unpkg was slow, blocked, or
# the reader was offline — nothing on the page is progressive, it is all React.
# Now the only thing the site fetches from anywhere is the map tiles.
$react = @'
<script src="vendor/react.production.min.js"></script>
<script src="vendor/react-dom.production.min.js"></script>
'@
foreach ($lib in @('vendor/react.production.min.js', 'vendor/react-dom.production.min.js')) {
  if (-not (Test-Path (Join-Path $root $lib))) { throw "missing $lib - the published site would render blank" }
}
$html = $html -replace '(?i)(<head>)', "`$1`n$react"
[IO.File]::WriteAllText((Join-Path $dist 'index.html'), $html)

Copy-Item (Join-Path $root 'support.js') $dist
Copy-Item (Join-Path $root 'vendor') $dist -Recurse

# Copy ONLY the images the built site actually asks for — never the whole img/
# tree. Two reasons, both of which bit us:
#   1. PRIVACY. The public build strips a living person's documents from the data,
#      but a blanket copy still published the scan itself. Unlisted is not private.
#   2. Stale files. Match-Media doesn't prune, so images from an earlier media sync
#      linger on disk and would be published forever.
# Refs come from the built data AND from the page (the story hero photos are named
# in the component, not in familydata.js).
$imgRefs = [System.Collections.Generic.HashSet[string]]::new()
foreach ($src in @((Join-Path $dist 'familydata.js'), (Join-Path $dist 'index.html'))) {
  foreach ($m in [regex]::Matches([IO.File]::ReadAllText($src), 'img/[A-Za-z0-9_\-./]+\.(?:jpg|jpeg|png|gif|webp)')) {
    [void]$imgRefs.Add($m.Value)
  }
}
$copied = 0; $missingRefs = [System.Collections.Generic.List[string]]::new()
foreach ($rel in $imgRefs) {
  $from = Join-Path $root ($rel -replace '/', '\')
  if (-not (Test-Path $from)) { $missingRefs.Add($rel); continue }
  $to = Join-Path $dist ($rel -replace '/', '\')
  New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
  Copy-Item $from $to
  $copied++
}
$onDisk = @(Get-ChildItem (Join-Path $root 'img') -Recurse -File).Count
Write-Host ("  images: $copied published, " + ($onDisk - $copied) + " on disk but unused (not published)")
if ($missingRefs.Count) {
  Write-Host "  !! referenced but missing from disk:" -ForegroundColor Red
  $missingRefs | ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
  throw "refusing to build: the site references $($missingRefs.Count) image(s) that do not exist"
}
# stops GitHub Pages running the output through Jekyll (which ignores _ files)
[IO.File]::WriteAllText((Join-Path $dist '.nojekyll'), '')

$n = (Get-ChildItem $dist -Recurse -File).Count
$kb = [Math]::Round(((Get-ChildItem $dist -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host ""
Write-Host "docs/ ready — $n files, $kb MB$(if(-not $Private){'   [PUBLIC: living people redacted]'})"
