# Renders the NikoDeck icons from the NIKO logo (docs/images/logo-niko.png, a 1254 px square):
#   agent/PhoneBox.Agent/phonebox.ico                              Windows agent, tray and favicon (16 to 256 px)
#   android/app/src/main/res/mipmap-*/ic_launcher.png              launcher icon before Android 8 (48 to 192 px)
#   android/app/src/main/res/mipmap-*/ic_launcher_foreground.png   adaptive icon foreground, Android 8+ (108 dp)
#   packaging/macos/PhoneBox.icns                                  macOS app icon (PNG entries, 16 to 1024 px)
# The word NIKO is too small to read at launcher sizes, so the icons are a crop centred on the "N" and the inner
# rings, on the logo's near-black background (#03070D, also the adaptive icon's background colour in themes.xml).
# The file names stay those of upstream PhoneBox, so the project files that point at them need no change.
# Usage: powershell -NoProfile -File tools/make-icon.ps1 [-Logo <png>]
param([string]$Logo = (Join-Path $PSScriptRoot '..\docs\images\logo-niko.png'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$src = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Logo).Path)
$unit = $src.Width / 1254.0
$background = [System.Drawing.ColorTranslator]::FromHtml('#03070D')

# crops in the coordinates of the 1254 px logo: centre x, centre y, side
function New-Crop([double]$cx, [double]$cy, [double]$side) {
    New-Object System.Drawing.RectangleF ([float](($cx - $side / 2) * $unit)), ([float](($cy - $side / 2) * $unit)), ([float]($side * $unit)), ([float]($side * $unit))
}
$tight = New-Crop 648 568 400   # the N with a little of the ring: 16 to 32 px
$core = New-Crop 640 560 500    # the N and the inner rings
$wide = New-Crop 640 560 750    # adaptive foreground: the visible 72 of its 108 dp show the core crop

function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-Graphics($bmp) {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    return $g
}

# the crop scaled to a full, opaque square
function New-Square($crop, [int]$size, [double]$fadeFrom = 0) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = New-Graphics $bmp
    $g.Clear($background)
    $attributes = New-Object System.Drawing.Imaging.ImageAttributes
    $attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY) # no light seam along the edges
    $dest = New-Object System.Drawing.Rectangle 0, 0, $size, $size
    $g.DrawImage($src, $dest, [float]$crop.X, [float]$crop.Y, [float]$crop.Width, [float]$crop.Height, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
    if ($fadeFrom -gt 0) {
        # fades out what lies below fadeFrom (the word NIKO), so it cannot peek out of the adaptive icon's margin
        $top = [float]($size * $fadeFrom); $band = [float]($size * 0.05)
        $fade = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.PointF 0, $top), (New-Object System.Drawing.PointF 0, ($top + $band)), ([System.Drawing.Color]::FromArgb(0, $background)), $background
        $g.FillRectangle($fade, [float]0, $top, [float]$size, $band)
        $g.FillRectangle((New-Object System.Drawing.SolidBrush $background), [float]0, ($top + $band - 1), [float]$size, [float]($size - $top - $band + 1))
        $fade.Dispose()
    }
    $g.Dispose()
    return $bmp
}

# the crop in a rounded square of tileFraction x size, transparent around it
function New-Tile($crop, [int]$size, [double]$tileFraction, [double]$radiusFraction) {
    $tile = [int][Math]::Round($size * $tileFraction)
    $offset = [float](($size - $tile) / 2.0)
    $square = New-Square $crop $tile
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = New-Graphics $bmp
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.TextureBrush $square
    $brush.TranslateTransform($offset, $offset)
    $g.FillPath($brush, (New-RoundRect $offset $offset $tile $tile ([float]($tile * $radiusFraction))))
    $g.Dispose(); $brush.Dispose(); $square.Dispose()
    return $bmp
}

function Get-PngBytes($bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return , $ms.ToArray()
}

function Save-Png($bmp, [string]$path) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [System.IO.File]::WriteAllBytes($path, (Get-PngBytes $bmp))
}

