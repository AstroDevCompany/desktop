# Run Peppermint on Windows.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-windows.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-windows.ps1 -Rebuild
#
# Logs: .build-logs\ under the repo root.

param(
    [switch]$Rebuild
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. (Join-Path $PSScriptRoot "windows-build-env.ps1")

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message"
}

$null = Start-BuildTranscript $Root "run-windows"
Set-MachBuildEnvironment
Refresh-BuildPath

Write-Step "Checking Git, Python 3.11, Node, and Rust"
if (-not (Test-Command "git")) {
    Install-WingetPackage "Git.Git"
}
if (-not (Test-Command "py")) {
    Install-WingetPackage "Python.Python.3.11"
}
if (Test-Command "node") {
    $nodeMajor = node -p "process.versions.node.split('.')[0]"
    if ($nodeMajor -ne "22") {
        Write-Host "Note: Node $nodeMajor detected; package.json targets Node 22. Continuing."
    }
}
else {
    Install-WingetPackage "OpenJS.NodeJS.22"
    $env:Path = "$env:ProgramFiles\nodejs;$env:Path"
}
if (-not (Test-Command "rustup")) {
    Install-WingetPackage "Rustlang.Rustup"
}
if (-not (Test-Command "7z")) {
    if (Test-Path "$env:LOCALAPPDATA\7-Zip\7z.exe") {
        $env:Path = "$env:LOCALAPPDATA\7-Zip;$env:Path"
    }
    else {
        Install-WingetPackage "7zip.7zip"
    }
}

Ensure-Python3

$vsPath = Get-VisualStudioBuildToolsPath
if (-not $vsPath) {
    Write-Step "Installing Visual Studio 2022 C++ Build Tools"
    $setup = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe"
    if (Test-Path $setup) {
        & $setup modify `
            --installPath "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools" `
            --add Microsoft.VisualStudio.Workload.VCTools `
            --includeRecommended `
            --passive --wait --norestart
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
            throw "Visual Studio installer exited with code $LASTEXITCODE"
        }
    }
    else {
        winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-package-agreements --accept-source-agreements --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    }
    $vsPath = Get-VisualStudioBuildToolsPath
    if (-not $vsPath) {
        throw "Visual Studio C++ tools are still missing. Install the Desktop development with C++ workload, then run this script again."
    }
}

if (-not (Test-Path "C:\mozilla-build\start-shell.bat") -and -not $env:MOZILLABUILD) {
    Write-Step "Installing MozillaBuild"
    $mozBuildSetup = "$env:TEMP\MozillaBuildSetup-Latest.exe"
    if (-not (Test-Path $mozBuildSetup)) {
        Invoke-WebRequest -Uri "https://ftp.mozilla.org/pub/mozilla/libraries/win32/MozillaBuildSetup-Latest.exe" -OutFile $mozBuildSetup
    }
    Start-Process -FilePath $mozBuildSetup -ArgumentList "/S" -Wait
    if (-not (Test-Path "C:\mozilla-build\start-shell.bat")) {
        throw "MozillaBuild did not install to C:\mozilla-build"
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
    if ($LASTEXITCODE -ne 0) {
        throw "cbindgen install failed"
    }
}

Assert-WindowsBuildPreflight $Root

Write-Step "Checking Node dependencies"
if (-not (Test-Path "node_modules\.bin\surfer.cmd") -and -not (Test-Path "node_modules\.bin\surfer")) {
    npm ci
    if ($LASTEXITCODE -ne 0) { throw "npm ci failed" }
}

function Repair-EnginePatches {
    node (Join-Path $Root "scripts\apply-engine-patches.mjs")
    if ($LASTEXITCODE -ne 0) {
        throw "apply-engine-patches failed"
    }
    node (Join-Path $Root "scripts\ensure-jar-manifest-patches.mjs")
    return $LASTEXITCODE -eq 2
}

function Find-Browser {
    $roots = @((Join-Path $Root "engine"))
    $mozconfig = Join-Path $Root "mozconfig"
    if (Test-Path $mozconfig) {
        foreach ($line in Get-Content $mozconfig) {
            if ($line -match '^mk_add_options MOZ_OBJDIR=(.+)$') {
                $roots += $Matches[1].Trim('"')
            }
        }
    }
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem -Path (Join-Path $root "obj-*\dist\bin\zen.exe") -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $found) {
            $direct = Join-Path $root "dist\bin\zen.exe"
            if (Test-Path $direct) { return $direct }
        }
        if ($found) { return $found.FullName }
    }
    return $null
}

$existing = Find-Browser
if (-not $Rebuild -and $existing) {
    if (Repair-EnginePatches) {
        $jobs = Get-MachBuildJobs
        Write-Step "Rebuilding Peppermint after chrome packaging fix ($jobs jobs)"
        Invoke-MachBuild $Root $jobs
    }
    Write-Step "Launching $existing"
    npm start
    if ($LASTEXITCODE -ne 0) { throw "npm start failed" }
    exit 0
}

$mozconfigPath = Join-Path $Root "mozconfig"
if (-not (Test-Path $mozconfigPath)) {
    Write-Step "Writing a local mozconfig"
    @"
# Created by scripts/run-windows.ps1 for a local development build.
ac_add_options --without-wasm-sandboxed-libraries
ac_add_options --disable-debug-symbols
"@ | Set-Content -Path $mozconfigPath -Encoding ASCII
}

if (-not (Test-Path "engine\mach")) {
    Invoke-Checked "Downloading the Firefox engine" { npm run download }
}

$brandFile = "engine\browser\branding\release\locales\en-US\brand.ftl"
$needsImport = -not (Test-Path $brandFile)
if (-not $needsImport) {
    $needsImport = -not (Select-String -Path $brandFile -Pattern "Peppermint" -Quiet)
}
if ($needsImport) {
    Invoke-Checked "Importing Peppermint patches" { npm run import }
}
else {
    Repair-EnginePatches | Out-Null
}

node (Join-Path $Root "scripts\run-python.mjs") -c @'
from pathlib import Path
vendor = Path("engine/browser/moz.configure")
text = vendor.read_text(encoding="utf-8")
old = "imply_option(\"MOZ_APP_VENDOR\", \"Mozilla\")"
new = "imply_option(\"MOZ_APP_VENDOR\", \"MintFlow Technologies\")"
if old in text:
    vendor.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("Set the application vendor to MintFlow Technologies")
'@
if ($LASTEXITCODE -ne 0) { throw "vendor moz.configure update failed" }

Invoke-Checked "Selecting the Peppermint release brand" { npm run surfer -- set brand release }

if (-not (Test-MachBootstrapReady)) {
    Write-Step "Bootstrapping the Firefox build environment (first time can take 30-60 minutes)"
    Invoke-MachBootstrap (Join-Path $Root "engine")
}
else {
    Write-Step "Firefox build environment already bootstrapped"
}

Write-Step "Copying English language packs"
node .\scripts\run-python.mjs .\scripts\update_en_US_packs.py
if ($LASTEXITCODE -ne 0) { throw "update_en_US_packs.py failed" }

if (Repair-EnginePatches) {
    Write-Step "Repaired engine patches / chrome manifests before build"
}

$jobs = Get-MachBuildJobs
Write-Step "Building Peppermint ($jobs parallel jobs). A full first build usually takes 2-4 hours on this machine."
Invoke-MachBuild $Root $jobs

Write-Step "Launching Peppermint"
npm start
if ($LASTEXITCODE -ne 0) { throw "npm start failed" }
exit 0
