<#
    Start-Session.ps1 — run this FIRST, every session, before any research.

    Why this exists: the loop's step 1 (re-export) kept getting skipped, because it was a
    judgement call ("has anything changed?") and the judgement was made badly. A stale
    TRACKER.md / problems.txt reports FINISHED work as outstanding, so a session gets spent
    re-doing jobs that were already done. This script removes the judgement.

    It does NOT export for you — only the browser can do that. It tells you, unambiguously,
    whether the local files can be trusted, then regenerates and prints the buckets in
    largest-first order so the prioritisation rule is computed rather than remembered.

    Usage:  pwsh site/tools/Start-Session.ps1            # check + regenerate + report
            pwsh site/tools/Start-Session.ps1 -Install   # after downloading a fresh export
#>
param(
    [switch]$Install,      # install the newest export from Downloads, then regenerate
    [switch]$SkipRegen     # just report, don't re-run the generators
)

$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $PSScriptRoot          # ...\site
$fam   = Split-Path -Parent $root                  # ...\Family
$ged   = Join-Path $root 'src\thompson_tree.ged'
$zip   = Join-Path $fam  'Thompson Family Tree.zip'

function Line { param($c='DarkGray') Write-Host ('-' * 78) -ForegroundColor $c }
function Head { param($t) Write-Host ''; Write-Host $t -ForegroundColor Cyan; Line }

Head 'STEP 1 - IS THE EXPORT CURRENT?'

# The trap: comparing the zip to the ged proves NOTHING if the zip is itself an old download.
# It only shows the last export was installed. So report ages, and never claim "unchanged".
$gedInfo = Get-Item $ged
$zipInfo = if (Test-Path $zip) { Get-Item $zip } else { $null }
$ageHrs  = [math]::Round(((Get-Date) - $gedInfo.LastWriteTime).TotalHours, 1)

Write-Host ("  working GEDCOM : {0}  ({1} bytes, {2}h old)" -f $gedInfo.LastWriteTime, $gedInfo.Length, $ageHrs)
if ($zipInfo) { Write-Host ("  last zip       : {0}  ({1} bytes)" -f $zipInfo.LastWriteTime, $zipInfo.Length) }

# Is there something newer sitting in Downloads (incl. the unnamed .tmp Ancestry drops)?
$dl = Join-Path $env:USERPROFILE 'Downloads'
$newer = @()
# Compare by CONTENT, not timestamp: Expand-Archive preserves the GEDCOM's internal
# mtime, so the installed .ged is always "older" than the download it came from. A
# false alarm every session would train us to ignore the one warning that matters.
$installedHash = if ($zipInfo) { (Get-FileHash $zip).Hash } else { $null }
if (Test-Path $dl) {
    $newer = Get-ChildItem $dl -File -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -gt $gedInfo.LastWriteTime.AddMinutes(-5) -and
                            ($_.Extension -in '.zip', '.tmp' -or $_.Name -like '*Thompson*') } |
             Where-Object { (Get-FileHash $_.FullName).Hash -ne $installedHash } |
             Sort-Object LastWriteTime -Descending
}
if ($newer) {
    Write-Host ''
    Write-Host '  ** UNINSTALLED EXPORT(S) FOUND IN Downloads: **' -ForegroundColor Yellow
    $newer | Select-Object -First 5 | ForEach-Object {
        $isZip = $false
        try { Add-Type -AssemblyName System.IO.Compression.FileSystem
              $z = [System.IO.Compression.ZipFile]::OpenRead($_.FullName); $isZip = $true; $z.Dispose() } catch {}
        Write-Host ("     {0}  {1} bytes  {2}" -f $_.LastWriteTime, $_.Length, $_.Name) -ForegroundColor Yellow
        Write-Host ("        valid zip: {0}" -f $(if($isZip){'YES - run with -Install'}else{'no'}))
    }
}

Write-Host ''
Write-Host '  >> DO NOT conclude "nothing changed" by comparing the zip to the GEDCOM.' -ForegroundColor Yellow
Write-Host '     An old download matches, and proves only that it was installed.' -ForegroundColor Yellow
Write-Host '     If ANY tree edit has happened since the timestamp above, EXPORT AGAIN:' -ForegroundColor Yellow
Write-Host '     Settings -> Export tree -> Export -> (~30s) -> Download your GEDCOM file' -ForegroundColor Yellow

if ($Install) {
    if (-not $newer) { Write-Host ''; Write-Host '  -Install given but nothing newer found in Downloads.' -ForegroundColor Red; exit 1 }
    $src = $newer[0]
    Head 'INSTALLING NEW EXPORT'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    Copy-Item $ged "$ged.bak-$stamp" -Force
    Write-Host "  backed up -> thompson_tree.ged.bak-$stamp"
    Copy-Item $src.FullName $zip -Force
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ged-" + $stamp)
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $tmpDir -Force
    $inner = Get-ChildItem $tmpDir -Filter *.ged -Recurse | Select-Object -First 1
    Copy-Item $inner.FullName $ged -Force
    Write-Host ("  installed  -> {0} bytes, {1} people" -f (Get-Item $ged).Length,
                (Select-String -Path $ged -Pattern '^0 @I').Count) -ForegroundColor Green
}