# 32-bit DIB icon entry (BITMAPINFOHEADER, bottom-up BGRA rows, then the 1-bit AND mask), readable by every icon API
function Get-DibBytes($bmp) {
    $n = $bmp.Width
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter $ms
    $w.Write([uint32]40); $w.Write([int32]$n); $w.Write([int32]($n * 2)); $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]0); $w.Write([uint32]0); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    for ($y = $n - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $n; $x++) { $c = $bmp.GetPixel($x, $y); $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A) }
    }
    $maskRow = [int]([Math]::Ceiling($n / 32.0) * 4)
    $w.Write((New-Object byte[] ($maskRow * $n))) # all zero: the alpha channel decides
    $w.Flush(); $bmp.Dispose()
    return , $ms.ToArray()
}

# --- Windows .ico: DIB entries up to 128 px (the tray and old APIs), PNG for 256 px ---
$icoPath = Join-Path $root 'agent\PhoneBox.Agent\phonebox.ico'
$sizes = 16, 24, 32, 48, 64, 128, 256
$images = foreach ($sz in $sizes) {
    $crop = if ($sz -le 32) { $tight } else { $core }
    $tile = New-Tile $crop $sz 1.0 0.18
    if ($sz -ge 256) { , (Get-PngBytes $tile) } else { , (Get-DibBytes $tile) }
}
$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $sz = $sizes[$i]; $len = $images[$i].Length
    $dim = if ($sz -ge 256) { 0 } else { $sz }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim)
    $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
    $offset += $len
}
foreach ($img in $images) { $bw.Write([byte[]]$img) }
$bw.Close()
"icon written: $icoPath ($((Get-Item $icoPath).Length) bytes)"

# --- Android launcher icons ---
$res = Join-Path $root 'android\app\src\main\res'
$densities = [ordered]@{ mdpi = 1.0; hdpi = 1.5; xhdpi = 2.0; xxhdpi = 3.0; xxxhdpi = 4.0 }
foreach ($d in $densities.Keys) {
    $f = $densities[$d]
    Save-Png (New-Tile $core ([int](48 * $f)) 0.92 0.18) (Join-Path $res "mipmap-$d\ic_launcher.png")
    Save-Png (New-Square $wide ([int](108 * $f)) 0.80) (Join-Path $res "mipmap-$d\ic_launcher_foreground.png")
}
"Android launcher icons written to $res\mipmap-*"

# --- macOS .icns: PNG entries; the tile is 824 of 1024 px, as macOS app icons are drawn ---
$icnsPath = Join-Path $root 'packaging\macos\PhoneBox.icns'
$entries = @(@('icp4', 16), @('icp5', 32), @('icp6', 64), @('ic07', 128), @('ic08', 256), @('ic09', 512), @('ic10', 1024),
    @('ic11', 32), @('ic12', 64), @('ic13', 256), @('ic14', 512))
function Get-BigEndian([uint32]$v) { $b = [BitConverter]::GetBytes($v); [Array]::Reverse($b); return , $b }
$body = New-Object System.IO.MemoryStream
foreach ($e in $entries) {
    $crop = if ($e[1] -le 32) { $tight } else { $core }
    $png = Get-PngBytes (New-Tile $crop $e[1] (824 / 1024.0) 0.225)
    $type = [System.Text.Encoding]::ASCII.GetBytes($e[0])
    $body.Write($type, 0, 4)
    $len = Get-BigEndian ([uint32]($png.Length + 8)); $body.Write($len, 0, 4)
    $body.Write($png, 0, $png.Length)
}
$out = New-Object System.IO.MemoryStream
$magic = [System.Text.Encoding]::ASCII.GetBytes('icns'); $out.Write($magic, 0, 4)
$total = Get-BigEndian ([uint32]($body.Length + 8)); $out.Write($total, 0, 4)
$body.WriteTo($out)
[System.IO.File]::WriteAllBytes($icnsPath, $out.ToArray())
"icns written: $icnsPath ($((Get-Item $icnsPath).Length) bytes)"
$src.Dispose()
