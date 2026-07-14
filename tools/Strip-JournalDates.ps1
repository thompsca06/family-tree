<#
Strip-JournalDates.ps1 — take the research dates out of the journals.

Chris: "dont have dates on take them away".

The journals carried a date line under each heading (*5 July 2026*), which drove the
Diary's date headers and its ordering. They were also a standing source of trouble:
they were invented after the fact, they drifted into the future, and they implied a
precision about WHEN the research happened that nothing else on the site claims.

This removes ONLY the standalone italic date line. Dates that are FACTS — "died on
10 April 1893", "the 1881 census" — are prose and are left completely alone.

    pwsh tools/Strip-JournalDates.ps1            # show what would go
    pwsh tools/Strip-JournalDates.ps1 -Apply     # write it (backs up first)
#>
param([switch]$Apply)

$ErrorActionPreference = 'Stop'
$family = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$FILES = @(
  'Thompson\journal-in-service.md',
  'Thompson\journal-the-garforth-families.md',
  'Thompson\journal-whitehead-and-champion.md',
  'Ingleby\the-long-road-to-beeston.md',
  'Ingleby\up-the-midland-line.md'
)

# a line that is NOTHING BUT an italic date:  *5 July 2026*
$DATELINE = '^\*\s*\d{1,2}\s+\w+\s+(?:19|20)\d\d\s*\*\s*$'
# the one authorial aside that names the research month
$WRITTEN = '(?i)\s*Written\s+\w+\s+(?:19|20)\d\d\.\s*'

$backup = Join-Path $family ("_journal-backup-" + (Get-Random))
$total = 0

foreach ($rel in $FILES) {
  $path = Join-Path $family $rel
  if (-not (Test-Path $path)) { Write-Host "missing: $rel" -ForegroundColor Yellow; continue }

  $lines = [IO.File]::ReadAllLines($path)
  $out = [System.Collections.Generic.List[string]]::new()
  $n = 0
  foreach ($line in $lines) {
    if ($line -match $DATELINE) { $n++; continue }
    $out.Add(($line -replace $WRITTEN, ' '))
  }

  # a heading followed by the now-deleted date line can leave a double blank
  $clean = [System.Collections.Generic.List[string]]::new()
  foreach ($line in $out) {
    if (-not $line.Trim() -and $clean.Count -and -not $clean[$clean.Count - 1].Trim()) { continue }
    $clean.Add($line)
  }

  $total += $n
  Write-Host ("{0,-44} {1,3} date lines removed" -f (Split-Path $rel -Leaf), $n)

  if ($Apply -and $n) {
    New-Item -ItemType Directory -Force $backup | Out-Null
    Copy-Item $path (Join-Path $backup (Split-Path $rel -Leaf))
    [IO.File]::WriteAllLines($path, $clean)
  }
}

Write-Host ""
if ($Apply) { Write-Host "removed $total date lines. originals backed up to $backup" }
else { Write-Host "$total date lines would go — re-run with -Apply" -ForegroundColor Yellow }
