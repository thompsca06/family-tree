<#
Fix-JournalVoice.ps1 — put the journals in Chris's own voice.

They currently read as a research TEAM ("we recovered", "the wrong turn we had to
undo") and one line refers to him in the third person ("Chris's father"). The site
presents them as his research diary, so they should read as one person writing.

  we / us / our / ours   ->  I / me / my / mine
  Chris's father         ->  my father

Word-boundary matches only, and case is preserved. Run once; re-running is a no-op.

    pwsh tools/Fix-JournalVoice.ps1            # show what would change
    pwsh tools/Fix-JournalVoice.ps1 -Apply     # write it
#>
param([switch]$Apply)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$family = Split-Path -Parent $root

$FILES = @(
  'Thompson\journal-the-garforth-families.md',
  'Thompson\journal-whitehead-and-champion.md',
  'Ingleby\the-long-road-to-beeston.md',
  'Ingleby\up-the-midland-line.md'
)

# Order matters: longer forms first, so "we're" isn't half-eaten by "we".
# A LIST, not a hashtable — PowerShell hashtable keys are case-insensitive, so
# 'we' and 'We' would collide and only one would survive.
$RULES = @(
  @("Chris's father", 'my father'),
  @("Chris's", 'my'),
  @('\bwe are\b', 'I am'),
  @('\bWe are\b', 'I am'),
  @("\bwe're\b", "I'm"),
  @("\bWe're\b", "I'm"),
  @("\bwe've\b", "I've"),
  @("\bWe've\b", "I've"),
  @("\bwe'd\b", "I'd"),
  @("\bWe'd\b", "I'd"),
  @('\bwe\b', 'I'),
  @('\bWe\b', 'I'),
  @('\bours\b', 'mine'),
  @('\bOurs\b', 'Mine'),
  @('\bourselves\b', 'myself'),
  @('\bour\b', 'my'),
  @('\bOur\b', 'My'),
  @('\bus\b', 'me'),
  @('\bUs\b', 'Me')
)

$totals = 0
foreach ($rel in $FILES) {
  $path = Join-Path $family $rel
  if (-not (Test-Path $path)) { Write-Host "missing: $rel" -ForegroundColor Yellow; continue }
  $txt = [IO.File]::ReadAllText($path)
  $orig = $txt
  $n = 0
  foreach ($r in $RULES) {
    $pat = $r[0]; $rep = $r[1]
    $hits = ([regex]::Matches($txt, $pat)).Count      # case-SENSITIVE by default
    if ($hits) { $n += $hits; $txt = [regex]::Replace($txt, $pat, $rep) }
  }

  # "I" needs the verb to agree: "I was" not "I were", "I do not know" not "I do"
  $txt = [regex]::Replace($txt, '\bI were\b', 'I was')
  $txt = [regex]::Replace($txt, '\bI have been\b', 'I have been')

  if ($txt -ne $orig) {
    $totals += $n
    Write-Host ("{0,-46} {1} changes" -f (Split-Path $rel -Leaf), $n)
    if ($Apply) { [IO.File]::WriteAllText($path, $txt) }
  } else {
    Write-Host ("{0,-46} already first person" -f (Split-Path $rel -Leaf))
  }
}

Write-Host ""
if ($Apply) { Write-Host "applied $totals changes" }
else { Write-Host "$totals changes pending — re-run with -Apply to write them" -ForegroundColor Yellow }
