# Build a Peppermint installer for Windows.
#
# The result is an .exe setup program. Run it to install Peppermint.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -PackageOnly
#
# -PackageOnly skips the compile and packages the build already on disk.
# A release-optimized build (much slower, and it reclobbers the object
# directory) is:
#   $env:ZEN_RELEASE = "1"; .\scripts\build-windows.ps1

param(
    [switch]$PackageOnly
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message"
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user;$env:USERPROFILE\.cargo\bin"
}

function Install-WingetPackage([string]$Id) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is not available. Install App Installer from the Microsoft Store, then run this script again."
    }
    winget install --id $Id -e --accept-package-agreements --accept-source-agreements
    Refresh-Path
}

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-ObjRoots {
    $roots = @()
    $mozconfig = Join-Path $Root "mozconfig"
    if (Test-Path $mozconfig) {
        foreach ($line in Get-Content $mozconfig) {
            if ($line -match '^mk_add_options MOZ_OBJDIR=(.+)$') {
                $roots += $Matches[1].Trim().Trim('"')
            }
        }
    }
    $roots += (Join-Path $Root "engine")
    return $roots
}

# Local release builds have no PGO profile. Any non-empty value skips it.
if ($env:ZEN_RELEASE -and -not $env:ZEN_GA_DISABLE_PGO) {
    $env:ZEN_GA_DISABLE_PGO = "1"
    Write-Step "PGO profile data is not available locally, so this release build skips PGO"
}

if (-not $PackageOnly) {
    Refresh-Path

    Write-Step "Checking Git, Python 3.11, Node 22, and Rust"
    if (-not (Test-Command "git")) {
        Install-WingetPackage "Git.Git"
    }
    if (-not (Test-Command "py")) {
        Install-WingetPackage "Python.Python.3.11"
    }
    $nodeMajor = $null
    if (Test-Command "node") {
        $nodeMajor = (node -p "process.versions.node.split('.')[0]")
    }
    if ($nodeMajor -ne "22") {
        Install-WingetPackage "OpenJS.NodeJS.22"
        $env:Path = "$env:ProgramFiles\nodejs;$env:Path"
    }
    if (-not (Test-Command "rustup")) {
        Install-WingetPackage "Rustlang.Rustup"
    }
    if (-not (Test-Command "7z")) {
        Install-WingetPackage "7zip.7zip"
    }

    $shim = Join-Path $env:TEMP "peppermint-browser-bin"
    New-Item -ItemType Directory -Force -Path $shim | Out-Null
    if (-not (Test-Command "python3")) {
        "@echo off`r`npy -3.11 %*`r`n" | Set-Content -Path (Join-Path $shim "python3.cmd") -Encoding ASCII
        $env:Path = "$shim;$env:Path"
    }

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vsPath = $null
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }
    if (-not $vsPath) {
        Write-Step "Installing Visual Studio 2022 Build Tools"
        winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-package-agreements --accept-source-agreements --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
        $vsPath = & $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (-not $vsPath) {
            throw "Visual Studio C++ tools are still missing. Install the Desktop development with C++ workload, then run this script again."
        }
    }

    if (-not (Test-Path "C:\mozilla-build\start-shell.bat") -and -not $env:MOZILLABUILD) {
        Write-Step "Installing MozillaBuild"
        try {
            Install-WingetPackage "Mozilla.MozillaBuild"
        }
        catch {
            Write-Host "MozillaBuild was not installed automatically."
            Write-Host "Download it from https://ftp.mozilla.org/pub/mozilla/libraries/win32/MozillaBuildSetup-Latest.exe"
            throw
        }
    }

    if (-not (Test-Command "cargo")) {
        $env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
    }
    if (-not (Test-Command "rustup")) {
        throw "rustup is not on PATH. Open a new terminal and run this script again."
    }
    rustup toolchain install stable | Out-Null
    rustup default stable | Out-Null

    $needsCbindgen = $true
    if (Test-Command "cbindgen") {
        $cbindgenVersion = (cbindgen --version).Split(" ")[-1]
        $needsCbindgen = [version]$cbindgenVersion -lt [version]"0.29.4"
    }
    if ($needsCbindgen) {
        Write-Step "Installing cbindgen"
        cargo install cbindgen --version 0.29.4 --locked
    }

    $drive = (Get-Item $Root).PSDrive
    $freeGb = [math]::Floor((Get-PSDrive $drive.Name).Free / 1GB)
    if ($freeGb -lt 40) {
        Write-Host "Warning: only ${freeGb}GB free on $($drive.Name):. A packaged build needs about 40GB."
    }

    Write-Step "Checking Node dependencies"
    if (-not (Test-Path "node_modules\.bin\surfer.cmd") -and -not (Test-Path "node_modules\.bin\surfer")) {
        npm ci
    }

    $mozconfigPath = Join-Path $Root "mozconfig"
    if (-not (Test-Path $mozconfigPath)) {
        Write-Step "Writing a local mozconfig"
        @"
# Created by scripts/build-windows.ps1 for a local build.
ac_add_options --without-wasm-sandboxed-libraries
ac_add_options --disable-debug-symbols
"@ | Set-Content -Path $mozconfigPath -Encoding ASCII
    }

    if (-not (Test-Path "engine\mach")) {
        Write-Step "Downloading the Firefox engine"
        npm run download
    }

    $brandFile = "engine\browser\branding\release\locales\en-US\brand.ftl"
    $needsImport = -not (Test-Path $brandFile)
    if (-not $needsImport) {
        $needsImport = -not (Select-String -Path $brandFile -Pattern "Peppermint" -Quiet)
    }
    if ($needsImport) {
        Write-Step "Importing Peppermint patches"
        npm run import
    }

    python3 -c @'
