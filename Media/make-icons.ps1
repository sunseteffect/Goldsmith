# Draws Goldsmith's icon (coin monogram) and logo mark (hammer and ingot)
# at 128x128 with transparent backgrounds, and saves each as a 32-bit TGA
# for WoW plus a PNG preview.
param([string]$OutDir, [string]$PreviewDir)

Add-Type -AssemblyName System.Drawing

function C([string]$hex, [int]$a = 255) {
    return [System.Drawing.Color]::FromArgb($a,
        [Convert]::ToInt32($hex.Substring(0, 2), 16),
        [Convert]::ToInt32($hex.Substring(2, 2), 16),
        [Convert]::ToInt32($hex.Substring(4, 2), 16))
}

function GoldBrush([System.Drawing.RectangleF]$r) {
    $b = New-Object System.Drawing.Drawing2D.LinearGradientBrush($r, (C "fbe7a6"), (C "a47a22"), 45.0)
    $blend = New-Object System.Drawing.Drawing2D.ColorBlend(3)
    $blend.Colors = @((C "fbe7a6"), (C "e8c25a"), (C "a47a22"))
    $blend.Positions = @(0.0, 0.5, 1.0)
    $b.InterpolationColors = $blend
    return $b
}

function SteelBrush([System.Drawing.RectangleF]$r) {
    return New-Object System.Drawing.Drawing2D.LinearGradientBrush($r, (C "c4c9d2"), (C "5f646f"), 90.0)
}

function NewCanvas() {
    $bmp = New-Object System.Drawing.Bitmap(128, 128, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    return @($bmp, $g)
}

# 32-bit uncompressed TGA, rows bottom to top (TGA's default origin),
# pixels as B, G, R, A
function SaveTga($bmp, [string]$path) {
    $w = $bmp.Width; $h = $bmp.Height
    $header = New-Object byte[] 18
    $header[2] = 2
    $header[12] = $w -band 0xFF; $header[13] = ($w -shr 8) -band 0xFF
    $header[14] = $h -band 0xFF; $header[15] = ($h -shr 8) -band 0xFF
    $header[16] = 32
    $header[17] = 8
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $raw = New-Object byte[] ($stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
    $bmp.UnlockBits($data)
    $pixels = New-Object byte[] ($w * 4 * $h)
    for ($y = 0; $y -lt $h; $y++) {
        [Array]::Copy($raw, ($h - 1 - $y) * $stride, $pixels, $y * $w * 4, $w * 4)
    }
    $out = New-Object byte[] (18 + $pixels.Length)
    [Array]::Copy($header, 0, $out, 0, 18)
    [Array]::Copy($pixels, 0, $out, 18, $pixels.Length)
    [System.IO.File]::WriteAllBytes($path, $out)
}

# A: coin monogram
$canvas = NewCanvas; $bmp = $canvas[0]; $g = $canvas[1]
$coin = New-Object System.Drawing.RectangleF(6, 6, 116, 116)
$g.FillEllipse((GoldBrush $coin), $coin)
$g.DrawEllipse((New-Object System.Drawing.Pen((C "7a5a16"), 6)), $coin)
$g.DrawEllipse((New-Object System.Drawing.Pen((C "a47a22"), 3)), 20, 20, 88, 88)
$font = New-Object System.Drawing.Font("Georgia", 58, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$format = New-Object System.Drawing.StringFormat
$format.Alignment = [System.Drawing.StringAlignment]::Center
$format.LineAlignment = [System.Drawing.StringAlignment]::Center
$g.DrawString("G", $font, (New-Object System.Drawing.SolidBrush((C "5c420d"))),
    (New-Object System.Drawing.RectangleF(0, 4, 128, 128)), $format)
SaveTga $bmp (Join-Path $OutDir "Icon.tga")
$bmp.Save((Join-Path $PreviewDir "Icon.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

# C: hammer and ingot
$canvas = NewCanvas; $bmp = $canvas[0]; $g = $canvas[1]
$ingotPen = New-Object System.Drawing.Pen((C "7a5a16"), 4)
$ingotPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$front = [System.Drawing.PointF[]]@(
    (New-Object System.Drawing.PointF(10, 112)), (New-Object System.Drawing.PointF(118, 112)),
    (New-Object System.Drawing.PointF(103, 82)), (New-Object System.Drawing.PointF(25, 82)))
$g.FillPolygon((GoldBrush (New-Object System.Drawing.RectangleF(10, 82, 108, 30))), $front)
$g.DrawPolygon($ingotPen, $front)
$top = [System.Drawing.PointF[]]@(
    (New-Object System.Drawing.PointF(25, 82)), (New-Object System.Drawing.PointF(103, 82)),
    (New-Object System.Drawing.PointF(92, 66)), (New-Object System.Drawing.PointF(36, 66)))
$g.FillPolygon((New-Object System.Drawing.SolidBrush((C "f6dd92"))), $top)
$g.DrawPolygon($ingotPen, $top)
# Hammer, tilted over the ingot
$g.TranslateTransform(66, 40)
$g.RotateTransform(-38)
$handle = New-Object System.Drawing.RectangleF(-5, -10, 10, 58)
$g.FillRectangle((New-Object System.Drawing.SolidBrush((C "7a5230"))), $handle)
$g.DrawRectangle((New-Object System.Drawing.Pen((C "3a2614"), 3)), -5, -10, 10, 58)
$head = New-Object System.Drawing.RectangleF(-27, -30, 54, 24)
$g.FillRectangle((SteelBrush $head), $head)
$g.DrawRectangle((New-Object System.Drawing.Pen((C "3a3d45"), 4)), -27, -30, 54, 24)
$g.ResetTransform()
SaveTga $bmp (Join-Path $OutDir "Logo.tga")
$bmp.Save((Join-Path $PreviewDir "Logo.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

"done"
