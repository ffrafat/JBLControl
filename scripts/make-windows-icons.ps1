<#
.SYNOPSIS
    Generates the Windows app's icons from the Mac icon artwork (Resources/AppIcon.icon).

.DESCRIPTION
    - windows/JBLControl.Windows/Assets/AppIcon.ico: the Mac app icon (graphite boombox with EQ sliders
      on the sunset gradient) as a Windows icon, 16-256 px.
    - windows/JBLControl.Windows/TrayIcons.Generated.cs: the same icon as raw pixels at each
      notification-area size, which TrayIcon draws its Keep Awake dot over at runtime.
    - windows/Installer/Wizard*.bmp: the installer's branded banner and header images.
    - windows/JBLControl.Windows/Assets/Store/*.png: the Microsoft Store listing's required logo sizes.

    Rasterizes the SVGs with headless Microsoft Edge, so it needs nothing beyond Windows itself.
    Re-run after changing the Mac icon (scripts/make-icon.py):  powershell -File scripts/make-windows-icons.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $root 'Resources/AppIcon.icon/Assets'
$appDir = Join-Path $root 'windows/JBLControl.Windows'
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge not found.' }

$work = Join-Path ([IO.Path]::GetTempPath()) "jblcontrol-icons-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$userData = Join-Path $work 'profile'

function Inner([string]$svgFile) {
    $text = Get-Content -Raw $svgFile
    return [regex]::Match($text, '<svg[^>]*>(.*)</svg>', 'Singleline').Groups[1].Value
}

# Renders the page in a roomy viewport (headless windows have a minimum size) and crops the top-left w x h.
function Render([string]$html, [int]$w, [int]$h, [string]$png) {
    $page = Join-Path $work ([IO.Path]::GetFileNameWithoutExtension($png) + '.html')
    Set-Content -Path $page -Value $html -Encoding UTF8
    $shot = "$png.full.png"
    $uri = ([Uri]$page).AbsoluteUri
    # At least 800x800 (headless windows have a minimum size), but big enough for larger renders
    # (e.g. 2160x2160 Store box art) to fit without cropping into empty space.
    $winW = [Math]::Max($w, 800); $winH = [Math]::Max($h, 800)
    $edgeArgs = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
        '--default-background-color=00000000', "`"--user-data-dir=$userData`"", "--window-size=$winW,$winH", "`"--screenshot=$shot`"", $uri)
    $p = Start-Process -FilePath $edge -ArgumentList $edgeArgs -Wait -PassThru -WindowStyle Hidden
    if (-not (Test-Path $shot)) { throw "Edge didn't render $png (exit $($p.ExitCode))" }
    $full = [Drawing.Bitmap]::FromFile($shot)
    $crop = $full.Clone((New-Object Drawing.Rectangle 0, 0, $w, $h), [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $crop.Save($png, [Drawing.Imaging.ImageFormat]::Png)
    $crop.Dispose(); $full.Dispose()
}

$page = '<!doctype html><html><head><style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}svg{display:block}</style></head><body>{0}</body></html>'
$body = Inner (Join-Path $assets 'body.svg')
$controls = Inner (Join-Path $assets 'controls.svg')

# --- App icon ---------------------------------------------------------------------------------------
# The Mac icon's layers on its gradient, in a Windows 11-style rounded square (macOS masks its own squircle).
# Glass is approximated with a top highlight on the speaker; the shadows follow icon.json's opacities.
$iconSvg = @"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="{0}" height="{0}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FF9429"/><stop offset="1" stop-color="#E62E33"/></linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/><stop offset="0.55" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>
    <filter id="s1" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#000" flood-opacity="0.5"/></filter>
    <filter id="s2" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#000" flood-opacity="0.4"/></filter>
    <clipPath id="sq"><rect x="40" y="40" width="944" height="944" rx="210"/></clipPath>
  </defs>
  <g clip-path="url(#sq)">
    <rect width="1024" height="1024" fill="url(#bg)"/>
    <g filter="url(#s1)">$body</g>
    <g style="mix-blend-mode:screen">$($body -replace '#4A4A50', 'url(#sheen)')</g>
    <g filter="url(#s2)">$controls</g>
  </g>
</svg>
"@
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$pngs = @()
foreach ($s in $sizes) {
    $png = Join-Path $work "icon-$s.png"
    Render ($page -replace '\{0\}', ($iconSvg -replace '\{0\}', $s)) $s $s $png
    $pngs += , @($s, [IO.File]::ReadAllBytes($png))
}

# ICO with PNG-compressed entries (supported since Windows Vista).
New-Item -ItemType Directory -Force (Join-Path $appDir 'Assets') | Out-Null
$ico = Join-Path $appDir 'Assets/AppIcon.ico'
$ms = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter $ms
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$pngs.Count)
$offset = 6 + 16 * $pngs.Count
foreach ($entry in $pngs) {
    $s = $entry[0]; $data = $entry[1]
    $dim = if ($s -ge 256) { 0 } else { $s }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$data.Length); $bw.Write([uint32]$offset)
    $offset += $data.Length
}
foreach ($entry in $pngs) { $bw.Write($entry[1]) }
[IO.File]::WriteAllBytes($ico, $ms.ToArray())
Copy-Item (Join-Path $work 'icon-256.png') (Join-Path $appDir 'Assets/AppIcon.png') -Force
Write-Host "wrote $ico"

# --- Store logos -------------------------------------------------------------------------------------
# Package.appxmanifest's required sizes: the app-list/taskbar tile, the Start tile, and the Store listing logo.
$storeDir = Join-Path $appDir 'Assets/Store'
New-Item -ItemType Directory -Force $storeDir | Out-Null
foreach ($logo in @(@{ n = 'Square44x44Logo'; s = 44 }, @{ n = 'Square150x150Logo'; s = 150 }, @{ n = 'StoreLogo'; s = 50 })) {
    $png = Join-Path $work "store-$($logo.s).png"
    Render ($page -replace '\{0\}', ($iconSvg -replace '\{0\}', $logo.s)) $logo.s $logo.s $png
    Copy-Item $png (Join-Path $storeDir "$($logo.n).png") -Force
}

# Partner Center's optional listing art: 1:1 Box art is just the app icon at full size; 9:16 Poster art
# is a taller branded composition (same treatment as the installer banner below) for the Store's main
# tile on Windows 10/11. Both rendered at their 2x size for a sharp Store listing.
$boxPng = Join-Path $work 'box-2160.png'
Render ($page -replace '\{0\}', ($iconSvg -replace '\{0\}', 2160)) 2160 2160 $boxPng
Copy-Item $boxPng (Join-Path $storeDir 'BoxArt.png') -Force

$posterSvg = @"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 720 1080" width="1440" height="2160">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FF9429"/><stop offset="1" stop-color="#E62E33"/></linearGradient>
    <radialGradient id="glow" cx="25%" cy="12%" r="65%"><stop offset="0" stop-color="#fff" stop-opacity="0.28"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/><stop offset="0.55" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>
    <filter id="s1" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#000" flood-opacity="0.5"/></filter>
    <filter id="s2" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#000" flood-opacity="0.4"/></filter>
  </defs>
  <rect width="720" height="1080" fill="url(#bg)"/>
  <rect width="720" height="1080" fill="url(#glow)"/>
  <g transform="translate(100, 150) scale(0.508)">
    <g filter="url(#s1)">$body</g>
    <g style="mix-blend-mode:screen">$($body -replace '#4A4A50', 'url(#sheen)')</g>
    <g filter="url(#s2)">$controls</g>
  </g>
  <text x="360" y="840" text-anchor="middle" font-family="'Segoe UI Variable Display','Segoe UI',sans-serif"
        font-size="58" font-weight="700" fill="#fff" style="letter-spacing:.2px">JBLControl</text>
</svg>
"@
$posterPng = Join-Path $work 'poster-1440.png'
Render ($page -replace '\{0\}', $posterSvg) 1440 2160 $posterPng
Copy-Item $posterPng (Join-Path $storeDir 'PosterArt.png') -Force
Write-Host "wrote $storeDir\*.png"

# --- Tray icon -------------------------------------------------------------------------------------
# The full app icon as straight-alpha RGBA at every notification-area size, so TrayIcon can composite
# the battery bar and Keep Awake badge over it at runtime without an image decoder.
$lines = @()
foreach ($s in 16, 20, 24, 28, 32, 36, 40, 48, 64) {
    $png = Join-Path $work "tray-$s.png"
    Render ($page -replace '\{0\}', ($iconSvg -replace '\{0\}', $s)) $s $s $png
    $bmp = [Drawing.Bitmap]::FromFile($png)
    $rgba = New-Object byte[] ($s * $s * 4)
    for ($y = 0; $y -lt $s; $y++) {
        for ($x = 0; $x -lt $s; $x++) {
            $c = $bmp.GetPixel($x, $y); $i = ($y * $s + $x) * 4
            $rgba[$i] = $c.R; $rgba[$i + 1] = $c.G; $rgba[$i + 2] = $c.B; $rgba[$i + 3] = $c.A
        }
    }
    $bmp.Dispose()
    $lines += "        [$s] = `"$([Convert]::ToBase64String($rgba))`","
}
$cs = @"
// <auto-generated>
// Generated by scripts/make-windows-icons.ps1 from Resources/AppIcon.icon. Do not edit.
// </auto-generated>
namespace JBLControl.Windows;

/// <summary>The app icon as straight-alpha RGBA pixels, keyed by (square) size.</summary>
internal static class TrayIcons
{
    public static readonly Dictionary<int, string> Rgba = new()
    {
$($lines -join "`r`n")
    };
}
"@
Remove-Item (Join-Path $appDir 'TrayShapes.Generated.cs') -ErrorAction SilentlyContinue
Set-Content -Path (Join-Path $appDir 'TrayIcons.Generated.cs') -Value $cs -Encoding UTF8
Write-Host "wrote $(Join-Path $appDir 'TrayIcons.Generated.cs')"

# --- Installer artwork ------------------------------------------------------------------------------
# Inno Setup's wizard images (24-bit BMP, which every Inno version reads), at 100/150/200% so they stay sharp:
# the tall banner on the Welcome and Finished pages, and the small image in the corner of the other pages.
$installerDir = Join-Path $root 'windows/Installer'
New-Item -ItemType Directory -Force $installerDir | Out-Null

function Save-Bmp([string]$png, [string]$bmp) {
    $src = [Drawing.Bitmap]::FromFile($png)
    $flat = New-Object Drawing.Bitmap $src.Width, $src.Height, ([Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [Drawing.Graphics]::FromImage($flat)
    $g.Clear([Drawing.Color]::White) # the wizard pages are white behind the small image
    $g.DrawImage($src, 0, 0, $src.Width, $src.Height)
    $g.Dispose(); $src.Dispose()
    $flat.Save($bmp, [Drawing.Imaging.ImageFormat]::Bmp)
    $flat.Dispose()
}

$banner = @"
<div style="width:{W}px;height:{H}px;position:relative;overflow:hidden;font-family:'Segoe UI Variable Display','Segoe UI',sans-serif;
  background:linear-gradient(180deg,#FF9429 0%,#E62E33 100%)">
  <div style="position:absolute;left:-30%;top:-20%;width:160%;height:70%;background:radial-gradient(closest-side,rgba(255,255,255,.28),rgba(255,255,255,0))"></div>
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="20 250 984 560" style="position:absolute;left:8%;top:22%;width:84%">
    <defs><filter id="s" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#000" flood-opacity="0.45"/></filter></defs>
    <g filter="url(#s)">$body</g><g>$controls</g>
  </svg>
  <div style="position:absolute;left:0;right:0;top:58%;text-align:center;color:#fff">
    <div style="font-size:{T}px;font-weight:700;letter-spacing:.2px;text-shadow:0 2px 8px rgba(0,0,0,.18)">JBLControl</div>
    <div style="font-size:{S}px;opacity:.9;margin-top:{G}px;padding:0 10%;line-height:1.3">JBL speaker control<br>for Windows</div>
  </div>
</div>
"@
foreach ($scale in @(@{ n = 100; w = 164; h = 314 }, @{ n = 150; w = 246; h = 471 }, @{ n = 200; w = 328; h = 628 })) {
    $k = $scale.w / 164
    $html = $banner -replace '\{W\}', $scale.w -replace '\{H\}', $scale.h -replace '\{T\}', [int](21 * $k) -replace '\{S\}', [int](11 * $k) -replace '\{G\}', [int](4 * $k)
    $png = Join-Path $work "banner-$($scale.n).png"
    Render ($page -replace '\{0\}', $html) $scale.w $scale.h $png
    Save-Bmp $png (Join-Path $installerDir "WizardImage-$($scale.n).bmp")
}
foreach ($scale in @(@{ n = 100; s = 55 }, @{ n = 150; s = 83 }, @{ n = 200; s = 110 })) {
    $png = Join-Path $work "small-$($scale.n).png"
    Render ($page -replace '\{0\}', ($iconSvg -replace '\{0\}', $scale.s)) $scale.s $scale.s $png
    Save-Bmp $png (Join-Path $installerDir "WizardSmallImage-$($scale.n).bmp")
}
Write-Host "wrote $installerDir\Wizard*.bmp"

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
