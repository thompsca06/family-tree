<#
Build-FamilyData.ps1 — data/gedcom.json + data/places.json + journals  ->  familydata.js

Every fact on the site is derived from the Ancestry GEDCOM export. Nothing is
inferred, rounded or filled in:
  * a place only gets a map pin if it resolves in the curated gazetteer;
    unresolved places are written to data/places-unresolved.json for review
  * a record's label comes from the source collection it was cited from
    ("1921 England Census"), not a generic "Census / residence"
  * occupations are lifted verbatim from the census / 1939 Register notes
  * no dates are invented — a person with no death record has no death year

    pwsh tools/Build-FamilyData.ps1
#>
param(
  [string]$GedJson = "data/gedcom.json",
  [string]$Places  = "data/places.json",
  [string]$Out     = "familydata.js",
  # -Public: redact people who may still be living. Their records never reach the
  # published file at all — this is not a hide-it-in-the-browser toggle.
  [switch]$Public,
  [int]$PrivacyYears = 100
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$family = Split-Path -Parent $root       # the Family/ folder: journals, rules, scans
$G = Get-Content (Join-Path $root $GedJson) -Raw | ConvertFrom-Json
$GAZ = Get-Content (Join-Path $root $Places) -Raw | ConvertFrom-Json

$EN_DASH = [char]0x2013
$EM_DASH = [char]0x2014

# ---------------------------------------------------------------- places
# Common misspellings / variants seen in this tree, mapped to gazetteer keys.
$SYNONYM = @{
  'knaresbro'             = 'knaresborough'
  'felbeck'               = 'fellbeck'
  'middlesborough'        = 'middlesbrough'
  'garton upon the wolds' = 'garton on the wolds'
  'garton'                = 'garton on the wolds'
  'hull'                  = 'kingston upon hull'
  'hunters hill'          = 'hunters hill'
  'kirby-wiske'           = 'kirby wiske'
  'kirkbymoorside'        = 'kirkby moorside'
  'newcastle'             = 'newcastle nsw'   # only one Newcastle in this tree, and it is NSW
  'melton'                = 'melton mowbray'
}

# County- and country-only strings ("Yorkshire, England") are deliberately NOT
# pinned: there is no honest point on a map for a whole county. They are listed
# as unresolved so the gap is visible rather than invented.

$gazKeys = @($GAZ.PSObject.Properties.Name | Where-Object { $_ -ne '_comment' })
$gazSet = @{}
foreach ($k in $gazKeys) { $gazSet[$k] = $GAZ.$k }

$unresolved = @{}

function Resolve-Place {
  param([string]$raw)
  if (-not $raw) { return $null }

  # Split on commas, then within each part try every contiguous word-span,
  # longest first, left to right. First gazetteer hit wins — so
  # "Hunslet, Leeds, West Yorkshire" resolves to Hunslet, not Leeds.
  foreach ($part in ($raw -split '[,;]')) {
    # apostrophes are deleted, not spaced, so "Hunter's Hill" -> "hunters hill"
    $clean = ($part -replace "['’]", '') -replace "[\[\]().:]", ' '
    $clean = ($clean -replace '\s+', ' ').Trim().ToLower()
    if (-not $clean) { continue }
    $words = @($clean -split ' ' | Where-Object { $_ })
    for ($len = $words.Count; $len -ge 1; $len--) {
      for ($i = 0; $i + $len -le $words.Count; $i++) {
        $span = ($words[$i..($i + $len - 1)] -join ' ')
        if ($SYNONYM.ContainsKey($span)) { $span = $SYNONYM[$span] }
        if ($gazSet.ContainsKey($span)) {
          return [ordered]@{ key = $span; label = $gazSet[$span].label; ll = $gazSet[$span].ll }
        }
      }
    }
  }
  $unresolved[$raw] = $unresolved[$raw] + 1
  return $null
}

# Display place: gazetteer label if we know it, else the first component verbatim.
function Short-Place {
  param([string]$raw)
  if (-not $raw) { return '' }
  $r = Resolve-Place $raw
  if ($r) { return $r.label }
  return (($raw -split ',')[0]).Trim()
}

# ---------------------------------------------------------------- dates
function Get-Year {
  param([string]$d)
  if (-not $d) { return $null }
  if ($d -match '(\d{4})') { return [int]$matches[1] }
  return $null
}
function Is-Approx {
  param([string]$d)
  if (-not $d) { return $false }
  return ($d -match '(?i)\b(abt|about|circa|est|cal|bef|aft|before|after)\b')
}

# ---------------------------------------------------------------- names
function Title-Case {
  param([string]$s)
  if (-not $s) { return $s }
  # Only fix SHOUTED names (INGLEBY); leave deliberate casing (McBride) alone.
  if ($s -cne $s.ToUpper()) { return $s }
  $out = ($s.ToLower() -split '(\s|-|'')') | ForEach-Object {
    if ($_ -match '^[a-z]') { $_.Substring(0, 1).ToUpper() + $_.Substring(1) } else { $_ }
  }
  return (-join $out)
}

# ---------------------------------------------------------------- sources
$SRC_NAMES = $G.sources.PSObject.Properties.Name

function Title-Of { param([string]$sid)
  if ($sid -and $SRC_NAMES -contains $sid) { return $G.sources.$sid.title }
  return $null
}

# Every citation on the event, kept — nothing is dropped.
function Src-List { param($ev)
  $out = @()
  foreach ($c in @($ev.cites)) {
    if (-not $c) { continue }
    $t = Title-Of $c.sid
    if ($t) { $out += , [ordered]@{ title = $t; page = $c.page } }
  }
  return $out
}

# Ancestry hangs several sources off a single event — a man's birth year can be
# cited from his death index or a passenger list. For the headline label, prefer
# the citation that actually matches the event; the rest stay in `srcs`.
$SRC_PREFER = @{
  BIRT    = 'Birth|Baptis|Christen|Births and Baptisms'
  CHR     = 'Baptis|Christen'
  BAPM    = 'Baptis|Christen'
  DEAT    = 'Death|Burial|Probate|Find a Grave|Cemetery'
  BURI    = 'Burial|Deaths and Burials|Find a Grave|Cemetery'
  MARR    = 'Marriage|Marriages'
  RESI    = 'Census|Register|Directories|Electoral|Land Tax|Criminal'
  PROB    = 'Probate'
  '_MILT' = 'Military|Medal|Service|Navy|Army|Prisoner'
  EVEN    = 'Passenger|Incoming|Emigra'
}
function Src-Best { param($ev)
  $list = Src-List $ev
  if (-not $list.Count) { return $null }
  $pat = $SRC_PREFER[$ev.tag]
  if ($pat) {
    foreach ($s in $list) { if ($s.title -match $pat) { return $s } }
  }
  return $list[0]
}

# A residence's label depends on which collection it was cited from.
function Resi-Label { param($title)
  if (-not $title) { return 'Residence' }
  if ($title -match '^(\d{4}) England Census') { return "$($matches[1]) Census" }
  if ($title -match '1939 England and Wales Register') { return '1939 Register' }
  if ($title -match 'Electoral Register') { return 'Electoral register' }
  if ($title -match 'City and County Directories') { return 'Trade directory' }
  if ($title -match 'Land Tax') { return 'Land tax record' }
  if ($title -match 'Criminal Registers') { return 'Criminal register' }
  return 'Residence'
}

$EVENT_LABEL = @{
  BIRT = 'Born'; CHR = 'Baptised'; BAPM = 'Baptised'; DEAT = 'Died'; BURI = 'Buried'
  PROB = 'Probate'; EMIG = 'Emigrated'; IMMI = 'Immigrated'; MARR = 'Married'
  '_MILT' = 'Military service'
}

# ---------------------------------------------------------------- people
$people = [ordered]@{}
$PPL = $G.people
$FAMS = $G.fams
$ids = @($PPL.PSObject.Properties.Name)

# spouse + marriage lookups
$spouseOf = @{}
$marrEv = @{}
foreach ($fid in $FAMS.PSObject.Properties.Name) {
  $f = $FAMS.$fid
  if ($f.husb -and $f.wife) {
    if (-not $spouseOf[$f.husb]) { $spouseOf[$f.husb] = @() }
    if (-not $spouseOf[$f.wife]) { $spouseOf[$f.wife] = @() }
    $spouseOf[$f.husb] += $f.wife
    $spouseOf[$f.wife] += $f.husb
  }
  foreach ($e in $f.events) {
    if ($e.tag -eq 'MARR') {
      foreach ($who in @($f.husb, $f.wife)) {
        if ($who) {
          if (-not $marrEv[$who]) { $marrEv[$who] = @() }
          $marrEv[$who] += , @{ ev = $e; other = $(if ($who -eq $f.husb) { $f.wife } else { $f.husb }) }
        }
      }
    }
  }
}

# parents lookup.
# A child can sit in more than one FAMC — in this tree William (1949) has his
# father in one family and his mother in another, because Tommy and Ada were
# never linked as a couple on Ancestry. So merge across all of a child's
# families rather than letting the last one win.
$parentsOf = @{}
$childrenOf = @{}
foreach ($fid in $FAMS.PSObject.Properties.Name) {
  $f = $FAMS.$fid
  foreach ($c in $f.chil) {
    if (-not $parentsOf[$c]) { $parentsOf[$c] = @{ f = $null; m = $null } }
    if ($f.husb -and -not $parentsOf[$c].f) { $parentsOf[$c].f = $f.husb }
    if ($f.wife -and -not $parentsOf[$c].m) { $parentsOf[$c].m = $f.wife }
    foreach ($who in @($f.husb, $f.wife)) {
      if ($who) {
        if (-not $childrenOf[$who]) { $childrenOf[$who] = @() }
        $childrenOf[$who] += $c
      }
    }
  }
}

# ---------------------------------------------------------------- branch
# The two sides do not only meet at Chris — they also meet at his parents'
# marriage. So: take the pure ancestor set of each parent (parent edges only,
# which keeps the two sets disjoint), then grow each side outwards through
# spouses and children without ever crossing into the other side's ancestors.
# Chris and his siblings are the home line.
$ROOTID = 'I352128205181'   # Christopher Anthony Thompson
$rootPar = $parentsOf[$ROOTID]

function Ancestors {
  param([string]$start)
  $set = @{}
  if (-not $start) { return $set }
  $q = [System.Collections.Queue]::new()
  $q.Enqueue($start)
  while ($q.Count) {
    $cur = $q.Dequeue()
    if (-not $cur -or $set[$cur]) { continue }
    $set[$cur] = $true
    if ($parentsOf[$cur]) {
      foreach ($n in @($parentsOf[$cur].f, $parentsOf[$cur].m)) { if ($n) { $q.Enqueue($n) } }
    }
  }
  return $set
}

$ancT = Ancestors $rootPar.f    # William Thompson + all his ancestors
$ancI = Ancestors $rootPar.m    # Glenys Ingleby + all her ancestors

# home line: Chris and his siblings
$homeLine = @{}
$homeLine[$ROOTID] = $true
foreach ($sib in @($childrenOf[$rootPar.f])) { if ($sib) { $homeLine[$sib] = $true } }

$branch = @{}
foreach ($k in $homeLine.Keys) { $branch[$k] = 'root' }

function Walk {
  param([hashtable]$seeds, [hashtable]$forbidden, [string]$label)
  $seen = @{}
  $q = [System.Collections.Queue]::new()
  foreach ($s in $seeds.Keys) { $q.Enqueue($s) }
  while ($q.Count) {
    $cur = $q.Dequeue()
    if (-not $cur -or $seen[$cur] -or $homeLine[$cur] -or $forbidden[$cur]) { continue }
    $seen[$cur] = $true
    if (-not $branch.ContainsKey($cur)) { $branch[$cur] = $label }
    $nbrs = @()
    if ($parentsOf[$cur]) { $nbrs += @($parentsOf[$cur].f, $parentsOf[$cur].m) }
    if ($childrenOf[$cur]) { $nbrs += $childrenOf[$cur] }
    if ($spouseOf[$cur]) { $nbrs += $spouseOf[$cur] }
    foreach ($n in $nbrs) { if ($n -and -not $seen[$n]) { $q.Enqueue($n) } }
  }
}
Walk $ancT $ancI 'thompson'
Walk $ancI $ancT 'ingleby'

# ---------------------------------------------------------------- build
$geoUsed = @{}

foreach ($id in $ids) {
  $p = $PPL.$id
  $given = Title-Case $p.givn
  $surn = Title-Case $p.surn
  $name = (@($given, $surn) | Where-Object { $_ }) -join ' '

  # --- vitals: strictly what is recorded
  $birt = $p.events | Where-Object { $_.tag -eq 'BIRT' } | Select-Object -First 1
  $bapm = $p.events | Where-Object { $_.tag -in 'BAPM', 'CHR' } | Select-Object -First 1
  $deat = $p.events | Where-Object { $_.tag -eq 'DEAT' } | Select-Object -First 1
  $buri = $p.events | Where-Object { $_.tag -eq 'BURI' } | Select-Object -First 1

  $by = Get-Year $birt.date
  if (-not $by) { $by = Get-Year $bapm.date }      # baptism is the next best evidence of birth
  $dy = Get-Year $deat.date
  if (-not $dy) { $dy = Get-Year $buri.date }
  $bApprox = (Is-Approx $birt.date) -or (-not $birt.date -and $bapm.date)

  if ($by -and $dy) { $years = "$(if($bApprox){'c. '})$by$EN_DASH$dy" }
  elseif ($by) { $years = "b. $(if($bApprox){'c. '})$by" }
  elseif ($dy) { $years = "d. $dy" }
  else { $years = "$EM_DASH" }

  # --- occupations, verbatim from census / 1939 Register notes
  $occs = [System.Collections.Generic.List[string]]::new()
  foreach ($e in ($p.events | Sort-Object { Get-Year $_.date })) {
    if (-not $e.note) { continue }
    foreach ($seg in ($e.note -split ';')) {
      if ($seg -match '(?i)^\s*Occupation:\s*(.+?)\s*$') {
        $o = $matches[1].Trim()
        if ($o -and -not ($occs | Where-Object { $_ -ieq $o })) { $occs.Add($o) }
      }
    }
  }

  # --- records timeline + map stops
  $recs = [System.Collections.Generic.List[object]]::new()
  $stops = [System.Collections.Generic.List[object]]::new()
  $seenStop = @{}

  $allEv = @($p.events)
  if ($marrEv[$id]) { foreach ($m in $marrEv[$id]) { $allEv += $m.ev } }

  # dated events in order; undated ones last rather than pretending they are earliest
  $sorted = @($allEv | Sort-Object @{E = { $null -eq (Get-Year $_.date) } }, @{E = { Get-Year $_.date } })
  foreach ($e in $sorted) {
    $yr = Get-Year $e.date
    $best = Src-Best $e
    $title = $(if ($best) { $best.title } else { $null })
    $sp = Short-Place $e.place

    switch ($e.tag) {
      'RESI' { $lab = Resi-Label $title }
      'EVEN' { $lab = if ($e.type) { $e.type } else { 'Event' } }
      'MARR' {
        $other = ($marrEv[$id] | Where-Object { $_.ev -eq $e } | Select-Object -First 1).other
        $oname = if ($other -and $PPL.$other) { (Title-Case $PPL.$other.givn) + ' ' + (Title-Case $PPL.$other.surn) } else { $null }
        $lab = if ($oname) { "Married $oname" } else { 'Married' }
      }
      default { $lab = $EVENT_LABEL[$e.tag]; if (-not $lab) { $lab = $e.tag } }
    }

    $label = if ($sp) { "$lab $EM_DASH $sp" } else { $lab }
    $recs.Add([ordered]@{
        year  = $yr
        label = $label
        src   = $title
        page  = $(if ($best) { $best.page } else { $null })
        place = $e.place
        date  = $e.date          # the record's date verbatim, not just the year
        srcs  = @(Src-List $e)   # every citation on this event
      })

    # map pin only for places we actually know
    $r = Resolve-Place $e.place
    if ($r) {
      $geoUsed[$r.key] = $r.ll
      $k = "$($r.key)|$yr"
      if (-not $seenStop[$k]) {
        $seenStop[$k] = $true
        $stops.Add([ordered]@{ name = $r.label; note = $lab.ToLower(); year = $yr; ll = $r.ll })
      }
    }
  }

  $sps = @($spouseOf[$id])
  $par = $parentsOf[$id]

  $people[$id] = [ordered]@{
    name    = $name
    sur     = $surn
    sex     = $p.sex
    branch  = $(if ($branch[$id]) { $branch[$id] } else { 'root' })
    years   = $years
    by      = $by
    dy      = $dy
    f       = $(if ($par) { $par.f } else { $null })
    m       = $(if ($par) { $par.m } else { $null })
    sp      = $(if ($sps.Count) { $sps[0] } else { $null })
    spouses = $sps
    birtP   = Short-Place $birt.place
    deatP   = Short-Place $deat.place
    occs    = @($occs)
    stops   = @($stops)
    rec     = @($recs)
  }
}

# ---------------------------------------------------------------- alias
# Slugs the page's hand-written stories and place notes refer to. Verified below.
$ALIAS = [ordered]@{
  chris = 'I352128205181'; wt1949 = 'I352793557923'; glenys = 'I352128205596'
  tommy = 'I352793883869'; ada = 'I352128205676'; harry = 'I352128205750'
  audrey = 'I352548944108'; wt1880 = 'I352793885171'; wt1827 = 'I352793886395'
  henryT = 'I352793885637'; eweatherill = 'I352793885189'; alfred = 'I352548944399'
  alice = 'I352548948349'; henryW = 'I352794090880'; adaB = 'I352794090881'
  charlie = 'I352794093690'; annieD = 'I352794093801'; arthurI = 'I352548945570'
  lilyLackey = 'I352548945571'; williamBlagg = 'I352551576887'; johnBlagg = 'I352551577622'
  georgeB = 'I352551574185'; thomasI = 'I352551786299'; josephI = 'I352551788878'
  thomasI_cord = 'I352793559056'; johnIngleby = 'I352552812685'
  # was I352551664279 — retired by an Ancestry merge on 14 Jul (a merge keeps one of
  # the two IDs and you don't get to choose which). This is the surviving record.
  wblowman = 'I352794101968'
}
$aliasOut = [ordered]@{}
$aliasBad = @()
foreach ($k in $ALIAS.Keys) {
  $v = $ALIAS[$k]
  if ($people.Contains($v)) { $aliasOut[$k] = $v } else { $aliasBad += "$k -> $v" }
}

# ---------------------------------------------------------------- geo
$geo = [ordered]@{}
foreach ($k in ($geoUsed.Keys | Sort-Object)) { $geo[$k] = $geoUsed[$k] }

# ---------------------------------------------------------------- diary
# The research journals, rendered from the markdown originals in Thompson/ and
# Ingleby/. The markdown stays the source of truth — edit those, rebuild.
#
# Sections are linked to PEOPLE by an explicit tag on the line after a heading:
#
#     ## Part One — Elizabeth Collins: the pit widow who married twice
#     <!-- ft: about=I352794086298 -->
#     ### The Champion who was not our Champion
#     <!-- ft: decoy=true -->
#
#   about=    this section IS about them   -> shown on their profile
#   mentions= a passing reference          -> shown as a lesser link
#   decoy=true  a REJECTED identification  -> never linked to anyone
#
# Names are never matched. They cannot be: "William Thompson" appears 58 times
# across the journals and three different men carry that name; "Mary Jane
# Nicholson" appears zero times (she is only ever "Mary Jane Blowman, ?née
# Nicholson"); and much of the prose is about people who were RULED OUT — the
# highest-scoring passage for Robert Dixon is the one proving a man is NOT him.
# An untagged section links to nobody.

function Get-Slug {
  param([string]$s)
  $x = ($s -replace '[^\w\s-]', '').Trim().ToLower()
  $x = $x -replace '\s+', '-'
  return $x
}

# "about=I1,I2 mentions=I3 decoy=true" -> hashtable.
# Pairs are separated by whitespace (and/or ';'); a value is a comma-list with no
# spaces. Parsed by matching key=value outright rather than splitting, so both
# separators work.
function Parse-FtTag {
  param([string]$line)
  if ($line -notmatch '<!--\s*ft:\s*(.*?)\s*-->') { return $null }
  $body = $matches[1]
  $out = @{ about = @(); mentions = @(); decoy = $false }
  foreach ($m in [regex]::Matches($body, '(\w+)\s*=\s*([^\s;]+)')) {
    $k = $m.Groups[1].Value.ToLower()
    $v = $m.Groups[2].Value.Trim()
    switch ($k) {
      'about' { $out.about = @($v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
      'mentions' { $out.mentions = @($v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
      'decoy' { $out.decoy = ($v -match '(?i)^(true|yes|1)$') }
    }
  }
  return $out
}

# Split a journal into heading-scoped sections, pulling out any ft: tag.
function Split-Sections {
  param([string]$md)
  $secs = [System.Collections.Generic.List[object]]::new()
  $cur = $null
  foreach ($line in ($md -split "`r?`n")) {
    if ($line -match '^(#{2,3})\s+(.*)$') {
      if ($cur) { $secs.Add($cur) }
      $cur = [ordered]@{
        level = $matches[1].Length
        heading = $matches[2].Trim()
        anchor = Get-Slug $matches[2]
        tag = $null
        lines = [System.Collections.Generic.List[string]]::new()
      }
      continue
    }
    if ($line -match '<!--\s*ft:') {
      if ($cur) { $cur.tag = Parse-FtTag $line }
      continue
    }
    if ($cur) { $cur.lines.Add($line) }
  }
  if ($cur) { $secs.Add($cur) }
  return $secs
}

# first real sentence(s) of a section, as plain text
function Get-Excerpt {
  param($lines, [int]$max = 240)
  foreach ($l in $lines) {
    $t = $l.Trim()
    if (-not $t) { continue }
    if ($t -match '^[>\-*#|]') { continue }      # skip quotes, lists, tables
    $t = $t -replace '\*\*|\*|`', ''
    $t = $t -replace '\[(.+?)\]\(.+?\)', '$1'
    if ($t.Length -lt 40) { continue }
    if ($t.Length -gt $max) { $t = $t.Substring(0, $max).TrimEnd() + '…' }
    return $t
  }
  return ''
}

function Md-Html {
  param([string]$md)
  $html = [System.Text.StringBuilder]::new()
  $inList = $false
  $inQuote = $false
  # Two journals open with an H3 used as a SUBTITLE, before any real section:
  #   # The Long Road to Beeston
  #   ### The Inglebys, from a Nidderdale farm to a Leeds council estate
  # The site already shows that as the entry's subtitle, so rendering it again as
  # a heading printed it twice. Drop an H3 that appears before the first H2.
  $seenH2 = $false
  $para = [System.Collections.Generic.List[string]]::new()

  function Inline { param([string]$s)
    $s = $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
    $s = $s -replace '\*\*\*(.+?)\*\*\*', '<strong><em>$1</em></strong>'
    $s = $s -replace '\*\*(.+?)\*\*', '<strong>$1</strong>'
    $s = $s -replace '(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)', '<em>$1</em>'
    $s = $s -replace '`(.+?)`', '<code>$1</code>'
    $s = $s -replace '\[(.+?)\]\((.+?)\)', '<a href="$2">$1</a>'
    return $s
  }
  function FlushPara { param($sb, $buf)
    if ($buf.Count) { [void]$sb.Append('<p>' + (Inline ($buf -join ' ')) + '</p>') ; $buf.Clear() }
  }

  foreach ($lineRaw in ($md -split "`r?`n")) {
    $line = $lineRaw.TrimEnd()

    if ($line -match '^\s*$') {
      FlushPara $html $para
      if ($inList) { [void]$html.Append('</ul>'); $inList = $false }
      if ($inQuote) { [void]$html.Append('</blockquote>'); $inQuote = $false }
      continue
    }
    if ($line -match '^---+\s*$') {
      FlushPara $html $para
      if ($inList) { [void]$html.Append('</ul>'); $inList = $false }
      [void]$html.Append('<hr>')
      continue
    }
    if ($line -match '^(#{1,6})\s+(.*)$') {
      FlushPara $html $para
      if ($inList) { [void]$html.Append('</ul>'); $inList = $false }
      $lvl = $matches[1].Length
      if ($lvl -eq 2) { $seenH2 = $true }
      # H1 is the page title, already in the site chrome. A leading H3 (before any
      # H2) is the journal's subtitle, already shown as the entry's sub — printing
      # it again duplicated it on the page.
      $isSubtitle = ($lvl -eq 3 -and -not $seenH2)
      if ($lvl -gt 1 -and -not $isSubtitle) {
        $anchor = Get-Slug $matches[2]
        [void]$html.Append("<h$lvl id=""$anchor"">" + (Inline $matches[2]) + "</h$lvl>")
      }
      continue
    }
    # person tags are metadata, never rendered
    if ($line -match '^\s*<!--\s*ft:.*-->\s*$') { continue }
    if ($line -match '^\s*[-*+]\s+(.*)$') {
      FlushPara $html $para
      if (-not $inList) { [void]$html.Append('<ul>'); $inList = $true }
      [void]$html.Append('<li>' + (Inline $matches[1]) + '</li>')
      continue
    }
    if ($line -match '^>\s?(.*)$') {
      FlushPara $html $para
      if (-not $inQuote) { [void]$html.Append('<blockquote>'); $inQuote = $true }
      [void]$html.Append('<p>' + (Inline $matches[1]) + '</p>')
      continue
    }
    $para.Add($line)
  }
  FlushPara $html $para
  if ($inList) { [void]$html.Append('</ul>') }
  if ($inQuote) { [void]$html.Append('</blockquote>') }
  return $html.ToString()
}

$diary = @()
$journalLinks = @{}      # personId -> list of links
$tagBadIds = @()         # tagged IDs that are not in the tree
$untagged = @()          # ##-level sections with no tag at all
$taggedCount = 0
$decoyCount = 0

$diaryManifest = Get-Content (Join-Path $root 'data/diary.json') -Raw | ConvertFrom-Json
foreach ($d in $diaryManifest) {
  $mdPath = Join-Path $root $d.file
  if (-not (Test-Path $mdPath)) { Write-Host "  !! diary source missing: $($d.file)" -ForegroundColor Yellow; continue }
  $md = [IO.File]::ReadAllText($mdPath)

  foreach ($sec in (Split-Sections $md)) {
    $tag = $sec.tag
    if (-not $tag) {
      if ($sec.level -eq 2) { $untagged += "$($d.id): $($sec.heading)" }
      continue
    }
    if ($tag.decoy) { $decoyCount++; continue }   # a rejected identification — link to nobody

    $excerpt = Get-Excerpt $sec.lines
    # the section's own prose, so a profile can show the whole chapter in place
    $secHtml = Md-Html (($sec.lines) -join "`n")
    foreach ($role in @('about', 'mentions')) {
      foreach ($personId in $tag.$role) {
        if (-not $people.Contains($personId)) { $tagBadIds += "$($d.id) '$($sec.heading)' -> $personId"; continue }
        if (-not $journalLinks[$personId]) { $journalLinks[$personId] = [System.Collections.Generic.List[object]]::new() }
        $journalLinks[$personId].Add([ordered]@{
            j       = $d.id
            jt      = $d.title
            branch  = $d.branch
            anchor  = $sec.anchor
            heading = $sec.heading
            excerpt = $excerpt
            html    = $secHtml
            role    = $role
          })
        $taggedCount++
      }
    }
  }

  $diary += [ordered]@{
    id     = $d.id
    title  = $d.title
    sub    = $d.sub
    date   = $d.date
    branch = $d.branch
    html   = Md-Html $md
  }
}

# attach to people
foreach ($personId in $journalLinks.Keys) {
  $links = @($journalLinks[$personId] | Sort-Object { if ($_.role -eq 'about') { 0 } else { 1 } })
  $people[$personId].journal = $links
}
foreach ($personId in $people.Keys) {
  if (-not $people[$personId].Contains('journal')) { $people[$personId].journal = @() }
}

# ------------------------------------------------- research gaps & sourced-ness
# The site should be as honest about what is MISSING as about what is known —
# "added" is not "sourced". These feed the "What we still don't know" panel and
# the sourced dot in the People list.
#
# Expected censuses: every census year the person was actually alive for. England
# ran a census every 10 years from 1841 (none in 1941; the 1939 Register stands in).
$CENSUS_YEARS = @(1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911, 1921, 1939)

$recordsPath = Join-Path $root 'data/records.json'
$docsFor = @{}
if (Test-Path $recordsPath) {
  $rj = Get-Content $recordsPath -Raw | ConvertFrom-Json
  foreach ($k in $rj.PSObject.Properties.Name) { $docsFor[$k] = $rj.$k }
}

foreach ($id in $ids) {
  $p = $people[$id]
  $ev = $PPL.$id.events

  $hasBirth = [bool](@($ev | Where-Object { $_.tag -in 'BIRT', 'BAPM', 'CHR' }).Count)
  $hasDeath = [bool](@($ev | Where-Object { $_.tag -in 'DEAT', 'BURI' }).Count)
  $hasMarr = [bool]($marrEv[$id])
  $censusYears = @($ev | Where-Object { $_.tag -eq 'RESI' } | ForEach-Object { Get-Year $_.date } | Where-Object { $_ })

  $gaps = @()
  if (-not $hasBirth) { $gaps += 'No birth or baptism record' }
  if (-not $hasMarr) { $gaps += 'No marriage record' }
  if (-not $hasDeath) { $gaps += 'No death or burial record' }
  if (-not $p.f) { $gaps += 'Father unknown' }
  if (-not $p.m) { $gaps += 'Mother unknown' }

  # Which censuses of their lifetime are missing?
  # STRICTLY between birth and death year. A census in the birth year may predate
  # the birth; a census in the death year may postdate the death — Elizabeth
  # Collins died in Feb 1911 and the census was taken that April, so demanding a
  # 1911 return for her would be nagging about a record that cannot exist.
  # Better to under-report a gap than to cry wolf.
  $missingCensus = @()
  if ($p.by) {
    $died = if ($p.dy) { $p.dy } else { $p.by + 85 }   # no death record: assume a normal span
    foreach ($cy in $CENSUS_YEARS) {
      if ($cy -le $p.by -or $cy -ge $died) { continue }
      if ($censusYears -contains $cy) { continue }
      $missingCensus += $cy
    }
  }
  if ($missingCensus.Count) {
    $label = if ($missingCensus.Count -eq 1) { "Not found in the $($missingCensus[0]) census" }
    else { "Not found in the $(($missingCensus -join ', ')) censuses" }
    $gaps += $label
  }

  # ConvertTo-Json turns an EMPTY PowerShell array into `null`, and collapses a
  # SINGLE-element array into a bare object. Both break `p.docs.map(...)` in the
  # browser. A List<object> always serialises as a proper JSON array.
  $gapList = [System.Collections.Generic.List[object]]::new()
  foreach ($g in $gaps) { $gapList.Add($g) }
  $p.gaps = $gapList

  $docList = [System.Collections.Generic.List[object]]::new()
  if ($docsFor.ContainsKey($id)) { foreach ($d in @($docsFor[$id])) { if ($d) { $docList.Add($d) } } }
  $p.docs = $docList

  # "done" in the sense of the full-vitals rule: everything a life should leave behind
  $p.sourced = ($hasBirth -and $hasMarr -and $hasDeath -and -not $missingCensus.Count)
  $p.unlinked = ($p.branch -eq 'root' -and $id -ne $ROOTID)
}

# ---------------------------------------------------------------- privacy
# A person is treated as LIVING if there is no death/burial record AND they were
# born within the last $PrivacyYears.
#
# The birth-year test matters. A naive "no death record = living" rule would hide
# Tommy Thompson (b.1919) purely because his death has not been sourced onto the
# tree yet — hiding a man who died decades ago, and who has a whole war story on
# the site. Anyone born before the cutoff is treated as dead regardless.
$living = @()
if ($Public) {
  $cutoff = (Get-Date).Year - $PrivacyYears
  foreach ($id in @($people.Keys)) {
    $p = $people[$id]
    $isLiving = (-not $p.dy) -and ($p.by) -and ($p.by -gt $cutoff)
    if (-not $p.by -and -not $p.dy) { $isLiving = $false }   # undated & undocumented: long dead
    if (-not $isLiving) { continue }

    $living += "$($p.name) (b. $($p.by))"
    # keep name + relationships so the tree still connects; drop everything else
    $p.years = 'Living'
    $p.by = $null; $p.dy = $null
    $p.birtP = ''; $p.deatP = ''
    $p.occs = @(); $p.stops = @(); $p.rec = @(); $p.journal = @()
    $p.gaps = [System.Collections.Generic.List[object]]::new()
    $p.docs = [System.Collections.Generic.List[object]]::new()
    $p.sourced = $false
  }
}

# ---------------------------------------------------------------- the method
# The front-page "how I know it's the right person" section.
#
# Prefer data/method.md — the same rules written in Chris's own voice, for a
# reader of the site. Fall back to RULES-AND-INSTRUCTIONS.md, which is the
# working spec written as instructions. Both parse the same way, so whichever is
# present, the front page follows the file rather than a hand-copied duplicate.
$rules = [ordered]@{ standing = @(); method = ''; hard = @(); intro = ''; closing = '' }
$rulesPath = Join-Path $root 'data/method.md'
if (-not (Test-Path $rulesPath)) { $rulesPath = Join-Path $family 'RULES-AND-INSTRUCTIONS.md' }
if (Test-Path $rulesPath) {
  $rl = Get-Content $rulesPath
  $section = ''
  for ($i = 0; $i -lt $rl.Count; $i++) {
    $line = $rl[$i]
    if ($line -match '^##\s+THE STANDING RULE') { $section = 'standing'; continue }
    if ($line -match '^##\s+THE HARD RULES') { $section = 'hard'; continue }
    if ($line -match '^##\s' ) { $section = ''; continue }

    if ($section -eq 'standing') {
      # the blockquote holds the rule; the "Method:" line is called out separately
      if ($line -match '^>\s*\*\*(.+?)\*\*\s*$') {
        $txt = $matches[1]
        if ($txt -match '^Method:') { $rules.method = ($txt -replace '^Method:\s*', '') }
        else { $rules.standing += $txt }
      }
      # the paragraph after the blockquote is the intro prose
      elseif ($line -notmatch '^[>\-#\s*]' -and $line.Trim() -and -not $rules.intro) {
        $rules.intro = ($line.Trim() -replace '\*\*(.+?)\*\*', '$1' -replace '\*(.+?)\*', '$1')
      }
    }
    if ($section -eq 'hard') {
      # "1. **Direct line, generation by generation** *(memory: ...)*"
      if ($line -match '^\s*(\d+)\.\s+\*\*(.+?)\*\*') {
        $n = $matches[1]; $title = $matches[2]
        $body = ''
        if ($i + 1 -lt $rl.Count) { $body = $rl[$i + 1].Trim() }
        # strip markdown emphasis for display
        $body = $body -replace '\*\*(.+?)\*\*', '$1' -replace '\*(.+?)\*', '$1'
        $rules.hard += [ordered]@{ n = $n; title = $title; body = $body }
      }
    }
  }
  # the closing italic line at the foot of the file
  $last = @($rl | Where-Object { $_ -match '^\*[^*].+\*\s*$' } | Select-Object -Last 1)
  if ($last.Count -and $rules.hard.Count) {
    $rules.closing = ($last[0].Trim() -replace '^\*|\*$', '' -replace '\*\*(.+?)\*\*', '$1')
  }
}
Write-Host "  method rules    : $($rules.hard.Count) hard rules, $($rules.standing.Count)-line standing rule"

# ---------------------------------------------------------------- emit
$doc = [ordered]@{
  people = $people
  alias  = $aliasOut
  geo    = $geo
  diary  = @($diary)
  rules  = $rules
  root   = $ROOTID
  meta   = [ordered]@{ exported = $G.meta.exported; people = $people.Count; built = 'Build-FamilyData.ps1' }
}

$json = $doc | ConvertTo-Json -Depth 12 -Compress
[IO.File]::WriteAllText((Join-Path $root $Out), "window.FAMILY = $json;`n")

$unres = [ordered]@{}
foreach ($k in ($unresolved.Keys | Sort-Object { -$unresolved[$_] })) { $unres[$k] = $unresolved[$k] }
[IO.File]::WriteAllText((Join-Path $root 'data/places-unresolved.json'), ($unres | ConvertTo-Json -Depth 3))

Write-Host "wrote $Out$(if($Public){'   [PUBLIC BUILD — living people redacted]'})"
Write-Host "  people          : $($people.Count)"
if ($Public) {
  Write-Host "  REDACTED (living, $PrivacyYears-yr rule): $($living.Count)" -ForegroundColor Cyan
  $living | ForEach-Object { Write-Host "       $_" -ForegroundColor Cyan }
}
Write-Host "  branch thompson : $(@($people.Values | Where-Object branch -eq 'thompson').Count)"
Write-Host "  branch ingleby  : $(@($people.Values | Where-Object branch -eq 'ingleby').Count)"
Write-Host "  branch root     : $(@($people.Values | Where-Object branch -eq 'root').Count)"
Write-Host "  places pinned   : $($geo.Count)"
Write-Host "  places UNRESOLVED (no pin, listed in data/places-unresolved.json): $($unres.Count)"
if ($aliasBad.Count) { Write-Host "  !! ALIAS NOT IN TREE: $($aliasBad -join ', ')" -ForegroundColor Red }

Write-Host ""
Write-Host "  journals        : $($diary.Count)"
Write-Host "  section links   : $taggedCount  (to $($journalLinks.Count) people)"
Write-Host "  decoy sections  : $decoyCount  (deliberately linked to nobody)"
if ($tagBadIds.Count) {
  Write-Host "  !! TAGGED ID NOT IN TREE ($($tagBadIds.Count)) — fix the tag or re-export:" -ForegroundColor Red
  $tagBadIds | ForEach-Object { Write-Host "       $_" -ForegroundColor Red }
}
if ($untagged.Count) {
  Write-Host "  untagged sections (no profile link — add <!-- ft: ... --> to include):" -ForegroundColor Yellow
  $untagged | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkYellow }
}
