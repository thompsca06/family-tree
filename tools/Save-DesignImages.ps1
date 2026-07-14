<#
Save-DesignImages.ps1 — decode images fetched from the Claude design project.

DesignSync get_file returns binary files as base64 and persists the full response
to a tool-results file (only a preview reaches the model's context). This scans
those files and writes any image response out to its own project-relative path,
which the response itself carries — so nothing has to be mapped by hand.

    pwsh tools/Save-DesignImages.ps1
#>
param(
  [string]$ToolResults = "C:\Users\Chris\.claude\projects\c--Users-Chris-OneDrive-Family\d4b7bf24-834e-4899-ac61-7803445d3ae4\tool-results"
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$written = 0; $skipped = 0
foreach ($f in (Get-ChildItem $ToolResults -Filter *.txt -File)) {
  $raw = [IO.File]::ReadAllText($f.FullName)
  $i = $raw.IndexOf('{"method"')
  if ($i -lt 0) { continue }
  try { $j = $raw.Substring($i) | ConvertFrom-Json } catch { continue }
  if ($j.method -ne 'get_file' -or -not $j.path -or -not $j.content) { continue }
  if ($j.path -notmatch '(?i)\.(png|jpe?g|gif|webp)$') { continue }

  $dest = Join-Path $root $j.path
  New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
  try { $bytes = [Convert]::FromBase64String($j.content) } catch { $skipped++; continue }
  [IO.File]::WriteAllBytes($dest, $bytes)
  $written++
  Write-Host ("  {0,-42} {1,8} bytes" -f $j.path, $bytes.Length)
}
Write-Host "wrote $written image(s); $skipped unreadable"

# report which referenced images are still missing
$html = Get-Content (Join-Path $root 'Family Tree.dc.html') -Raw
$refs = [regex]::Matches($html, 'img/[A-Za-z0-9_/.-]*\.(?:png|jpg)') | ForEach-Object { $_.Value } | Sort-Object -Unique
$missing = @($refs | Where-Object { -not (Test-Path (Join-Path $root $_)) })
Write-Host "referenced: $($refs.Count)   present: $($refs.Count - $missing.Count)   MISSING: $($missing.Count)"
$missing | ForEach-Object { Write-Host "  missing: $_" -ForegroundColor Yellow }
