#!/usr/bin/env pwsh
# Build an unsigned, per-user MSI from the tested portable build.
param(
    [switch]$SkipBuild,
    [string]$WixBinPath = '',
    [string]$WorkRoot = '',
    [string]$OutputDirectory = '',
    [string]$PayloadDirectory = ''
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root
if ($PayloadDirectory -and -not $SkipBuild) { throw '-PayloadDirectory requires -SkipBuild' }
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build-windows.ps1') -RunTests -Portable
}
$zipPath = Join-Path $root '.build\artifacts\ScribbleEverywhere-windows-x64-portable.zip'
if (-not (Test-Path -LiteralPath $zipPath)) { throw "Portable archive missing: $zipPath" }

if (-not $WixBinPath) {
    $WixBinPath = Join-Path $root '.build\tools\wix3141'
    if (-not (Test-Path -LiteralPath (Join-Path $WixBinPath 'candle.exe'))) {
        New-Item -ItemType Directory -Force -Path $WixBinPath | Out-Null
        $wixZip = Join-Path $WixBinPath 'wix314-binaries.zip'
        Invoke-WebRequest -Uri 'https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip' -OutFile $wixZip
        $expected = '6AC824E1642D6F7277D0ED7EA09411A508F6116BA6FAE0AA5F2C7DAA2FF43D31'
        if ((Get-FileHash -LiteralPath $wixZip -Algorithm SHA256).Hash -ne $expected) { throw 'WiX archive checksum mismatch' }
        Expand-Archive -LiteralPath $wixZip -DestinationPath $WixBinPath -Force
    }
}
foreach ($tool in @('heat.exe', 'candle.exe', 'light.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $WixBinPath $tool))) { throw "WiX tool not found: $tool" }
}
if (-not $WorkRoot) { $WorkRoot = Join-Path $root '.build\msi' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root '.build\artifacts' }
$buildDir = Join-Path $WorkRoot ([Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Force -Path $buildDir, $OutputDirectory | Out-Null
if ($PayloadDirectory) {
    $payload = (Resolve-Path -LiteralPath $PayloadDirectory).Path
} else {
    $payload = Join-Path $buildDir 'payload'
    New-Item -ItemType Directory -Force -Path $payload | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $payload
}
if (-not (Test-Path -LiteralPath (Join-Path $payload 'ScribbleEverywhere.exe'))) { throw 'Portable archive lacks executable' }
$versionMatch = Select-String -Path (Join-Path $root 'Sources\ScribbleEverywhereCore\Version.swift') -Pattern 'static let short = "([0-9]+\.[0-9]+\.[0-9]+)"'
if (-not $versionMatch) { throw 'Unable to determine product version' }
$version = $versionMatch.Matches[0].Groups[1].Value
$harvest = Join-Path $buildDir 'payload.wxs'
$mainObj = Join-Path $buildDir 'main.wixobj'
$payloadObj = Join-Path $buildDir 'payload.wixobj'
$msi = Join-Path $OutputDirectory 'ScribbleEverywhere-windows-x64.msi'
$pendingMsi = Join-Path $buildDir 'ScribbleEverywhere-windows-x64.msi'
& (Join-Path $WixBinPath 'heat.exe') dir $payload -cg ApplicationFiles -dr INSTALLFOLDER -srd -sreg -scom -sfrag -ag -var 'var.Payload' -out $harvest
if ($LASTEXITCODE -ne 0) { throw "WiX heat failed: $LASTEXITCODE" }
# ICE38 requires HKCU registry key paths for per-user file components.
# Deterministic component identities keep registry keys stable across upgrades.
[xml]$document = Get-Content -LiteralPath $harvest -Raw
$namespaces = [Xml.XmlNamespaceManager]::new($document.NameTable)
$namespaces.AddNamespace('w', 'http://schemas.microsoft.com/wix/2006/wi')
foreach ($component in $document.SelectNodes('//w:Component', $namespaces)) {
    $component.SetAttribute('Win64', 'yes')
    # WiX v3 cannot auto-generate GUIDs for a file plus a registry key path.
    $identity = $component.SelectSingleNode('w:File', $namespaces).GetAttribute('Source')
    $digest = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $digest.ComputeHash([Text.Encoding]::UTF8.GetBytes('ScribbleEverywhere.x64:' + $identity.ToLowerInvariant())) }
    finally { $digest.Dispose() }
    $component.SetAttribute('Guid', ([Guid]::new([byte[]]$bytes[0..15])).ToString('B'))
    foreach ($file in $component.SelectNodes('w:File', $namespaces)) { $file.RemoveAttribute('KeyPath') }
    $key = $document.CreateElement('RegistryValue', 'http://schemas.microsoft.com/wix/2006/wi')
    foreach ($entry in @{Root='HKCU'; Key='Software\ScribbleEverywhere\Installer\Components'; Name=$component.Id; Type='integer'; Value='1'; KeyPath='yes'}.GetEnumerator()) {
        $key.SetAttribute($entry.Key, $entry.Value)
    }
    [void]$component.AppendChild($key)
}
$document.Save($harvest)
& (Join-Path $WixBinPath 'candle.exe') -nologo -arch x64 "-dProductVersion=$version" "-dPayload=$payload" -out $mainObj (Join-Path $root 'packaging\windows\ScribbleEverywhere.wxs')
if ($LASTEXITCODE -ne 0) { throw "WiX candle failed: $LASTEXITCODE" }
& (Join-Path $WixBinPath 'candle.exe') -nologo -arch x64 "-dPayload=$payload" -out $payloadObj $harvest
if ($LASTEXITCODE -ne 0) { throw "WiX payload compilation failed: $LASTEXITCODE" }
& (Join-Path $WixBinPath 'light.exe') -nologo -out $pendingMsi $mainObj $payloadObj
if ($LASTEXITCODE -ne 0) { throw "WiX link failed: $LASTEXITCODE" }
Copy-Item -LiteralPath $pendingMsi -Destination $msi -Force
Write-Host "Unsigned MSI: $msi"
