<#
.SYNOPSIS
    Generates Microsoft Store listing screenshots (branded banners around the real app UI) into
    windows/JBLControl.Windows/Assets/Store/Screenshots/.

.DESCRIPTION
    Three 1920x1080 banners, each a real screenshot from site/images/ composited onto the sunset-gradient
    "stage" treatment from the website's hero section, with a headline/subhead band on top. Not raw
    screenshots: Partner Center recommends several per device family, and plain window captures alone
    read as thin next to competitors' marketing shots.

    Rasterizes with headless Microsoft Edge, so it needs nothing beyond Windows itself (same approach as
    scripts/make-windows-icons.ps1, which this duplicates a small render helper from).
    Re-run after changing site/images/windows-*.png:  powershell -File scripts/make-store-screenshots.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$images = Join-Path $root 'site/images'
$assets = Join-Path $root 'Resources/AppIcon.icon/Assets'
$outDir = Join-Path $root 'windows/JBLControl.Windows/Assets/Store/Screenshots'
New-Item -ItemType Directory -Force $outDir | Out-Null

function Inner([string]$svgFile) {
    $text = Get-Content -Raw $svgFile
    return [regex]::Match($text, '<svg[^>]*>(.*)</svg>', 'Singleline').Groups[1].Value
}
$body = Inner (Join-Path $assets 'body.svg')
$controls = Inner (Join-Path $assets 'controls.svg')
# Small inline rendering of the app icon artwork for the banner's brand mark (no raster asset needed).
$brandMark = @"
<svg viewBox="0 0 1024 1024" width="34" height="34" style="display:block">
  <defs><clipPath id="sq"><rect x="40" y="40" width="944" height="944" rx="210"/></clipPath></defs>
  <g clip-path="url(#sq)">
    <rect width="1024" height="1024" fill="#00000048"/>
    $body
    $controls
  </g>
</svg>
"@

$work = Join-Path ([IO.Path]::GetTempPath()) "jblcontrol-shots-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$userData = Join-Path $work 'profile'
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge not found.' }

function Render([string]$html, [int]$w, [int]$h, [string]$png) {
    $page = Join-Path $work ([IO.Path]::GetFileNameWithoutExtension($png) + '.html')
    Set-Content -Path $page -Value $html -Encoding UTF8
    $shot = "$png.full.png"
    $uri = ([Uri]$page).AbsoluteUri
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

function Uri([string]$path) { ([Uri]$path).AbsoluteUri }

# The shared stage: sunset gradient, grille-dot texture, a small wordmark, a caption band, the screenshot
# below it. $imageHtml is whatever markup places (and optionally crops) the screenshot.
function Banner([string]$headline, [string]$subhead, [string]$imageHtml) {
    @"
<!doctype html><html><head><style>
  html, body { margin:0; padding:0; overflow:hidden; }
  body {
    width:1920px; height:1080px; position:relative; font-family:'Segoe UI Variable Display','Segoe UI',sans-serif;
    background: radial-gradient(130% 110% at 14% -10%, #FF9429, #E62E33 68%);
  }
  .dots { position:absolute; inset:0; opacity:.16;
    background-image: radial-gradient(rgba(0,0,0,.6) 2px, transparent 2.4px); background-size:16px 16px; }
  .brand { position:absolute; left:64px; top:48px; display:flex; align-items:center; gap:12px; color:#fff; font-weight:800; font-size:26px; }
  .caption { position:absolute; left:64px; top:118px; right:64px; color:#fff; }
  .caption h1 { margin:0; font-size:54px; font-weight:800; letter-spacing:-.01em; text-shadow:0 2px 10px rgba(0,0,0,.18); max-width:1500px; }
  .caption p { margin:14px 0 0; font-size:25px; font-weight:500; opacity:.92; max-width:1300px; }
  .stage { position:absolute; left:0; right:0; top:300px; bottom:0; display:flex; align-items:center; justify-content:center; }
</style></head><body>
  <div class="dots"></div>
  <div class="brand">$brandMark JBLControl</div>
  <div class="caption"><h1>$headline</h1><p>$subhead</p></div>
  <div class="stage">$imageHtml</div>
</body></html>
"@
}

# Render() writes a same-named "<png>.full.png" sibling before cropping, so every call targets a path
# inside $work (never $outDir directly) and is copied out afterward — otherwise that intermediate file
# is left behind next to the real output.
function RenderToOutput([string]$html, [string]$name) {
    $tmp = Join-Path $work $name
    Render $html 1920 1080 $tmp
    Copy-Item $tmp (Join-Path $outDir $name) -Force
}

# 1. Hero / overview — the main window, full.
$appShot = Uri (Join-Path $images 'windows-app.png')
$html1 = Banner 'JBL speaker control, right in your window and tray.' `
    'Battery, JBL&rsquo;s EQ presets and a 7-band custom equalizer &mdash; no phone, no account.' `
    "<img src=`"$appShot`" style=`"height:700px;filter:drop-shadow(0 30px 50px rgba(40,10,0,.45));border-radius:14px`">"
RenderToOutput $html1 'Screenshot-1-Overview.png'

# 2. Tray panel — convenience.
$trayShot = Uri (Join-Path $images 'windows-tray.png')
$html2 = Banner 'Always one click away.' `
    'A compact panel in your system tray, with everything the main window has.' `
    "<img src=`"$trayShot`" style=`"height:700px;filter:drop-shadow(0 30px 50px rgba(40,10,0,.45));border-radius:14px`">"
RenderToOutput $html2 'Screenshot-2-Tray.png'

# 3. Equalizer, zoomed — crop the presets+equalizer region out of the main window shot
#    (source image is 1558x1037; the region sits roughly at x:480-1220, y:370-860).
$html3 = Banner 'A real 7-band equalizer, not a toy.' `
    '125 Hz to 8 kHz, with a live response curve as you drag.' `
    @"
<div style="width:740px;height:490px;overflow:hidden;border-radius:18px;box-shadow:0 30px 50px rgba(40,10,0,.45);transform:scale(1.5)">
  <img src="$appShot" width="1558" height="1037" style="margin-left:-480px;margin-top:-370px;display:block">
</div>
"@
RenderToOutput $html3 'Screenshot-3-Equalizer.png'

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host "wrote $outDir\Screenshot-*.png"
