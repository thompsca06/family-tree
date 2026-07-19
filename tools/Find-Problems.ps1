<#
Find-Problems.ps1 — data-quality audit of the Ancestry tree itself.

Reports things that need a human decision, rather than silently papering over them:
  1. probable duplicate people (same name, compatible birth years)
  2. children whose father and mother sit in DIFFERENT families
     (i.e. the parents were never linked as a couple)
  3. people with no birth and no baptism (nothing to date them by)
  4. direct-line ancestors missing vitals, per the "no person done without
     full vitals" rule
  5. places that do not resolve to the gazetteer

    pwsh tools/Find-Problems.ps1
#>
param([string]$GedJson = "data/gedcom.json")

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$G = Get-Content (Join-Path $root $GedJson) -Raw | ConvertFrom-Json
$PPL = $G.people
$FAMS = $G.fams
$ROOTID = 'I352128205181'

function Yr { param($d) if ($d -and $d -match '(\d{4})') { [int]$matches[1] } else { $null } }
function Ev1 { param($p, [string[]]$tags) $p.events | Where-Object { $_.tag -in $tags } | Select-Object -First 1 }
function Nm { param($p) (($p.givn, $p.surn) | Where-Object { $_ }) -join ' ' }

$report = [System.Collections.Generic.List[string]]::new()
function Say { param($s) $report.Add($s); Write-Host $s }

