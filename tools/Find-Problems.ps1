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

[IO.File]::WriteAllLines((Join-Path $root 'data/problems.txt'), $report)
Write-Host ""
Write-Host "full report -> data/problems.txt"
