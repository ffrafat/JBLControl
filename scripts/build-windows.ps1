<#
.SYNOPSIS
    Builds the Windows app into ./build/windows. The Windows counterpart of scripts/build-app.sh.

.DESCRIPTION
    Publishes JBLControl self-contained (the .NET and Windows App SDK runtimes ship inside, so nothing
    else needs installing) for each architecture: .NET has no fat binary, so x64 and arm64 are separate
    builds, as plan section 10 describes. Unsigned, like the Mac release zips.

    Usage: scripts/build-windows.ps1 [-Arch x64,arm64] [-Installer] [-Zip] [-Msix] [-Install] [-Run]
      -Installer  build/JBLControl-win-<arch>-<version>-setup.exe per architecture (needs Inno Setup 6:
                  winget install JRSoftware.InnoSetup); the release download
      -Zip        build/JBLControl-win-<arch>-<version>.zip per architecture (portable, no installer)
      -Msix       build/JBLControl-win-<arch>-<version>.msixupload per architecture, for Partner Center
                  (Microsoft Store submission). A separate, packaged (sandboxed) build from -Installer/-Zip:
                  see Package.appxmanifest and windows/PORT_PLAN.md's Store-publishing notes. Partner Center
                  accepts one .msixupload per architecture in a submission; they don't need to be bundled.
      -Install    copy this PC's architecture to %LOCALAPPDATA%\Programs\JBLControl, with a Start menu shortcut
      -Run        restart the app (the installed copy with -Install, otherwise the fresh build)
    -Installer and -Zip also write build/JBLControl-win-<version>.sha256 with every file's SHA-256.
#>
param(
    [ValidateSet('x64', 'arm64')] [string[]] $Arch = @('x64', 'arm64'),
    [switch] $Installer,
    [switch] $Zip,
    [switch] $Msix,
    [switch] $Install,
    [switch] $Run
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$plist = Get-Content -Raw 'Resources/Info.plist'
$version = [regex]::Match($plist, 'CFBundleShortVersionString</key>\s*<string>([^<]+)').Groups[1].Value
$build = [regex]::Match($plist, 'CFBundleVersion</key>\s*<string>([^<]+)').Groups[1].Value

# Inno Setup's compiler: on PATH, or where its installer (or winget) puts it.
$iscc = $null
if ($Installer) {
    $iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
    if (-not $iscc) {
        $iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "$env:ProgramFiles\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $iscc) { throw 'Inno Setup 6 not found. Install it with: winget install JRSoftware.InnoSetup' }
}
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
    # The redistributed runtimes' terms must ship with them (see THIRD_PARTY_NOTICES.md).
    $licenses = 'JBLControl-LICENSE.txt', 'THIRD_PARTY_NOTICES.md', 'WindowsAppSDK-LICENSE.txt', 'CommunityToolkit-LICENSE.md',
        'dotnet-LICENSE.txt', 'dotnet-ThirdPartyNotices.txt'
    $missing = $licenses | Where-Object { -not (Test-Path (Join-Path $dir "licenses/$_")) }
    if ($missing) { throw "License files missing from the $a build: $($missing -join ', ')" }
    Write-Host "Built $dir"
}

$artifacts = @()

if ($Msix) {
    # The Store's Identity Version: the 4th segment is reserved by the Store and must stay 0
    # (see Package.appxmanifest's own comment on this).
    $manifestPath = 'windows/JBLControl.Windows/Package.appxmanifest'
    $manifest = Get-Content -Raw $manifestPath
    # Anchored so it only touches Identity's Version="…" and not Dependencies' MinVersion/MaxVersionTested.
    $manifest = [regex]::Replace($manifest, '(?<![A-Za-z])Version="\d+\.\d+\.\d+\.\d+"', "Version=`"$version.0`"")
    Set-Content -Path $manifestPath -Value $manifest -Encoding UTF8 -NoNewline

    foreach ($a in $Arch) {
        $msbuildPlatform = if ($a -eq 'arm64') { 'ARM64' } else { 'x64' }
        $packagesDir = 'windows/JBLControl.Windows/AppPackages'
        if (Test-Path $packagesDir) { Remove-Item -Recurse -Force $packagesDir }
        # -AppxSymbolPackageEnabled:false sidesteps a WinAppSDK MSIX-tooling bug under dotnet's
        # cross-platform MSBuild (mspdbcmf.exe/System.Security.Permissions missing); the app package
        # itself doesn't need the separate .appxsym debug-symbols package to be valid for submission.
        dotnet publish $project -c Release -r "win-$a" --self-contained true -p:Platform=$msbuildPlatform `
            -p:WindowsPackageType=MSIX -p:AppxPackageSigningEnabled=false -p:AppxSymbolPackageEnabled=false `
            -p:GenerateAppxPackageOnBuild=true -p:UapAppxPackageBuildMode=StoreUpload -nologo
        if ($LASTEXITCODE -ne 0) { throw "MSIX publish failed for $a" }
        $upload = Get-ChildItem (Join-Path $root "$packagesDir/*.msixupload") | Select-Object -First 1
        if (-not $upload) { throw "No .msixupload produced for $a" }
        $dest = Join-Path $root "build/JBLControl-win-$a-$version.msixupload"
        Copy-Item $upload $dest -Force
        $artifacts += $dest
        Write-Host "Built $dest"
    }
}

if ($Installer) {
    foreach ($a in $Arch) {
        $setup = Join-Path $root "build/JBLControl-win-$a-$version-setup.exe"
        & $iscc /Qp "/DAppVersion=$version" "/DBuildNumber=$build" "/DArch=$a" "/DSourceDir=$(Join-Path $out "$a\JBLControl")" `
            "/DOutputDir=$(Join-Path $root 'build')" (Join-Path $root 'windows/Installer/JBLControl.iss')
        if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed for $a" }
        $artifacts += $setup
        Write-Host "Built $setup"
    }
}

if ($Zip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($a in $Arch) {
        $zipPath = Join-Path $root "build/JBLControl-win-$a-$version.zip"
        if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
        [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $out "$a/JBLControl"), $zipPath,
            [IO.Compression.CompressionLevel]::Optimal, $true)
        $artifacts += $zipPath
        Write-Host "Zipped $zipPath"
    }
}

if ($artifacts) {
    # The same format as shasum -a 256, for the release notes.
    $sums = $artifacts | ForEach-Object { "$((Get-FileHash -Algorithm SHA256 $_).Hash.ToLowerInvariant())  $(Split-Path -Leaf $_)" }
    Set-Content -Path (Join-Path $root "build/JBLControl-win-$version.sha256") -Value $sums -Encoding ascii
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
