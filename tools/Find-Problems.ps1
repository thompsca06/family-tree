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
  $spotted = @()
  foreach ($w in @($OCCDATA.vocabulary)) {
    $wl = & $flat $w
    if (-not $wl -or $recordedBlob.Contains($wl) -or $curatedBlob.Contains($wl)) { continue }
    $n = @([regex]::Matches($prose, [regex]::Escape($w), 'IgnoreCase')).Count
    if ($n -gt 0) { $spotted += , @{ w = $w; n = $n } }
  }
  Say ""
  Say "=== 9. OCCUPATIONS — IN THE WRITING, RECORDED NOWHERE =========="
  Say "    (trade words used in the journal or stories but in nobody's occupations."
  Say "     Most will be background or a man ruled out - read the context first.)"
  foreach ($s in @($spotted | Sort-Object { - $_.n })) { Say ("  {0,3}x  {1}" -f $s.n, $s.w) }
  Say "  -> $(@($spotted).Count) trade words to check"
  foreach ($x in @($OCCDATA.ruledOut)) { Say ("  RULED OUT: {0}" -f ($x -replace '\*\*', '')) }
  Say ""
  Say "  recorded now: $($allOcc.Count) occupation entries, $($distinctOcc.Count) distinct, across $($occOf.Count) people"
}

# ---------------------------------------------------- 10. blocked / what next
# TRACKER.md counts what is missing; it cannot say whether a gap is a five-minute
# lookup or a man who has vanished. data/leads.json carries what was ALREADY
# TRIED and what to try next, so a failed search is never re-run.
#
# NOTHING IN leads.json IS EVIDENCE AND NOTHING IN IT MAY BE ATTACHED. It is a
# record of dead ends. That rule is enforced structurally: leads.json is read
# HERE and nowhere else — Build-FamilyData never opens it, so not one word of it
# can reach the website. If a lead comes good it goes to the tree and the
# journal, and the entry is deleted.
$leadPath = Join-Path $root 'data/leads.json'
if (Test-Path $leadPath) {
  $LEADS = Get-Content $leadPath -Raw -Encoding UTF8 | ConvertFrom-Json

  # Is the named gap closed in this export? Returns 'closed', 'open', or
  # 'manual' for anything that cannot honestly be checked from the data.
  function Test-Gap {
    param($person, [string]$gap, $parents, $hasMarr)
    $ev = @($person.events)
    $yrsResi = @($ev | Where-Object { $_.tag -in 'RESI', 'CENS' } | ForEach-Object { Yr $_.date } | Where-Object { $_ })
    $parts = @($gap -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $states = @()
    $lastWasCensus = $false
    foreach ($p in $parts) {
      $t = $p.ToLower()
      if ($t -match '^census\s+(\d{4})$') { $lastWasCensus = $true; $states += $(if ($yrsResi -contains [int]$matches[1]) { 'closed' } else { 'open' }); continue }
      if ($t -match '^(\d{4})$' -and $lastWasCensus) { $states += $(if ($yrsResi -contains [int]$matches[1]) { 'closed' } else { 'open' }); continue }
      $lastWasCensus = $false
      switch -regex ($t) {
        '^census'            { $lastWasCensus = $true; $states += $(if ($yrsResi.Count) { 'closed' } else { 'open' }) }
        'birth|bapti'        { $states += $(if (@($ev | Where-Object { $_.tag -in 'BIRT', 'BAPM', 'CHR' }).Count) { 'closed' } else { 'open' }) }
        'death|burial'       { $states += $(if (@($ev | Where-Object { $_.tag -in 'DEAT', 'BURI' }).Count) { 'closed' } else { 'open' }) }
        'marriage'           { $states += $(if ($hasMarr) { 'closed' } else { 'open' }) }
        'mother'             { $states += $(if ($parents -and $parents.m) { 'closed' } else { 'open' }) }
        'father'             { $states += $(if ($parents -and $parents.f) { 'closed' } else { 'open' }) }
        default              { $states += 'manual' }
      }
    }
    if (-not $states.Count) { return 'manual' }
    if ($states -contains 'open') { return 'open' }
    if ($states -contains 'manual') { return 'manual' }
    return 'closed'
  }

  Say ""
  Say "=== 10. BLOCKED - WHAT TO TRY NEXT ============================="
  Say "    (searches already run and FAILED, so nobody re-runs them.)"
  Say "    !! NOTHING HERE IS EVIDENCE. Nothing in this section may be attached."
  $open = 0; $shut = 0
  foreach ($b in @($LEADS.blocked)) {
    $who = $PPL.($b.id)
    if (-not $who) { Say ("  ?? {0,-24} {1} - not in this export" -f $b.name, $b.id); continue }
    $state = Test-Gap $who $b.gap $parentsOf[$b.id] $marrOf[$b.id]
    if ($state -eq 'closed') {
      $shut++
      Say ("  [x] {0,-24} {1} - CLOSED in this export. Delete the entry from data/leads.json." -f $b.name, $b.gap)
      continue
    }
    $open++
    $flag = $(if ($state -eq 'manual') { ' (close this one by hand)' } else { '' })
    Say ""
    Say ("  [ ] {0}  -  {1}{2}" -f $b.name, $b.gap, $flag)
    if (@($b.tried).Count) {
      Say "        ALREADY TRIED AND FAILED:"
      foreach ($x in @($b.tried)) { Say ("          - {0}" -f $x) }
    }
    if ($b.found_instead) { Say ("        FOUND INSTEAD: {0}" -f $b.found_instead) }
    if (@($b.next).Count) {
      Say "        TRY NEXT:"
      foreach ($x in @($b.next)) { Say ("          -> {0}" -f $x) }
    }
  }
  Say ""
  Say "  -> $open still blocked, $shut closed$(if($shut){' (delete the closed entries from data/leads.json)'})"
}

[IO.File]::WriteAllLines((Join-Path $root 'data/problems.txt'), $report)
Write-Host ""
Write-Host "full report -> data/problems.txt"
