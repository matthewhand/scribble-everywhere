#!/usr/bin/env pwsh
# Builds the Windows shell of ScribbleEverywhere and copies PalimpsestWin.exe to
# %LOCALAPPDATA%\PalimpsestInk\.
#
# Needs Swift 6.x for Windows and Visual Studio 2022 Build Tools with the
# "Desktop development with C++" workload. The script locates both: it puts
# the Swift toolchain and runtime on PATH, sets SDKROOT, and imports vcvars64
# so lld-link can see the Windows SDK libraries. Swift PM writes the exe under
# .build\out\Products when it cannot create the .build\release symlink.
# The Swift runtime DLLs are copied next to the exe. PenService starts that
# exe by full path and does not inherit a PATH that contains the Swift runtime.

param(
    [switch]$RunTests,
    [switch]$NoInstall,
    [switch]$Portable
)

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

function Add-PathEntry([string]$entry) {
    if ([string]::IsNullOrWhiteSpace($entry)) { return }
    $trimmed = $entry.TrimEnd('\')
    $parts = @($env:Path -split ';' | ForEach-Object { $_.TrimEnd('\') })
    if ($parts -contains $trimmed) { return }
    if ([string]::IsNullOrWhiteSpace($env:Path)) {
        $env:Path = $entry
    } else {
        $env:Path = "$entry;$env:Path"
    }
}

$swiftCmd = Get-Command swift -ErrorAction SilentlyContinue
if (-not $swiftCmd) {
    $swiftExe = Get-ChildItem -Path "$env:LOCALAPPDATA\Programs\Swift\Toolchains" -Filter swift.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\usr\\bin\\swift\.exe$' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if (-not $swiftExe) { throw "swift.exe not found. Install Swift 6.x for Windows from swift.org." }
    Add-PathEntry (Split-Path $swiftExe.FullName)
    $swiftCmd = Get-Command swift
}

$swiftExePath = $swiftCmd.Source
if ($swiftExePath -match '\\Toolchains\\([^\\+]+)') {
    $swiftVersion = $Matches[1]
    $runtimeBin = Join-Path $env:LOCALAPPDATA "Programs\Swift\Runtimes\$swiftVersion\usr\bin"
    if (Test-Path $runtimeBin) {
        Add-PathEntry $runtimeBin
        $script:swiftRuntimeBin = $runtimeBin
    }
    $manifestApi = Join-Path (Split-Path (Split-Path $swiftExePath)) "lib\swift\pm\ManifestAPI"
    if (Test-Path $manifestApi) { Add-PathEntry $manifestApi }
    if (-not $env:SDKROOT) {
        $sdk = Join-Path $env:LOCALAPPDATA "Programs\Swift\Platforms\$swiftVersion\Windows.platform\Developer\SDKs\Windows.sdk"
        if (Test-Path $sdk) { $env:SDKROOT = $sdk }
    }
}
if (-not $env:SDKROOT) {
    $userSdk = [Environment]::GetEnvironmentVariable("SDKROOT", "User")
    if ($userSdk) { $env:SDKROOT = $userSdk.TrimEnd('\') }
}
if (-not $env:SDKROOT -or -not (Test-Path $env:SDKROOT)) {
    throw "SDKROOT is not set and the Windows Swift SDK was not found."
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe not found. Install Visual Studio 2022 Build Tools."
}
$vsInstall = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsInstall) {
    throw "Visual Studio Build Tools with the C++ workload were not found (link.exe / Windows SDK)."
}
$vcvars = Join-Path $vsInstall "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found at $vcvars" }

$savedPath = $env:Path
$savedSdk = $env:SDKROOT
$vcvarsOutput = & cmd.exe /c "`"$vcvars`" >nul && set"
if ($LASTEXITCODE -ne 0) { throw "vcvars64.bat failed (exit $LASTEXITCODE)" }
foreach ($line in $vcvarsOutput) {
    if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        $name = $Matches[1]
        $value = $Matches[2]
        if ($name -eq "Path") {
            $env:Path = "$value;$savedPath"
        } else {
            Set-Item -Path "Env:$name" -Value $value
        }
    }
}
if (-not $env:SDKROOT) { $env:SDKROOT = $savedSdk }

if ($RunTests) {
    # Swift 6.4's swiftbuild backend currently discovers zero Swift Testing tests
    # here. Use the native backend until its DLL discovery is working.
    $discoveredTests = @(swift test --build-system native -c release list)
    if ($LASTEXITCODE -ne 0) { throw "Test discovery failed (exit $LASTEXITCODE)" }
    $coreTests = @($discoveredTests | Where-Object { $_ -match '^PalimpsestCoreTests\..+/' })
    $windowsTests = @($discoveredTests | Where-Object { $_ -match '^PalimpsestWinTests\..+/' })
    if ($coreTests.Count -eq 0 -or $windowsTests.Count -eq 0) {
        throw "Test discovery must find both Core and Windows tests; refusing a zero-test success."
    }
    Write-Host "Discovered $($coreTests.Count) Core tests and $($windowsTests.Count) Windows tests."
    swift test --build-system native -c release
    if ($LASTEXITCODE -ne 0) { throw "swift test failed (exit $LASTEXITCODE)" }
}

# Apply GUI startup flags only to this executable build, never to test DLLs.
# Build after testing so the installed artifact always has the GUI subsystem.
swift build -c release --product PalimpsestWin -Xlinker /SUBSYSTEM:WINDOWS -Xlinker /ENTRY:mainCRTStartup
if ($LASTEXITCODE -ne 0) { throw "swift build failed (exit $LASTEXITCODE)" }

# Testing and GUI builds may use different backends. Ask the GUI build backend
# for its output rather than installing a stale executable from another backend.
$binDirectory = & swift build -c release --show-bin-path
if ($LASTEXITCODE -ne 0) { throw "Could not resolve the GUI build output" }
$bin = Join-Path ($binDirectory | Select-Object -Last 1) "PalimpsestWin.exe"
if (-not (Test-Path -LiteralPath $bin)) { throw "Build produced no PalimpsestWin.exe at $bin" }

# Verify the artifact itself, including when tests also produced a console exe.
$exeBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $bin))
if ($exeBytes.Length -lt 64) { throw "Build output is not a valid PE executable" }
$peOffset = [BitConverter]::ToInt32($exeBytes, 0x3C)
if ($peOffset -lt 0 -or $peOffset + 94 -gt $exeBytes.Length -or
    [BitConverter]::ToUInt32($exeBytes, $peOffset) -ne 0x00004550 -or
    [BitConverter]::ToUInt16($exeBytes, $peOffset + 92) -ne 2) {
    throw "Build output does not have the Windows GUI subsystem; refusing to install it."
}
Write-Host "Verified GUI executable: $bin"
function Copy-RuntimeClosure([string]$exePath, [string]$runtimeBin, [string]$destDir) {
    $dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if (-not $dumpbin) {
        Write-Warning "dumpbin.exe not found; Swift runtime DLLs were not copied beside the exe."
        return
    }
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $seen = @{}
    $exeDeps = & $dumpbin.Source /dependents $exePath
    $inDeps = $false
    foreach ($line in $exeDeps) {
        if ($line -match "dependencies:") { $inDeps = $true; continue }
        if ($inDeps -and $line -match "Summary") { break }
        if ($inDeps -and $line -match "^\s+(\S+\.dll)\s*$") {
            $name = $Matches[1]
            if (-not $seen.ContainsKey($name)) {
                $seen[$name] = $true
                $queue.Enqueue($name)
            }
        }
    }
    $copied = 0
    while ($queue.Count -gt 0) {
        $name = $queue.Dequeue()
        $source = Join-Path $runtimeBin $name
        if (-not (Test-Path $source)) { continue }
        Copy-Item $source (Join-Path $destDir $name) -Force
        $copied++
        $deps = & $dumpbin.Source /dependents $source
        $inDeps = $false
        foreach ($line in $deps) {
            if ($line -match "dependencies:") { $inDeps = $true; continue }
            if ($inDeps -and $line -match "Summary") { break }
            if ($inDeps -and $line -match "^\s+(\S+\.dll)\s*$") {
                $next = $Matches[1]
                if (-not $seen.ContainsKey($next)) {
                    $seen[$next] = $true
                    $queue.Enqueue($next)
                }
            }
        }
    }
    Write-Host "Copied $copied Swift runtime DLLs to $destDir"
}

if ($Portable) {
    if (-not $script:swiftRuntimeBin -or -not (Get-Command dumpbin.exe -ErrorAction SilentlyContinue)) {
        throw "A Swift runtime directory and dumpbin.exe are required to package the portable archive."
    }
    $stage = Join-Path (Join-Path $PSScriptRoot '..\.build\portable') ([Guid]::NewGuid().ToString())
    $artifacts = Join-Path $PSScriptRoot '..\.build\artifacts'
    New-Item -ItemType Directory -Force -Path $stage, $artifacts | Out-Null
    Copy-Item -LiteralPath $bin -Destination (Join-Path $stage 'ScribbleEverywhere.exe')
    Copy-RuntimeClosure (Resolve-Path $bin) $script:swiftRuntimeBin $stage
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\LICENSE') -Destination $stage
    $archive = Join-Path $artifacts 'ScribbleEverywhere-windows-x64-portable.zip'
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive -Force
    Write-Host "Portable archive: $archive"
    Write-Host "The app stores settings and annotation history in the user profile."
    return
}

if ($NoInstall) {
    Write-Host "Build complete; installation skipped."
    return
}

$dest = Join-Path $env:LOCALAPPDATA "PalimpsestInk"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

# The running app locks swiftCore.dll, so replace the install only after it exits.
Get-Process PalimpsestWin, ScribbleEverywhere -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400

if ($script:swiftRuntimeBin) {
    Copy-RuntimeClosure (Resolve-Path $bin) $script:swiftRuntimeBin $dest
} else {
    Write-Warning "Swift runtime directory not found; DLLs were not copied beside the exe."
}

$installedExe = Join-Path $dest "ScribbleEverywhere.exe"
try {
    Copy-Item $bin $installedExe -Force -ErrorAction Stop
} catch {
    Get-Process PalimpsestWin, ScribbleEverywhere -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 400
    Copy-Item $bin $installedExe -Force
}

# Keep existing startup shortcuts and pen-service integrations functional.
Copy-Item $bin (Join-Path $dest 'PalimpsestWin.exe') -Force -ErrorAction Stop

Write-Host "Installed: $installedExe"
Write-Host "Launch it from a shortcut in shell:startup for autostart:"
Write-Host "  $dest\ScribbleEverywhere.exe"
Write-Host ""
Write-Host "First run: left-click the tray icon (or Ctrl+Alt+D) toggles annotation."
Write-Host "Right-click opens the menu: ink colour, and which window to paste into."
