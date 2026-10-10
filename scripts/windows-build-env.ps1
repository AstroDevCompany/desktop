# Shared helpers for scripts/run-windows.ps1 and scripts/build-windows.ps1

function Refresh-BuildPath {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $extra = @(
        "$env:USERPROFILE\.cargo\bin"
        "$env:LOCALAPPDATA\7-Zip"
        "$env:TEMP\peppermint-browser-bin"
    )
    $env:Path = ($extra + @($machine, $user) | Where-Object { $_ }) -join ";"
}

function Install-WingetPackage([string]$Id) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is not available. Install App Installer from the Microsoft Store, then run this script again."
    }
    winget install --id $Id -e --accept-package-agreements --accept-source-agreements
    Refresh-BuildPath
}

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Ensure-Python3 {
    $shim = Join-Path $env:TEMP "peppermint-browser-bin"
    New-Item -ItemType Directory -Force -Path $shim | Out-Null
    if (-not (Test-Command "py")) {
        Install-WingetPackage "Python.Python.3.11"
    }
    $py311 = & py -3.11 -c "import sys; print(sys.executable)" 2>$null
    if (-not $py311) {
        Install-WingetPackage "Python.Python.3.11"
        Refresh-BuildPath
        $py311 = & py -3.11 -c "import sys; print(sys.executable)" 2>$null
    }
    if (-not $py311) {
        throw "Python 3.11 is required. Run: winget install Python.Python.3.11"
    }
    $pyRoot = Split-Path -Parent $py311.Trim()
    "@echo off`r`npy -3.11 %*`r`n" | Set-Content -Path (Join-Path $shim "python3.cmd") -Encoding ASCII
    $env:Path = "$shim;$pyRoot;$pyRoot\Scripts;$env:Path"
    & python3 -c "import sys; assert sys.version_info[:2] == (3, 11)" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "python3 is not Python 3.11 after setup. Disable the Microsoft Store python3 app execution alias in Windows Settings."
    }
}

function Set-MachBuildEnvironment {
    $env:MACH_HIDE_DEV_DRIVE_SUGGESTION = "1"
    $env:PYTHONUNBUFFERED = "1"
}

function Get-MachBuildJobs {
    $memGb = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $cpus = [Environment]::ProcessorCount
    # Firefox builds need several GiB per job; linker peaks are worse than compile averages.
    $jobs = [math]::Floor(($memGb - 4) / 4)
    if ($memGb -le 18) {
        $jobs = [math]::Min($jobs, 2)
    }
    $jobs = [math]::Max(1, $jobs)
    return [math]::Min($jobs, $cpus)
}

function Invoke-Checked {
    param(
        [string]$Label,
        [scriptblock]$Command
    )
    Write-Host ""
    Write-Host "==> $Label"
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

function Get-VisualStudioBuildToolsPath {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        return $null
    }
    return & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}

function Test-MachBootstrapReady {
    $clang = Join-Path $env:USERPROFILE ".mozbuild\clang\bin\clang.exe"
    if (-not (Test-Path $clang)) {
        return $false
    }
    $midl = Get-ChildItem -Path (Join-Path $env:USERPROFILE ".mozbuild\vs\Windows Kits\10\bin") -Filter midl.exe -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    return [bool]$midl
}

function Invoke-MachBootstrap([string]$EngineDir) {
    Push-Location $EngineDir
    try {
        $logDir = Join-Path (Split-Path -Parent $EngineDir) ".build-logs"
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        $log = Join-Path $logDir "mach-bootstrap-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
        Write-Host "Bootstrap log: $log"
        python3 .\mach --no-interactive bootstrap --application-choice browser 2>&1 | Tee-Object -FilePath $log
        if ($LASTEXITCODE -ne 0) {
            throw "mach bootstrap failed with exit code $LASTEXITCODE (see $log)"
        }
        $text = Get-Content $log -Raw -ErrorAction SilentlyContinue
        if ($text -notmatch "ready to build Firefox") {
            throw "mach bootstrap did not report a ready toolchain (see $log)"
        }
        if (-not (Test-MachBootstrapReady)) {
            throw "mach bootstrap finished but clang or the Windows SDK is missing under $env:USERPROFILE\.mozbuild"
        }
    }
    finally {
        Pop-Location
    }
}

