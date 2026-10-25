<#
.SYNOPSIS
    Builds the Windows app into ./build/windows. The Windows counterpart of scripts/build-app.sh.

.DESCRIPTION
    Publishes JBLControl self-contained (the .NET and Windows App SDK runtimes ship inside, so nothing
    else needs installing) for each architecture: .NET has no fat binary, so x64 and arm64 are separate
    builds, as plan section 10 describes. Unsigned, like the Mac release zips.

    Usage: scripts/build-windows.ps1 [-Arch x64,arm64] [-Zip] [-Install] [-Run]
      -Zip      build/JBLControl-win-<arch>-<version>.zip per architecture, with SHA-256 hashes
      -Install  copy this PC's architecture to %LOCALAPPDATA%\Programs\JBLControl, with a Start menu shortcut
      -Run      restart the app (the installed copy with -Install, otherwise the fresh build)
#>
param(
    [ValidateSet('x64', 'arm64')] [string[]] $Arch = @('x64', 'arm64'),
    [switch] $Zip,
    [switch] $Install,
    [switch] $Run
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$plist = Get-Content -Raw 'Resources/Info.plist'
$version = [regex]::Match($plist, 'CFBundleShortVersionString</key>\s*<string>([^<]+)').Groups[1].Value
$project = 'windows/JBLControl.Windows/JBLControl.Windows.csproj'
$out = Join-Path $root 'build/windows'

# This PC's own build, for -Install and -Run.
$nativeArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
if (($Install -or $Run) -and $Arch -notcontains $nativeArch) { $Arch += $nativeArch }

$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
foreach ($a in $Arch) {
    # The folder is named JBLControl so the zip unpacks to a tidy JBLControl\ folder.
    $dir = Join-Path $out "$a/JBLControl"
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    dotnet publish $project -c Release -r "win-$a" --self-contained true -p:Platform=$a -p:PublishReadyToRun=true -o $dir -nologo
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed for $a" }
    Write-Host "Built $dir"
}

if ($Zip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $sums = @()
    foreach ($a in $Arch) {
        $zipPath = Join-Path $root "build/JBLControl-win-$a-$version.zip"
        if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
        [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $out "$a/JBLControl"), $zipPath,
            [IO.Compression.CompressionLevel]::Optimal, $true)
        $hash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLowerInvariant()
        $sums += "$hash  $(Split-Path -Leaf $zipPath)"
        Write-Host "Zipped $zipPath"
    }
    # The same format as shasum -a 256, for the release notes.
    $sumsPath = Join-Path $root "build/JBLControl-win-$version.sha256"
    Set-Content -Path $sumsPath -Value $sums -Encoding ascii
    $sums | ForEach-Object { Write-Host $_ }
}

$exe = Join-Path $out "$nativeArch/JBLControl/JBLControl.exe"

if ($Install) {
    Get-Process JBLControl -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    $target = Join-Path $env:LOCALAPPDATA 'Programs/JBLControl'
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    Copy-Item -Recurse (Join-Path $out "$nativeArch/JBLControl") $target
    $exe = Join-Path $target 'JBLControl.exe'
    # A Start menu entry, so it shows up in Start and search like any installed app.
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'JBLControl.lnk'))
    $link.TargetPath = $exe
    $link.WorkingDirectory = $target
    $link.Description = 'JBL speaker control'
    $link.Save()
    Write-Host "Installed $target"
}

if ($Run) {
    Get-Process JBLControl -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    Start-Process $exe
}
