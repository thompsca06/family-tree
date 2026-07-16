<#
Verify-Content.ps1 — does everything in the SOURCES actually reach the SITE?

Run it after any build. It answers "how do we know nothing else is being
silently lost?" with checks instead of hope:

  1. Every substantive line of every story .md appears on the Journal page.
  2. Every chapter shown on a profile runs to the true end of its section —
     checked for EVERY entry on EVERY person. (A chapter used to stop at its
     first ### sub-heading; this is the regression test for that class of bug.)
  3. Every GEDCOM event (incl. family marriages) appears as a profile record.
  4. Every citation on those events is carried through.
  Plus a BY-DESIGN DROPS report (non-MARR family events, note segments other
  than Occupation) so anything the build discards is chosen, not silent.

    pwsh tools/Verify-Content.ps1        # exits non-zero if anything is lost

Two PowerShell traps this file has already been bitten by — do not reintroduce:
  * Variables are CASE-INSENSITIVE: a loop's $f CLOBBERED the site data in $F
    and made every lookup null. The site data is now $SITE, never $F/$S.
  * @($null) is a ONE-element array: seeding "@($h[$k]) + ,$x" from a missing
    key, or counting @($null).Count, silently adds a phantom 1 per person.
    Always ContainsKey before reading, and filter nulls before counting.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$family = Split-Path -Parent $root

# ---- load the built site data (the FULL build, not the redacted docs/ copy)
$js = [IO.File]::ReadAllText((Join-Path $root 'familydata.js'))
$json = ($js -replace '^\s*window\.FAMILY\s*=\s*', '').TrimEnd().TrimEnd(';')
$SITE = $json | ConvertFrom-Json
$G = Get-Content (Join-Path $root 'data/gedcom.json') -Raw | ConvertFrom-Json

function Normalize([string]$s) {
  # squash to a whitespace-free, tag-free, markup-free form. Tags strip to
  # NOTHING (replacing with a space split "**Henry**." into "Henry ." and
  # false-flagged every line with inline bold), and ALL whitespace goes so
  # block boundaries and paragraph wrapping cannot cause a miss.
  if (-not $s) { return '' }
  $s = $s -replace '<[^>]+>', ''
  $s = $s -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&#39;', "'"
  $s = $s -replace '\*\*\*|\*\*|\*|`', ''
  $s = $s -replace '\[(.+?)\]\((.+?)\)', '$1'
  $s = $s -replace '\s', ''
  return $s.ToLower()
}

function Get-CheckableLines($lines) {
  # substantive prose lines, normalized; skips headings/comments/images/rules
  $out = @()
  foreach ($l in $lines) {
    $t = ([string]$l).Trim()
    if (-not $t) { continue }
    if ($t -match '^(#|<!--|!\[|---)') { continue }
    $t = $t -replace '^>\s?', '' -replace '^[-*+]\s+', '' -replace '^\d+\.\s+', ''
    $n = Normalize $t
    if ($n.Length -lt 40) { continue }
    $out += , $n
  }
  return $out
}

$fail = 0

# ---- gather the story files (same rule as the build: has a story: header)
$storyFiles = Get-ChildItem $family -Recurse -Filter *.md |
  Where-Object { $_.FullName -notmatch '\\_Archive\\|\\site\\' } |
  Where-Object { (Get-Content $_.FullName -Raw) -match '<!--\s*story:' }

# ---- split each story into sections exactly as the build does (## and ###),
#      and give each ## chapter its full body (subsections included)
$storySections = @{}   # "storyId|heading" -> @{ level; body }
$allStoryLines = @{}   # storyId -> every raw line (for check 1)
foreach ($sf in $storyFiles) {
  $md = Get-Content $sf.FullName -Raw
  $storyId = if ($md -match '<!--\s*story:\s*[^>]*\bid=([a-z0-9-]+)') { $matches[1] } else { $sf.BaseName }
  $lines = $md -split "`r?`n"
  $allStoryLines[$storyId] = $lines
  $secs = @(); $cur = $null
  foreach ($line in $lines) {
    if ($line -match '^(#{2,3})\s+(.*)$') {
      if ($cur) { $secs += , $cur }
      $cur = @{ level = $matches[1].Length; heading = $matches[2].Trim(); lines = @() }
      continue
    }
    if ($cur) { $cur.lines += , $line }
  }
  if ($cur) { $secs += , $cur }
  for ($i = 0; $i -lt $secs.Count; $i++) {
    $s = $secs[$i]
    $body = @($s.lines)
    if ($s.level -eq 2) {
      for ($k = $i + 1; ($k -lt $secs.Count) -and ($secs[$k].level -eq 3); $k++) {
        $body += , ('### ' + $secs[$k].heading)
        $body += @($secs[$k].lines)
      }
    }
    $storySections["$storyId|$($s.heading)"] = @{ level = $s.level; body = $body }
  }
}

Write-Host "=== 1. EVERY STORY LINE REACHES THE JOURNAL PAGE ==============="
$diaryAll = Normalize (@($SITE.diary | ForEach-Object { $_.html }) -join ' ')
$missing1 = 0
foreach ($sid in $allStoryLines.Keys) {
  foreach ($n in (Get-CheckableLines $allStoryLines[$sid])) {
    if (-not $diaryAll.Contains($n)) {
      $missing1++
      Write-Host "  MISSING from journal ($sid): $($n.Substring(0,[Math]::Min(90,$n.Length)))" -ForegroundColor Red
    }
  }
}
Write-Host "  -> $missing1 missing lines"
if ($missing1) { $fail++ }

Write-Host ""
Write-Host "=== 2. EVERY PROFILE CHAPTER RUNS TO ITS TRUE END =============="
$checked2 = 0; $bad2 = 0
foreach ($personId in $SITE.people.PSObject.Properties.Name) {
  $p = $SITE.people.$personId
  foreach ($jl in @($p.journal)) {
    if (-not $jl) { continue }
    $key = "$($jl.j)|$($jl.heading)"
    if (-not $storySections.ContainsKey($key)) {
      Write-Host "  ?? no source section for [$key] (person $personId)" -ForegroundColor Yellow
      continue
    }
    $need = @(Get-CheckableLines $storySections[$key].body)
    if (-not $need.Count) { continue }
    $checked2++
    $html = Normalize $jl.html
    $missingHere = @($need | Where-Object { -not $html.Contains($_) })
    if ($missingHere.Count) {
      $bad2++
      Write-Host "  TRUNCATED [$key] on $personId - $($missingHere.Count)/$($need.Count) lines missing; first: $($missingHere[0].Substring(0,[Math]::Min(70,$missingHere[0].Length)))" -ForegroundColor Red
    }
  }
}
Write-Host "  -> $checked2 profile chapters checked, $bad2 truncated"
if ($bad2) { $fail++ }

Write-Host ""
Write-Host "=== 3. EVERY GEDCOM EVENT IS A PROFILE RECORD =================="
# marriages per person, from the gedcom families (the build attributes each
# family MARR to both spouses)
$famProp = ($G.PSObject.Properties.Name | Where-Object { $_ -match '^fam' } | Select-Object -First 1)
$marr = @{}; $famOther = @{}
foreach ($fid in $G.$famProp.PSObject.Properties.Name) {
  $fam = $G.$famProp.$fid
  foreach ($e in @($fam.events)) {
    if (-not $e) { continue }
    if ($e.tag -eq 'MARR') {
      foreach ($who in @($fam.husb, $fam.wife)) {
        if ($who) {
          if (-not $marr.ContainsKey($who)) { $marr[$who] = @() }
          $marr[$who] += , $e
        }
      }
    } else {
      $famOther[$e.tag] = 1 + [int]$famOther[$e.tag]
    }
  }
}
$bad3 = 0; $checked3 = 0
foreach ($personId in $G.people.PSObject.Properties.Name) {
  $gp = $G.people.$personId
  $marrN = if ($marr.ContainsKey($personId)) { @($marr[$personId]).Count } else { 0 }
  $expected = @($gp.events | Where-Object { $_ }).Count + $marrN
  $sp = $SITE.people.$personId
  if (-not $sp) { Write-Host "  ?? $personId in gedcom but not on the site" -ForegroundColor Red; $bad3++; continue }
  $actual = @($sp.rec | Where-Object { $_ }).Count
  $checked3++
  if ($actual -ne $expected) {
    $bad3++
    Write-Host ("  MISMATCH {0,-16} {1}: gedcom {2} events -> site {3} records" -f $personId, $sp.name, $expected, $actual) -ForegroundColor Red
  }
}
Write-Host "  -> $checked3 people checked, $bad3 mismatches"
if ($bad3) { $fail++ }

Write-Host ""
Write-Host "=== 4. EVERY CITATION IS CARRIED THROUGH ======================="
$bad4 = 0
foreach ($personId in $G.people.PSObject.Properties.Name) {
  $gp = $G.people.$personId; $sp = $SITE.people.$personId
  if (-not $sp) { continue }
  $expCites = 0
  foreach ($e in @($gp.events)) { if ($e -and $e.cites) { $expCites += @($e.cites).Count } }
  if ($marr.ContainsKey($personId)) {
    foreach ($e in @($marr[$personId])) { if ($e -and $e.cites) { $expCites += @($e.cites).Count } }
  }
  $actCites = 0
  foreach ($r in @($sp.rec)) { if ($r -and $r.srcs) { $actCites += @($r.srcs).Count } }
  if ($actCites -lt $expCites) {
    $bad4++
    Write-Host ("  LOST CITES {0,-16} {1}: gedcom {2} -> site {3}" -f $personId, $sp.name, $expCites, $actCites) -ForegroundColor Red
  }
}
Write-Host "  -> $bad4 people lost citations"
if ($bad4) { $fail++ }

Write-Host ""
Write-Host "=== BY-DESIGN DROPS (should be chosen, not silent) ============="
if ($famOther.Count) {
  foreach ($k in $famOther.Keys) { Write-Host "  family event tag '$k' x$($famOther[$k]) - NOT shown on any profile" -ForegroundColor Yellow }
} else { Write-Host "  no non-MARR family events in the gedcom" }
$segKinds = @{}
foreach ($personId in $G.people.PSObject.Properties.Name) {
  foreach ($e in @($G.people.$personId.events)) {
    if (-not $e -or -not $e.note) { continue }
    foreach ($seg in ($e.note -split ';')) {
      $s = $seg.Trim()
      if ($s -match '^([A-Za-z ]{2,24}):') { $segKinds[$matches[1]] = 1 + [int]$segKinds[$matches[1]] }
    }
  }
}
Write-Host "  note segments in gedcom events (only 'Occupation' is shown, as occs):"
foreach ($k in ($segKinds.Keys | Sort-Object { -$segKinds[$_] })) {
  Write-Host ("    {0,-28} x{1}" -f $k, $segKinds[$k])
}

Write-Host ""
if ($fail) { Write-Host "CONTENT LOST - see above" -ForegroundColor Red; exit 1 }
Write-Host "all content accounted for" -ForegroundColor Green
exit 0