from pathlib import Path
vendor = Path("engine/browser/moz.configure")
text = vendor.read_text(encoding="utf-8")
old = "imply_option(\"MOZ_APP_VENDOR\", \"Mozilla\")"
new = "imply_option(\"MOZ_APP_VENDOR\", \"MintFlow Technologies\")"
if old in text:
    vendor.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("Set the application vendor to MintFlow Technologies")
'@

    Write-Step "Selecting the Peppermint release brand"
    npm run surfer -- set brand release

    Write-Step "Bootstrapping the Firefox build environment"
    Push-Location engine
    try {
        python3 .\mach --no-interactive bootstrap --application-choice browser
    }
    finally {
        Pop-Location
    }

    Write-Step "Copying English language packs"
    python3 .\scripts\update_en_US_packs.py

    $memGb = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $cpus = [Environment]::ProcessorCount
    $jobs = [math]::Max(2, [math]::Floor($memGb / 4))
    if ($jobs -gt $cpus) { $jobs = $cpus }

    Write-Step "Building Peppermint ($jobs jobs). The first build can take a few hours."
    npm run build -- --jobs $jobs
}

if (-not (Test-Command "python3")) {
    $shim = Join-Path $env:TEMP "peppermint-browser-bin"
    if (Test-Path (Join-Path $shim "python3.cmd")) {
        $env:Path = "$shim;$env:Path"
    }
}

Write-Step "Packaging the installer"
Push-Location (Join-Path $Root "engine")
try {
    python3 .\mach package
    if ($LASTEXITCODE -ne 0) {
        throw "mach package failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

$installer = $null
foreach ($objRoot in (Get-ObjRoots)) {
    if (-not (Test-Path $objRoot)) { continue }
    $distDirs = @()
    $directDist = Join-Path $objRoot "dist"
    if (Test-Path $directDist) { $distDirs += $directDist }
    if (Test-Path $objRoot) {
        $distDirs += Get-ChildItem -Path $objRoot -Directory -Filter "obj-*" -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "dist" } |
            Where-Object { Test-Path $_ }
    }
    foreach ($distDir in $distDirs) {
        $installer = Get-ChildItem -Path $distDir -Filter "*.installer.exe" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch "stub" } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($installer) { break }
    }
    if ($installer) { break }
}

if (-not $installer) {
    throw "Packaging finished, but no installer .exe was found. NSIS is required; run this script again without -PackageOnly so the Firefox bootstrap can install it."
}

$dist = Join-Path $Root "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$output = Join-Path $dist "Peppermint-Setup.exe"
Copy-Item -Path $installer.FullName -Destination $output -Force

Write-Step "Installer ready: $output"
Write-Host "Run Peppermint-Setup.exe to install Peppermint."
