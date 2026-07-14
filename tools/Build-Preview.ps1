<#
Build-Preview.ps1 — make a standalone, double-clickable copy of the site.

The .dc.html is a Claude *design component*: it uses React but never loads it,
because the claude.ai design host injects React/ReactDOM/support.js for it.
To view the same page locally we just supply those ourselves.

Output: site/preview.html  (open it in a browser — needs internet for React,
Leaflet and the map tiles, but the family data is local).

Regenerate after every Build-FamilyData run:  pwsh tools/Build-Preview.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'Family Tree.dc.html'
$out = Join-Path $root 'preview.html'

$html = [IO.File]::ReadAllText($src)

$inject = @'
<script crossorigin src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
<script crossorigin src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
'@

# React must be defined before support.js runs, so put it first in <head>.
$html = $html -replace '(?i)(<head>)', "`$1`n$inject"

[IO.File]::WriteAllText($out, $html)
Write-Host "wrote preview.html  ->  $out"
Write-Host "open it with:  start `"$out`""