if (-not $SkipRegen) {
    Head 'STEP 2 - REGENERATE'
    Push-Location $root
    try {
        & .\tools\Parse-Gedcom.ps1  | Out-Host
        & .\tools\New-Tracker.ps1   | Out-Host
        & .\tools\Find-Problems.ps1 | Out-Null
        Write-Host '  wrote data/problems.txt' -ForegroundColor Green
    } finally { Pop-Location }
}

# ---------------------------------------------------------------- the buckets
Head 'STEP 3 - THE BUCKETS, LARGEST FIRST (work the top one, right through)'

$probFile = Join-Path $root 'data\problems.txt'
$tracker  = Join-Path $fam  'TRACKER.md'
$prob     = Get-Content $probFile
$buckets  = @()

function Count-Section {
    param($name, $pattern)
    $m = $prob | Select-String -Pattern $pattern | Select-Object -First 1
    if ($m -and $m.Line -match '(\d+)') { return [int]$Matches[1] }
    return 0
}

$buckets += [pscustomobject]@{ Bucket='S6 not connected';        Count=(Count-Section 6 '-> (\d+) people not connected');            Note='STRUCTURE - do first; one link can move dozens' }
$buckets += [pscustomobject]@{ Bucket='S2 parents not a couple'; Count=(Count-Section 2 '-> (\d+) people affected');                 Note='STRUCTURE' }
$buckets += [pscustomobject]@{ Bucket='S2b one-parent dup';      Count=(Count-Section 2 '-> (\d+) children in a one-parent');        Note='STRUCTURE' }
$buckets += [pscustomobject]@{ Bucket='S1 possible duplicates';  Count=(Count-Section 1 '-> (\d+) name-groups');                     Note='STRUCTURE - mostly FALSE POSITIVES, check FAMC/FAMS' }
$buckets += [pscustomobject]@{ Bucket='S7 trades to add';        Count=(Count-Section 7 '-> (\d+) of \d+ still to add');             Note='occupations' }
$buckets += [pscustomobject]@{ Bucket='S8 transcriptions';       Count=(Count-Section 8 '-> (\d+) of \d+ still to correct');         Note='occupations' }
$buckets += [pscustomobject]@{ Bucket='S9 trade words';          Count=(Count-Section 9 '-> (\d+) trade words');                     Note='occupations' }

# tracker gaps, by kind — this is the sourcing queue and usually the biggest thing on the board
if (Test-Path $tracker) {
    $t = Get-Content $tracker
    $miss = $t | Where-Object { $_ -match '\*\*missing:\*\*' }
    $cens = ($miss | Where-Object { $_ -match 'census' }).Count
    $deat = ($miss | Where-Object { $_ -match 'death/burial' }).Count
    $marr = ($miss | Where-Object { $_ -match 'marriage' }).Count
    $birt = ($miss | Where-Object { $_ -match 'birth/baptism' }).Count
    $buckets += [pscustomobject]@{ Bucket='TRACKER missing censuses'; Count=$cens; Note='sourcing queue' }
    $buckets += [pscustomobject]@{ Bucket='TRACKER missing death';    Count=$deat; Note='sourcing queue' }
    $buckets += [pscustomobject]@{ Bucket='TRACKER missing marriage'; Count=$marr; Note='sourcing queue' }
    $buckets += [pscustomobject]@{ Bucket='TRACKER missing birth';    Count=$birt; Note='sourcing queue' }
    $hdr = $t | Select-String -Pattern 'direct ancestors' | Select-Object -First 1
    if ($hdr) { Write-Host ("  {0}" -f ($hdr.Line -replace '\*\*','')) -ForegroundColor White; Write-Host '' }
}

$buckets | Where-Object { $_.Count -gt 0 } | Sort-Object Count -Descending |
    Format-Table @{n='count';e={$_.Count};w=6}, @{n='bucket';e={$_.Bucket};w=26}, @{n='note';e={$_.Note}} -AutoSize |
    Out-Host

$top = $buckets | Where-Object { $_.Count -gt 0 -and $_.Note -like 'STRUCTURE*' } | Sort-Object Count -Descending | Select-Object -First 1
if (-not $top) { $top = $buckets | Where-Object { $_.Count -gt 0 } | Sort-Object Count -Descending | Select-Object -First 1 }
Write-Host ("  >> STRUCTURE BEFORE SOURCING. Start here: {0} ({1})" -f $top.Bucket, $top.Count) -ForegroundColor Green

# ---------------------------------------------------------------- reminders
Head 'STEP 4 - BEFORE YOU RESEARCH'
@(
 'READ FIRST: HANDOVER.md, RULES-AND-INSTRUCTIONS.md, AGENT-NOTES.md, JOURNAL.md - all of them.',
 'CHECK SOURCES before searching on a fact. An unsourced birth year filters real records OUT.',
 'OPEN EVERY DOCUMENT. The index is not the record - a bride''s father is often only on the image.',
 'Read REGISTER images first, CENSUS images last (a census image kills screenshots session-wide).',
 'One item blocking does NOT end the bucket - log it in leads.json and take the next item.',
 'A broken mechanism is not absent evidence. Merge screen scary? Untick every box, Save = citation only.',
 'Nothing is done until it is on the tree WITH its source, then in JOURNAL.md, then in a story.'
) | ForEach-Object { Write-Host "   - $_" }

Write-Host ''
Line
Write-Host ' When the work is finished: RE-EXPORT and re-run this script, or the next' -ForegroundColor DarkGray
Write-Host ' session inherits stale reports and re-does jobs that are already done.'   -ForegroundColor DarkGray
Line
