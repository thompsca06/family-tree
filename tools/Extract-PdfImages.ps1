<#
Extract-PdfImages.ps1 — recover the war-story photos from the source PDFs.

Why: the design project's img/tommy/* and img/harry/* were extracted from
"Thomas Thompson - The War.pdf" and "harry-ingleby-the-war2.pdf". They cannot be
pulled back down through DesignSync — get_file caps a response at 256 KiB and
these are far bigger, so they arrive truncated and corrupt.

But the design filenames encode the pixel size (t_p3_1830x1743.png), so an image
extracted from the PDF can be matched to its filename by EXACT dimensions — no
guessing about which photo is which.

Handles both encodings present:
  * DCTDecode  -> the stream already IS a JPEG; carve it out verbatim
  * FlateDecode -> raw samples; inflate, then rebuild an image from
                   /Width /Height /ColorSpace /BitsPerComponent

    pwsh tools/Extract-PdfImages.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$family = Split-Path -Parent $root
Add-Type -AssemblyName System.Drawing

$PDFS = @(
  @{ file = Join-Path $family 'Thompson\Thomas Thompson - The War.pdf' },
  @{ file = Join-Path $family 'Ingleby\harry-ingleby-the-war2.pdf' }
)

# what we still need, keyed by "WxH"
$html = Get-Content (Join-Path $root 'Family Tree.dc.html') -Raw
$want = @{}
foreach ($m in [regex]::Matches($html, 'img/(?:tommy|harry)/[A-Za-z0-9_.-]*?_(\d+)x(\d+)\.png')) {
  $path = $m.Value
  if (Test-Path (Join-Path $root $path)) { continue }
  $key = "$($m.Groups[1].Value)x$($m.Groups[2].Value)"
  if (-not $want[$key]) { $want[$key] = @() }
  $want[$key] += $path
}
Write-Host "still needed: $($want.Values | ForEach-Object { $_ } | Measure-Object).Count image(s) across $($want.Count) distinct sizes"
$want.Keys | Sort-Object | ForEach-Object { Write-Host "   $_  -> $($want[$_] -join ', ')" }

function Inflate([byte[]]$data) {
  # PDF Flate streams are zlib: 2-byte header, then raw deflate
  $ms = [IO.MemoryStream]::new($data, 2, $data.Length - 2)
  $ds = [IO.Compression.DeflateStream]::new($ms, [IO.Compression.CompressionMode]::Decompress)
  $out = [IO.MemoryStream]::new()
  $ds.CopyTo($out)
  $ds.Dispose(); $ms.Dispose()
  return $out.ToArray()
}

$found = 0; $saved = 0
foreach ($pdf in $PDFS) {
  if (-not (Test-Path $pdf.file)) { Write-Host "missing: $($pdf.file)" -ForegroundColor Yellow; continue }
  $bytes = [IO.File]::ReadAllBytes($pdf.file)
  $ascii = [Text.Encoding]::GetEncoding(28591).GetString($bytes)   # latin1: byte-preserving

  # find each image XObject dictionary and the stream that follows it
  foreach ($m in [regex]::Matches($ascii, '<<(?<dict>[^<>]*?/Subtype\s*/Image.*?)>>\s*stream\r?\n', 'Singleline')) {
    $dict = $m.Groups['dict'].Value
    $start = $m.Index + $m.Length

    $len = 0
    if ($dict -match '/Length\s+(\d+)') { $len = [int]$matches[1] } else { continue }
    if ($start + $len -gt $bytes.Length) { continue }

    $w = 0; $h = 0
    if ($dict -match '/Width\s+(\d+)') { $w = [int]$matches[1] }
    if ($dict -match '/Height\s+(\d+)') { $h = [int]$matches[1] }
    if (-not $w -or -not $h) { continue }
    $found++

    $key = "${w}x${h}"
    if (-not $want.ContainsKey($key)) { continue }     # not one we need
    if ($want[$key].Count -eq 0) { continue }          # every file of this size already filled

    # Several files can share one size — Tommy's five medals are 202x296, 201x296,
    # 202x296, 201x296, 202x296. Consume them in PDF order, one filename per image,
    # so each medal gets its own picture instead of the first one being copied to all.
    $dest = $want[$key][0]
    $want[$key] = @($want[$key] | Select-Object -Skip 1)

    $raw = New-Object byte[] $len
    [Array]::Copy($bytes, $start, $raw, 0, $len)

    $bmp = $null
    try {
      if ($dict -match 'DCTDecode') {
        $ms = [IO.MemoryStream]::new($raw)
        $bmp = [Drawing.Image]::FromStream($ms)
      }
      elseif ($dict -match 'FlateDecode') {
        $px = Inflate $raw
        $bpc = 8; if ($dict -match '/BitsPerComponent\s+(\d+)') { $bpc = [int]$matches[1] }
        if ($bpc -ne 8) { continue }
        $comp = [Math]::Floor($px.Length / ($w * $h))
        if ($comp -lt 1) { continue }
        $bmp = [Drawing.Bitmap]::new($w, $h, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $bd = $bmp.LockBits([Drawing.Rectangle]::new(0, 0, $w, $h), [Drawing.Imaging.ImageLockMode]::WriteOnly, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $row = New-Object byte[] ($w * 3)
        for ($y = 0; $y -lt $h; $y++) {
          for ($x = 0; $x -lt $w; $x++) {
            $si = ($y * $w + $x) * $comp
            if ($comp -ge 3) { $r = $px[$si]; $g = $px[$si + 1]; $b = $px[$si + 2] }
            else { $r = $px[$si]; $g = $px[$si]; $b = $px[$si] }
            $row[$x * 3] = $b; $row[$x * 3 + 1] = $g; $row[$x * 3 + 2] = $r   # BGR
          }
          [Runtime.InteropServices.Marshal]::Copy($row, 0, [IntPtr]::Add($bd.Scan0, $y * $bd.Stride), $row.Length)
        }
        $bmp.UnlockBits($bd)
      }
      else { continue }

      $out = Join-Path $root $dest
      New-Item -ItemType Directory -Force (Split-Path -Parent $out) | Out-Null
      $bmp.Save($out, [Drawing.Imaging.ImageFormat]::Png)
      $saved++
      Write-Host ("  {0,-40} {1}x{2} from {3}" -f $dest, $w, $h, (Split-Path $pdf.file -Leaf)) -ForegroundColor Green
      if ($want[$key].Count -eq 0) { $want.Remove($key) }
    }
    catch { }
    finally { if ($bmp) { $bmp.Dispose() } }
  }
}

Write-Host ""
Write-Host "image objects scanned: $found   saved: $saved"
if ($want.Count) {
  Write-Host "STILL MISSING:" -ForegroundColor Yellow
  $want.Keys | Sort-Object | ForEach-Object { Write-Host "   $_  $($want[$_] -join ', ')" -ForegroundColor Yellow }
}