function Get-RunningMachBuild {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'mach(\.py)?\s+build' })
}

function Get-MachBuildActivity {
    $clang = Get-CimInstance Win32_Process -Filter "Name = 'clang.exe' OR Name = 'clang-cl.exe' OR Name = 'lld-link.exe'" -ErrorAction SilentlyContinue |
        Sort-Object CreationDate -Descending |
        Select-Object -First 1
    if (-not $clang) {
        return "waiting (configure or linking setup)"
    }
    $cmd = $clang.CommandLine
    if ($cmd -match 'target-objects|Unified_[A-Za-z0-9_.]+|-Fo([A-Za-z0-9_.]+)\.obj') {
        if ($Matches[1]) { return "compiling $($Matches[1]).obj" }
    }
    if ($cmd -match '([A-Za-z0-9_./\\-]+\.(cpp|c|cc|mm))\b') {
        return "compiling $($Matches[1])"
    }
    if ($clang.Name -eq "lld-link.exe") {
        return "linking"
    }
    return "compiling ($($clang.ProcessId))"
}

function Invoke-MachBuild {
    param(
        [string]$Root,
        [int]$Jobs
    )
    $already = Get-RunningMachBuild
    if ($already.Count -gt 0) {
        $pidList = ($already | ForEach-Object { $_.ProcessId }) -join ", "
        throw "mach build is already running (pid $pidList). A second build will stall both. Let the running one finish."
    }

    $logDir = Join-Path $Root ".build-logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $log = Join-Path $logDir "mach-build-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    $status = Join-Path $logDir "build-status.txt"
    $engine = Join-Path $Root "engine"
    Write-Host "Build log: $log"
    Write-Host "Live status: $status"
    Write-Host "A full optimized build on this machine takes about 3 hours. Progress is printed every 30 seconds."

    $env:PYTHONUNBUFFERED = "1"
    $env:PYTHONIOENCODING = "utf-8"
    # cmd redirection avoids a PowerShell pipeline, which buffers output and can stall mach when the window is closed.
    $proc = Start-Process -FilePath "cmd.exe" `
        -ArgumentList @("/c", "python -u .\mach build --jobs $Jobs > `"$log`" 2>&1") `
        -WorkingDirectory $engine `
        -WindowStyle Hidden `
        -PassThru

    try {
        while (-not $proc.HasExited) {
            $activity = Get-MachBuildActivity
            $line = "$(Get-Date -Format 'HH:mm:ss') pid=$($proc.Id) $activity"
            Set-Content -Path $status -Value $line -Encoding ASCII
            Write-Host $line
            Start-Sleep -Seconds 30
        }
        $proc.Refresh()
        if ($proc.ExitCode -ne 0) {
            throw "mach build failed with exit code $($proc.ExitCode) (see $log)"
        }
    }
    finally {
        if (-not $proc.HasExited) {
            Write-Host "Build still running as pid $($proc.Id). Closing this script does not stop it."
        }
    }
}

function Assert-WindowsBuildPreflight([string]$Root) {
    $drive = (Get-Item $Root).PSDrive
    $freeGb = [math]::Floor((Get-PSDrive $drive.Name).Free / 1GB)
    if ($freeGb -lt 35) {
        throw "Only ${freeGb}GB free on $($drive.Name):. Need at least 35GB for a first Firefox build."
    }
    $engineMach = Join-Path $Root "engine\mach"
    if (-not (Test-Path $engineMach)) {
        throw "engine\mach is missing. Run: npm run download"
    }
    $firefoxJs = Join-Path $Root "engine\browser\app\profile\firefox.js"
    if (-not (Test-Path $firefoxJs)) {
        throw "Incomplete engine tree (firefox.js missing). Re-run: npm run download"
    }
}

function Start-BuildTranscript([string]$Root, [string]$Name) {
    $logDir = Join-Path $Root ".build-logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $path = Join-Path $logDir "$Name-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Start-Transcript -Path $path -Force | Out-Null
    Write-Host "Session log: $path"
    return $path
}
