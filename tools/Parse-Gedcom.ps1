<#
Parse-Gedcom.ps1 — full-fidelity GEDCOM 5.5.1 -> JSON.

Reads the Ancestry export and projects it to JSON without inferring anything:
dates stay verbatim, places stay verbatim, every event keeps its citations.

    pwsh tools/Parse-Gedcom.ps1
#>
param(
  [string]$Ged = "src/thompson_tree.ged",
  [string]$Out = "data/gedcom.json"
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$gedPath = Join-Path $root $Ged
$outPath = Join-Path $root $Out
New-Item -ItemType Directory -Force (Split-Path -Parent $outPath) | Out-Null

class Node {
  [string]$Tag
  [string]$Xref
  [string]$Value
  [System.Collections.Generic.List[Node]]$Kids
  Node() { $this.Kids = [System.Collections.Generic.List[Node]]::new() }
}

# ---------- lex ----------
$records = [System.Collections.Generic.List[Node]]::new()
$stack = @{}
$last = $null

foreach ($line in [IO.File]::ReadLines($gedPath)) {
  if ($line -match '^\s*$') { continue }
  if ($line -notmatch '^(\d+)\s+(?:(@[^@]+@)\s+)?(\w+)(?:\s(.*))?$') { continue }
  $lvl = [int]$matches[1]; $xref = $matches[2]; $tag = $matches[3]; $val = $matches[4]

  # CONT adds a newline, CONC concatenates — both extend the previous node's value
  if ($tag -eq 'CONT') { if ($last) { $last.Value = "$($last.Value)`n$val" }; continue }
  if ($tag -eq 'CONC') { if ($last) { $last.Value = "$($last.Value)$val" }; continue }

  $n = [Node]::new(); $n.Tag = $tag; $n.Xref = $xref; $n.Value = $val
  if ($lvl -eq 0) { $records.Add($n) } else { $stack[$lvl - 1].Kids.Add($n) }
  $stack[$lvl] = $n
  $last = $n
}

# ---------- helpers ----------
function Kid ([Node]$n, [string]$tag) { $n.Kids | Where-Object Tag -eq $tag | Select-Object -First 1 }
function Kidz ([Node]$n, [string]$tag) { @($n.Kids | Where-Object Tag -eq $tag) }
function KidVal ([Node]$n, [string]$tag) { $k = Kid $n $tag; if ($k) { $k.Value } else { $null } }
function Deref ([string]$v) { if ($v) { $v -replace '@', '' } else { $null } }

function Cites ([Node]$n) {
  @(Kidz $n 'SOUR' | ForEach-Object {
      [ordered]@{ sid = (Deref $_.Value); page = (KidVal $_ 'PAGE'); apid = (KidVal $_ '_APID') }
    })
}

function Ev ([Node]$n) {
  [ordered]@{
    tag   = $n.Tag
    type  = (KidVal $n 'TYPE')
    date  = (KidVal $n 'DATE')
    place = (KidVal $n 'PLAC')
    note  = (KidVal $n 'NOTE')
    cites = (Cites $n)
  }
}

# Anything time-and-place shaped. Everything else is ignored rather than mangled.
$EVENT_TAGS = @(
  'BIRT', 'CHR', 'BAPM', 'DEAT', 'BURI', 'RESI', 'OCCU', 'EMIG', 'IMMI', 'CENS',
  'PROB', 'MARR', 'DIV', 'EVEN', 'RETI', 'GRAD', 'NATU', '_MILT', '_DSCR'
)

# ---------- project ----------
$people = [ordered]@{}
$fams = [ordered]@{}
$sources = [ordered]@{}

foreach ($r in $records) {
  switch ($r.Tag) {
    'INDI' {
      $id = Deref $r.Xref
      $nameNode = Kid $r 'NAME'
      $raw = if ($nameNode) { $nameNode.Value } else { '' }
      $givn = if ($nameNode) { KidVal $nameNode 'GIVN' } else { $null }
      $surn = if ($nameNode) { KidVal $nameNode 'SURN' } else { $null }
      if (-not $givn -and $raw -match '^([^/]*)') { $givn = $matches[1].Trim() }
      if (-not $surn -and $raw -match '/([^/]*)/') { $surn = $matches[1].Trim() }

      $people[$id] = [ordered]@{
        id     = $id
        raw    = $raw
        givn   = $givn
        surn   = $surn
        sex    = (KidVal $r 'SEX')
        famc   = @(Kidz $r 'FAMC' | ForEach-Object { Deref $_.Value })   # family as child -> parents
        fams   = @(Kidz $r 'FAMS' | ForEach-Object { Deref $_.Value })   # family as spouse
        events = @($r.Kids | Where-Object { $EVENT_TAGS -contains $_.Tag } | ForEach-Object { Ev $_ })
        notes  = @(Kidz $r 'NOTE' | ForEach-Object { $_.Value })
        cites  = (Cites $r)
        media  = @(Kidz $r 'OBJE' | ForEach-Object { [ordered]@{ file = (KidVal $_ 'FILE'); titl = (KidVal $_ 'TITL') } })
      }
    }
    'FAM' {
      $id = Deref $r.Xref
      $fams[$id] = [ordered]@{
        id     = $id
        husb   = (Deref (KidVal $r 'HUSB'))
        wife   = (Deref (KidVal $r 'WIFE'))
        chil   = @(Kidz $r 'CHIL' | ForEach-Object { Deref $_.Value })
        events = @($r.Kids | Where-Object { $EVENT_TAGS -contains $_.Tag } | ForEach-Object { Ev $_ })
      }
    }
    'SOUR' {
      if (-not $r.Xref) { break }
      $sources[(Deref $r.Xref)] = [ordered]@{
        id    = (Deref $r.Xref)
        title = (KidVal $r 'TITL')
        auth  = (KidVal $r 'AUTH')
        publ  = (KidVal $r 'PUBL')
      }
    }
  }
}

$head = $records | Where-Object Tag -eq 'HEAD' | Select-Object -First 1
$doc = [ordered]@{
  meta    = [ordered]@{
    source     = $Ged
    exported   = (KidVal $head 'DATE')
    people     = $people.Count
    families   = $fams.Count
    sourceRecs = $sources.Count
  }
  people  = $people
  fams    = $fams
  sources = $sources
}

[IO.File]::WriteAllText($outPath, ($doc | ConvertTo-Json -Depth 12))
Write-Host "wrote $Out — $($people.Count) people, $($fams.Count) families, $($sources.Count) sources (exported $($doc.meta.exported))"
