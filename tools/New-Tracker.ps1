<#
New-Tracker.ps1 - GENERATE the sourcing tracker from the tree itself.

The hand-written tracker is the file that rots. Today alone it claimed the whole
maternal line was unsourced (it wasn't) and pointed at a journal file that does not
exist. That is not carelessness - it is what happens to any file that has to be kept
in step with a tree by hand. So it stops being written by hand.

Everything a tracker asserts about COMPLETENESS is already in the GEDCOM: who has a
birth, a marriage, a death, which censuses are attached, how many sources hang off
each fact. This reads the export and writes the status out. Re-run it after every
download and it is true again by construction.

What this file does NOT hold, because it cannot be derived:
  * WHY an identification was accepted, and who was rejected  -> the journals
  * what to search next                                       -> the worklist

    pwsh tools/New-Tracker.ps1            # -> Family/TRACKER.md
#>
param([string]$GedJson = 'data/gedcom.json')

$ErrorActionPreference = 'Stop'
$siteDir = Split-Path -Parent $PSScriptRoot
$familyDir = Split-Path -Parent $siteDir
$G = Get-Content (Join-Path $siteDir $GedJson) -Raw | ConvertFrom-Json
$PPL = $G.people
$FAMS = $G.fams
$ROOTID = 'I352128205181'          # Chris
$THIS_YEAR = 2026
$BT = [char]0x60                   # backtick, for markdown code spans

# How many scans are actually attached to each person. This CANNOT come from the
# GEDCOM: Ancestry exports media objects with an empty FILE line, so the export
# knows a photo exists but not where it is. The real links live in the RootsMagic
# database and land in familydata.js, so read the count back from there.
$docCount = @{}
$fdPath = Join-Path $siteDir 'familydata.js'
if (Test-Path $fdPath) {
  $fd = ((Get-Content $fdPath -Raw) -replace '^window\.FAMILY = ', '' -replace ';\s*$', '') | ConvertFrom-Json
  foreach ($prop in $fd.people.PSObject.Properties) {
    $docCount[$prop.Name] = @($prop.Value.docs).Count + @(if ($prop.Value.photo) { 1 }).Count
  }
}

function Get-Year { param($d) if ($d -and $d -match '(\d{4})') { [int]$matches[1] } else { $null } }
function Get-Name { param($who) (("$($who.givn) $($who.surn)") -replace '\s+', ' ').Trim() }

# parents of a person, via the family they are a child in
function Get-Parents {
  param([string]$id)
  $out = @()
  foreach ($fid in @($PPL.$id.famc)) {
    $fam = $FAMS.$fid
    if (-not $fam) { continue }
    foreach ($par in @($fam.husb, $fam.wife)) { if ($par) { $out += $par } }
  }
  return @($out)
}

# ---- walk the direct line, generation by generation -------------------------
$gens = @{}
$seen = @{}
$queue = @([pscustomobject]@{ id = $ROOTID; gen = 1 })
while ($queue.Count) {
  $cur = $queue[0]
  $queue = @($queue | Select-Object -Skip 1)
  if ($seen.ContainsKey($cur.id)) { continue }
  $seen[$cur.id] = $true
  if (-not $gens.ContainsKey($cur.gen)) { $gens[$cur.gen] = [System.Collections.Generic.List[string]]::new() }
  $gens[$cur.gen].Add($cur.id)
  foreach ($par in (Get-Parents $cur.id)) {
    $queue += [pscustomobject]@{ id = $par; gen = $cur.gen + 1 }
  }
}

# ---- what each person has ---------------------------------------------------
# the censuses that person could appear in, given their lifespan
$CENSUSES = @(1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911, 1921)

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($gen in ($gens.Keys | Sort-Object)) {
  foreach ($id in $gens[$gen]) {
    $who = $PPL.$id
    if (-not $who) { continue }
    $events = @($who.events)
    $tags = @($events | ForEach-Object { $_.tag })

    $birthYear = Get-Year (@($events | Where-Object { $_.tag -in 'BIRT', 'BAPM', 'CHR' } | Select-Object -First 1).date)
    $deathYear = Get-Year (@($events | Where-Object { $_.tag -in 'DEAT', 'BURI' } | Select-Object -First 1).date)

    # LIVING: no death, and born inside the last 100 years. No public records exist,
    # so they are not a gap and must never be listed as one.
    $living = (-not $deathYear) -and $birthYear -and ($birthYear -gt ($THIS_YEAR - 100))

    $hasBirth = @($tags | Where-Object { $_ -in 'BIRT', 'BAPM', 'CHR' }).Count -gt 0
    $hasDeath = @($tags | Where-Object { $_ -in 'DEAT', 'BURI' }).Count -gt 0

    # marriage lives on the FAMILY, not the person
    $hasMarr = $false
    foreach ($fid in @($who.fams)) {
      if (@($FAMS.$fid.events | Where-Object { $_.tag -eq 'MARR' }).Count) { $hasMarr = $true }
    }

    # which censuses are attached, and which they should appear in
    $resiYears = @($events | Where-Object { $_.tag -in 'RESI', 'CENS' } | ForEach-Object { Get-Year $_.date } | Where-Object { $_ })
    $expected = @()
    if ($birthYear) {
      $to = if ($deathYear) { $deathYear } else { $birthYear + 90 }
      $expected = @($CENSUSES | Where-Object { $_ -ge $birthYear -and $_ -le $to })
    }
    $missing = @($expected | Where-Object { $resiYears -notcontains $_ })

    $srcCount = @($who.cites).Count + @($events | ForEach-Object { $_.cites } | Where-Object { $_ }).Count
    $mediaCount = if ($docCount.ContainsKey($id)) { $docCount[$id] } else { 0 }

    # A living person has no death record because they are alive, and no 1921 census
    # because it is closed. Those are not gaps and must never be listed as work.
    $gaps = [System.Collections.Generic.List[string]]::new()
    if (-not $living) {
      if (-not $hasBirth) { $gaps.Add('birth/baptism') }
      if (-not $hasMarr) { $gaps.Add('marriage') }
      if (-not $hasDeath) { $gaps.Add('death/burial') }
      if ($missing.Count) { $gaps.Add("census: $($missing -join ', ')") }
    }

    $status = if ($living) { 'LIVING' } elseif (-not $gaps.Count) { 'DONE' } elseif ($srcCount -eq 0) { 'NOT STARTED' } else { 'PARTIAL' }

    $rows.Add([pscustomobject]@{
        Gen = $gen; Id = $id; Name = (Get-Name $who)
        Born = $birthYear; Died = $deathYear
        Status = $status; Gaps = @($gaps); Sources = $srcCount; Media = $mediaCount
      })
  }
}

# ---- write it out -----------------------------------------------------------
$md = [System.Collections.Generic.List[string]]::new()
$md.Add('# Sourcing tracker - the direct line')
$md.Add('')
$md.Add('> **GENERATED. Do not edit this file - your changes will be overwritten.**')
$md.Add('> `pwsh site/tools/New-Tracker.ps1`, straight from the latest GEDCOM export.')
$md.Add('>')
$md.Add('> It reports only what the tree can prove: what is attached and what is missing.')
$md.Add('> *Why* an identification was accepted, and who was rejected, belongs in the')
$md.Add('> journals. What to search next belongs in the worklist.')
$md.Add('')
$done = @($rows | Where-Object Status -eq 'DONE').Count
$partial = @($rows | Where-Object Status -eq 'PARTIAL').Count
$notStarted = @($rows | Where-Object Status -eq 'NOT STARTED').Count
$livingN = @($rows | Where-Object Status -eq 'LIVING').Count
$md.Add("**$($rows.Count) direct ancestors** - $done fully sourced | $partial partial | $notStarted not started | $livingN living (no public records)")
$md.Add('')

foreach ($gen in ($rows.Gen | Sort-Object -Unique)) {
  $md.Add("## Generation $gen")
  $md.Add('')
  foreach ($row in @($rows | Where-Object Gen -eq $gen | Sort-Object Name)) {
    $mark = switch ($row.Status) {
      'DONE' { '[x]' } 'LIVING' { '[-]' } default { '[ ]' }
    }
    $life = if ($row.Born -and $row.Died) { "$($row.Born)-$($row.Died)" }
    elseif ($row.Born) { "b. $($row.Born)" } else { 'no dates' }
    # $BT: a markdown code-fence backtick. It cannot be written inline in a
    # double-quoted string — PowerShell reads a backtick as its ESCAPE character,
    # so `$(...) becomes a literal dollar and the parse falls apart on the next line.
    $md.Add("- $mark **$($row.Name)** ($life) $BT$($row.Id)$BT")
    $md.Add("  - $($row.Status) | $($row.Sources) sources | $($row.Media) documents attached")
    if ($row.Gaps.Count) { foreach ($gap in $row.Gaps) { $md.Add("  - **missing:** $gap") } }
  }
  $md.Add('')
}

$outPath = Join-Path $familyDir 'TRACKER.md'
[IO.File]::WriteAllLines($outPath, $md)

Write-Host "wrote TRACKER.md - $($rows.Count) direct ancestors"
Write-Host "  fully sourced : $done"
Write-Host "  partial       : $partial"
Write-Host "  not started   : $notStarted"
Write-Host "  living        : $livingN"