# ---------------------------------------------------------- 1. duplicates
Say ""
Say "=== 1. PROBABLE DUPLICATE PEOPLE ==============================="
$byName = @{}
foreach ($id in $PPL.PSObject.Properties.Name) {
  $p = $PPL.$id
  $key = ((Nm $p) -replace '\s+', ' ').Trim().ToLower()
  if (-not $key) { continue }
  if (-not $byName[$key]) { $byName[$key] = @() }
  $byName[$key] += $id
}
$dupCount = 0
foreach ($key in ($byName.Keys | Sort-Object)) {
  $grp = @($byName[$key])
  if ($grp.Count -lt 2) { continue }
  # only flag when birth years are compatible (within 3 yrs, or one is unknown)
  $pairs = @()
  for ($i = 0; $i -lt $grp.Count; $i++) {
    for ($j = $i + 1; $j -lt $grp.Count; $j++) {
      $a = $PPL.($grp[$i]); $b = $PPL.($grp[$j])
      $ya = Yr (Ev1 $a @('BIRT', 'BAPM', 'CHR')).date
      $yb = Yr (Ev1 $b @('BIRT', 'BAPM', 'CHR')).date
      if ((-not $ya) -or (-not $yb) -or ([Math]::Abs($ya - $yb) -le 3)) {
        $pairs += , @($grp[$i], $grp[$j], $ya, $yb)
      }
    }
  }
  if (-not $pairs.Count) { continue }
  $dupCount++
  Say ""
  Say "  '$key'"
  foreach ($id in $grp) {
    $p = $PPL.$id
    $b = Ev1 $p @('BIRT', 'BAPM', 'CHR'); $d = Ev1 $p @('DEAT', 'BURI')
    $par = @(); foreach ($fid in $p.famc) { $ff = $FAMS.$fid; if ($ff) { $par += "$(if($ff.husb){Nm $PPL.($ff.husb)}) / $(if($ff.wife){Nm $PPL.($ff.wife)})" } }
    Say ("    {0}  b.{1,-12} d.{2,-12} recs:{3,-3} parents: {4}" -f `
        $id, ($(if ($b.date) { $b.date } else { '?' })), ($(if ($d.date) { $d.date } else { '?' })), @($p.events).Count, ($par -join ' + '))
  }
}
Say ""
Say "  -> $dupCount name-groups look like possible duplicates"

# ---------------------------------------------------- 2. split parent families
Say ""
Say "=== 2. PARENTS NEVER LINKED AS A COUPLE ========================"
Say "    (child's father and mother sit in different families — the marriage"
Say "     link is missing on Ancestry, so the tree cannot join the two lines)"
$split = 0
foreach ($id in $PPL.PSObject.Properties.Name) {
  $p = $PPL.$id
  if (@($p.famc).Count -lt 2) { continue }
  $fa = $null; $mo = $null; $which = @()
  foreach ($fid in $p.famc) {
    $f = $FAMS.$fid
    if (-not $f) { continue }
    $which += "$fid(h=$(if($f.husb){'y'}else{'-'}),w=$(if($f.wife){'y'}else{'-'}))"
    if ($f.husb) { $fa = $f.husb }
    if ($f.wife) { $mo = $f.wife }
  }
  $split++
  Say ("  {0}  {1,-32} father={2,-24} mother={3,-24} {4}" -f `
      $id, (Nm $p), $(if ($fa) { Nm $PPL.$fa } else { '—' }), $(if ($mo) { Nm $PPL.$mo } else { '—' }), ($which -join ' '))
}
Say "  -> $split people affected"

# ------------------------------ 2b. one parent missing, the other family has one
# The blind spot between §2 and §4, found by eye on the tree view and not by this
# report. A child sits in a family that has a FATHER BUT NO WIFE, while the same
# father has ANOTHER family that does have one — so the child is parked in a
# wifeless duplicate and their real mother is a click away.
#
# §2 could not see it: it compares a father and a mother in different families,
# and here there is no mother at all, so it has nothing to compare and says 0.
# §4 does report "no mother" but only walks the DIRECT LINE, and these are
# usually collateral children.
#
# It happens for an ordinary reason and will recur: children attached from a
# census taken AFTER their mother died are created motherless, because she is not
# on the page to attach. Thomas Ingleby's sons Thomas (1847) and William (1851)
# came off the 1861 census; Dorothy Tomlinson died in 1854.
#
# Precise by design: a man with children by two women has two families that BOTH
# have wives, so he never fires here.
Say ""
Say "=== 2b. ONE PARENT MISSING, THE OTHER FAMILY HAS ONE ==========="
Say "    (child is in a family with only a father (or only a mother), while that"
Say "     parent has ANOTHER family that does have a spouse - the child is in a"
Say "     duplicate family and the real parent is on the other one)"
$halfFam = 0
foreach ($id in $PPL.PSObject.Properties.Name) {
  $p = $PPL.$id
  foreach ($fid in @($p.famc)) {
    $f = $FAMS.$fid
    if (-not $f) { continue }
    # which single parent is present, and who is the other family's spouse?
    $lone = $null; $loneRole = ''; $missing = ''
    if ($f.husb -and -not $f.wife) { $lone = $f.husb; $loneRole = 'father'; $missing = 'mother' }
    elseif ($f.wife -and -not $f.husb) { $lone = $f.wife; $loneRole = 'mother'; $missing = 'father' }
    if (-not $lone) { continue }
    $lp = $PPL.$lone
    if (-not $lp) { continue }
    # does that parent have ANOTHER family that does carry a spouse?
    $elsewhere = @()
    foreach ($ofid in @($lp.fams)) {
      if ($ofid -eq $fid) { continue }
      $of = $FAMS.$ofid
      if (-not $of) { continue }
      $spouse = $(if ($loneRole -eq 'father') { $of.wife } else { $of.husb })
      if ($spouse -and $PPL.$spouse) { $elsewhere += , @{ fam = $ofid; who = $spouse } }
    }
    if (-not $elsewhere.Count) { continue }
    $halfFam++
    $names = @($elsewhere | ForEach-Object { "$(Nm $PPL.($_.who)) [$($_.fam)]" }) -join ', '
    Say ("  {0}  {1,-28} in {2} with {3} {4} and NO {5}" -f $id, (Nm $p), $fid, $loneRole, (Nm $lp), $missing)
    Say ("        {0} also has: {1}  <- the {2} is probably there" -f (Nm $lp), $names, $missing)
  }
}
Say "  -> $halfFam children in a one-parent duplicate family"

# ---------------------------------------------------- 3. undated people
Say ""
Say "=== 3. PEOPLE WITH NO BIRTH AND NO BAPTISM ====================="
$undated = 0
foreach ($id in $PPL.PSObject.Properties.Name) {
  $p = $PPL.$id
  if (-not (Ev1 $p @('BIRT', 'BAPM', 'CHR'))) {
    $undated++
    Say ("  {0}  {1,-34} records: {2}" -f $id, (Nm $p), @($p.events).Count)
  }
}
Say "  -> $undated people cannot be dated"

# ------------------------------------------- 4. direct line, full vitals
Say ""
Say "=== 4. DIRECT LINE — MISSING VITALS ============================"
Say "    (rule: birth/baptism + marriage + death/burial + every census)"
$parentsOf = @{}
foreach ($fid in $FAMS.PSObject.Properties.Name) {
  $f = $FAMS.$fid
  foreach ($c in $f.chil) {
    if (-not $parentsOf[$c]) { $parentsOf[$c] = @{ f = $null; m = $null } }
    if ($f.husb -and -not $parentsOf[$c].f) { $parentsOf[$c].f = $f.husb }
    if ($f.wife -and -not $parentsOf[$c].m) { $parentsOf[$c].m = $f.wife }
  }
}
# marriages by person
$marrOf = @{}
foreach ($fid in $FAMS.PSObject.Properties.Name) {
  $f = $FAMS.$fid
  if ($f.events | Where-Object tag -eq 'MARR') {
    foreach ($w in @($f.husb, $f.wife)) { if ($w) { $marrOf[$w] = $true } }
  }
}
# ...and by the person's own events: a marriage attached from the civil
# marriage index exports as a MARR on the INDI, not the FAM — count those too
# or everyone sourced that way is false-flagged "missing marriage"
foreach ($pn in $PPL.PSObject.Properties.Name) {
  if (@($PPL.$pn.events | Where-Object { $_.tag -eq 'MARR' }).Count) { $marrOf[$pn] = $true }
}

$line = [System.Collections.Generic.List[object]]::new()
function Climb { param([string]$id, [int]$gen)
  if (-not $id -or $gen -gt 9) { return }
  $line.Add(@{ id = $id; gen = $gen })
  $pp = $parentsOf[$id]
  if ($pp) { Climb $pp.f ($gen + 1); Climb $pp.m ($gen + 1) }
}
Climb $ROOTID 1

$gaps = 0
foreach ($e in ($line | Sort-Object { $_.gen })) {
  $p = $PPL.($e.id)
  if (-not $p) { continue }
  $miss = @()
  if (-not (Ev1 $p @('BIRT', 'BAPM', 'CHR'))) { $miss += 'birth' }
  if (-not $marrOf[$e.id]) { $miss += 'marriage' }
  if (-not (Ev1 $p @('DEAT', 'BURI'))) { $miss += 'death' }
  $cens = @($p.events | Where-Object { $_.tag -eq 'RESI' }).Count
  if ($cens -eq 0) { $miss += 'no census' }
  $par = $parentsOf[$e.id]
  if (-not $par -or -not $par.f) { $miss += 'no father' }
  if (-not $par -or -not $par.m) { $miss += 'no mother' }
  if ($miss.Count) {
    $gaps++
    Say ("  gen {0}  {1,-32} censuses:{2,-3} MISSING: {3}" -f $e.gen, (Nm $p), $cens, ($miss -join ', '))
  }
}
Say "  -> $gaps direct-line ancestors have gaps"

# ---------------------------------------------------------- 5. places
Say ""
Say "=== 5. UNRESOLVED PLACES ======================================="
$upath = Join-Path $root 'data/places-unresolved.json'
if (Test-Path $upath) {
  $u = Get-Content $upath -Raw | ConvertFrom-Json
  foreach ($k in $u.PSObject.Properties.Name) { Say ("  {0,3}x  {1}" -f $u.$k, $k) }
} else { Say "  (run Build-FamilyData.ps1 first)" }

# ------------------------------------------- 6. not connected to home person
# People in the Ancestry tree with NO path to the home person over the
# person<->family graph. Parse-Gedcom drops them from the site render (they are
# research staged for a connection that is not made yet); they are listed here
# so the drop is visible, never silent. Connect them on Ancestry and they will
# appear on the site at the next build.
Say ""
Say "=== 6. NOT CONNECTED TO THE HOME PERSON ========================"
Say "    (in the Ancestry tree but no path to $ROOTID - NOT rendered on the site)"
$nc = @($G.meta.notConnected)
if ($nc.Count) {
  foreach ($x in ($nc | Sort-Object { $_.name })) { Say ("  {0,-16} {1}" -f $x.id, $x.name) }
} else { Say "  everyone in the file is connected" }
Say "  -> $($nc.Count) people not connected (of $($G.meta.totalInFile) in the file)"

# People PROVED not to be family are parked in data/not-relevant.json and are NOT
# part of the count above - otherwise this section reports settled work as the
# biggest outstanding bucket, which it did twice. Listed separately, never hidden.
$nrel = @($G.meta.notRelevant)
if ($nrel.Count) {
  Say ""
  Say "  PARKED - PROVED NOT FAMILY (data/not-relevant.json), excluded from the count above:"
  foreach ($grp in ($nrel | Group-Object cluster | Sort-Object Count -Descending)) {
    Say ("    {0,3} - {1}" -f $grp.Count, $grp.Name)
  }
  Say "  -> $($nrel.Count) parked. They stay in the Ancestry tree; excluding is not deleting."
  Say "     Do NOT 'reconnect' these - each carries the evidence that disproved it in that file."
}

# ---------------------------------------------------------- 7. occupations
# The Work page is built ONLY from occupations in the export. A trade read in a
# record and written up in the journal, but never entered as a fact on Ancestry,
# cannot reach the site at all. The curated list of those lives in
# data/occupations.json; this checks it against the live tree and TICKS OFF
# anything now recorded, so it can never sit here stale telling you to do
# something you have already done.
#
# Occupations arrive TWO ways and both are read here, exactly as the build reads
# them: in a census note ("Occupation: Boilermaker; Marital Status: ...") and as
# an Occupation fact's own value ("1 OCCU Joiner").
$occPath = Join-Path $root 'data/occupations.json'
if (Test-Path $occPath) {
  $OCCDATA = Get-Content $occPath -Raw -Encoding UTF8 | ConvertFrom-Json

  $occOf = @{}
  $allOcc = [System.Collections.Generic.List[string]]::new()
  foreach ($pn in $PPL.PSObject.Properties.Name) {
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($ev in @($PPL.$pn.events)) {
      if (-not $ev) { continue }
      if ($ev.tag -eq 'OCCU' -and $ev.value) {
        $t = ($ev.value -replace '\s+', ' ').Trim()
        if ($t -and -not ($list -contains $t)) { $list.Add($t) }
        $allOcc.Add($t)
      }
      if (-not $ev.note) { continue }
      foreach ($seg in ($ev.note -split ';')) {
        if ($seg -match '(?i)^\s*Occupation:\s*(.+?)\s*$') {
          $t = ($matches[1] -replace '\s+', ' ').Trim()
          if ($t -and -not ($list -contains $t)) { $list.Add($t) }
          $allOcc.Add($t)
        }
      }
    }
    if ($list.Count) { $occOf[$pn] = @($list) }
  }
  $distinctOcc = @($allOcc | Sort-Object -Unique)

  Say ""
  Say "=== 7. OCCUPATIONS — TRADES TO ADD ============================="
  Say "    (proven in a record, never entered as a fact, so absent from the site)"
  $left = 0
  foreach ($it in @($OCCDATA.add)) {
    $done = $false; $now = ''
    if ($it.id -and $it.match -and $occOf.ContainsKey($it.id)) {
      $hit = @($occOf[$it.id] | Where-Object { $_ -match $it.match })
      if ($hit.Count) { $done = $true; $now = ($hit -join ', ') }
    }
    if ($done) { Say ("  [x] {0,-24} {1}  -- now recorded as: {2}" -f $it.name, $it.trade, $now); continue }
    $left++
    Say ("  [ ] {0,-24} {1}" -f $it.name, $it.trade)
    Say ("        {0}" -f $it.evidence)
    if ($it.id -and -not $PPL.($it.id)) { Say "        !! not in this export - check the ID, or they may be unconnected" }
    if ($it.warn) { Say ("        !! {0}" -f $it.warn) }
  }
  Say "  -> $left of $(@($OCCDATA.add).Count) still to add"

  Say ""
  Say "=== 8. OCCUPATIONS — TRANSCRIPTIONS TO CORRECT ================="
  Say "    (Ancestry's census wording, carried through verbatim as the rule requires)"
  $fleft = 0
  foreach ($it in @($OCCDATA.fix)) {
    if (-not ($distinctOcc -contains $it.recorded)) { Say ("  [x] {0,-20} '{1}' is gone from the export" -f $it.name, $it.recorded); continue }
    $fleft++
    $to = $(if ($it.suggest) { " -> $($it.suggest)" } else { '' })
    Say ("  [ ] {0,-20} {1} census: '{2}'{3}" -f $it.name, $it.year, $it.recorded, $to)
    if ($it.warn) { Say ("        !! {0}" -f $it.warn) }
  }
  Say "  -> $fleft of $(@($OCCDATA.fix).Count) still to correct"

  # trade words used in the writing that are in NOBODY's recorded occupations
  $prose = ''
  foreach ($mdf in @(Get-ChildItem (Split-Path -Parent $root) -Recurse -Filter *.md -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\_Archive\\|\\site\\' })) {
    $prose += "`n" + ([IO.File]::ReadAllText($mdf.FullName, [Text.Encoding]::UTF8))
  }
  $flat = { param($s) ($s -replace '[^A-Za-z]', '').ToLower() }
  $recordedBlob = & $flat ($distinctOcc -join ' ')
  $curatedBlob = & $flat ((@($OCCDATA.add | ForEach-Object { "$($_.trade) $($_.match)" }) -join ' ') -replace '[.?*|]', ' ')
  # One job can have more than one word. "Publican" is not missing when the register
  # says "Innkeeper" — same man, same trade, different pen. So a word is only
  # reported if NOTHING in its synonym group is recorded against anybody.
  $synGroups = @()
  foreach ($grp in @($OCCDATA.synonyms)) {
    $flatGrp = @(@($grp) | ForEach-Object { & $flat $_ } | Where-Object { $_ })
    if ($flatGrp.Count) { $synGroups += , $flatGrp }
  }
  # Words already RULED OUT. These were only ever printed, never subtracted, so a
  # word got LOUDER the more thoroughly it was disproved: writing up the disproof
  # put more occurrences in the journal, and the tally counts the journal. §9
  # could never reach zero. Ruled-out words now drop out of the tally and are
  # counted separately, so nothing is hidden - it is reported as settled, not
  # outstanding.
  #
  # Terms are taken from the LEADING quoted words of each ruledOut entry, i.e.
  # everything before the first " - ". An entry may lead with more than one
  # ("carrier" and "brewer"), and the prose that follows often quotes other
  # things ('Hare and Hounds'), which is why only the lead is read.
  $ruledWords = @()
  foreach ($x in @($OCCDATA.ruledOut)) {
    $lead = (($x -split ' - ', 2)[0])
    foreach ($m in [regex]::Matches($lead, '"([^"]+)"')) {
      $rw = & $flat $m.Groups[1].Value
      if ($rw) { $ruledWords += $rw }
    }
  }
  $spotted = @(); $ruledHits = @()
  foreach ($w in @($OCCDATA.vocabulary)) {
    $wl = & $flat $w
    if (-not $wl -or $recordedBlob.Contains($wl) -or $curatedBlob.Contains($wl)) { continue }
    if ($ruledWords -contains $wl) {
      $n = @([regex]::Matches($prose, [regex]::Escape($w), 'IgnoreCase')).Count
      if ($n -gt 0) { $ruledHits += , @{ w = $w; n = $n } }
      continue
    }
    # is a synonym of it recorded?
    $covered = $false
    foreach ($grp in $synGroups) {
      if ($grp -notcontains $wl) { continue }
      foreach ($alt in $grp) {
        if ($alt -ne $wl -and ($recordedBlob.Contains($alt) -or $curatedBlob.Contains($alt))) { $covered = $true; break }
      }
      if ($covered) { break }
    }
    if ($covered) { continue }
    $n = @([regex]::Matches($prose, [regex]::Escape($w), 'IgnoreCase')).Count
    if ($n -gt 0) { $spotted += , @{ w = $w; n = $n } }
  }
  Say ""
  Say "=== 9. OCCUPATIONS — IN THE WRITING, RECORDED NOWHERE =========="
  Say "    (trade words used in the journal or stories but in nobody's occupations."
  Say "     Most will be background or a man ruled out - read the context first.)"
  foreach ($s in @($spotted | Sort-Object { - $_.n })) { Say ("  {0,3}x  {1}" -f $s.n, $s.w) }
  $rOut = @($ruledHits | Sort-Object { - $_.n })
  if ($rOut.Count) {
    Say ("  (settled, not counted: {0})" -f (@($rOut | ForEach-Object { "$($_.w) $($_.n)x" }) -join ', '))
  }
  Say "  -> $(@($spotted).Count) trade words to check$(if($rOut.Count){" ($($rOut.Count) ruled out)"})"
  foreach ($x in @($OCCDATA.ruledOut)) { Say ("  RULED OUT: {0}" -f ($x -replace '\*\*', '')) }
  Say ""
  Say "  recorded now: $($allOcc.Count) occupation entries, $($distinctOcc.Count) distinct, across $($occOf.Count) people"
}


[IO.File]::WriteAllLines((Join-Path $root 'data/problems.txt'), $report)
Write-Host ""
Write-Host "full report -> data/problems.txt"
