<#
  Draws the program icon (a rounded blue-violet square with the "move" arrows)
  and writes it as app.ico with sizes 16-256. Run by build.ps1 when app.ico is missing.
  Written by Claude 2026-10-02.
#>
param([string]$Out = (Join-Path $PSScriptRoot 'app.ico'))
Add-Type -AssemblyName System.Drawing

function New-IconBitmap([int]$Size) {
  $bmp = New-Object Drawing.Bitmap $Size, $Size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = 'AntiAliasGridFit'
  $g.Clear([Drawing.Color]::Transparent)
  $r = [Math]::Max(2, [int]($Size * 0.22))
  $rect = New-Object Drawing.RectangleF 0, 0, ($Size - 1), ($Size - 1)
  $path = New-Object Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
  $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
  $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
  $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  $brush = New-Object Drawing.Drawing2D.LinearGradientBrush $rect, ([Drawing.Color]::FromArgb(255, 0x5B, 0x8D, 0xEF)), ([Drawing.Color]::FromArgb(255, 0x7B, 0x5B, 0xEF)), 45.0
  $g.FillPath($brush, $path)
  $fontName = 'Segoe Fluent Icons'
  $installed = (New-Object Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
  if ($installed -notcontains $fontName) { $fontName = 'Segoe MDL2 Assets' }
  $font = New-Object Drawing.Font $fontName, ([single]($Size * 0.48)), ([Drawing.FontStyle]::Regular), ([Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object Drawing.StringFormat
  $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $g.DrawString([string][char]0xE8AB, $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF 0, ($Size * 0.02), $Size, $Size), $sf)
  $g.Dispose()
  return $bmp
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$images = foreach ($s in $sizes) {
  $bmp = New-IconBitmap $s
  $ms = New-Object IO.MemoryStream
  $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  , $ms.ToArray()
}
$fs = [IO.File]::Create($Out)
$w = New-Object IO.BinaryWriter $fs
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]
  $w.Write([byte]$(if ($s -ge 256) { 0 } else { $s })); $w.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))
  $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32)
  $w.Write([uint32]$images[$i].Length); $w.Write([uint32]$offset)
  $offset += $images[$i].Length
}
foreach ($img in $images) { $w.Write($img) }
$w.Flush(); $fs.Dispose()
"icon written: $Out"
