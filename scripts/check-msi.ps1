#!/usr/bin/env pwsh
# Read the built installer database without installing or registering it.
param([string]$Path = '.build\artifacts\ScribbleEverywhere-windows-x64.msi')
$ErrorActionPreference = 'Stop'
$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.OpenDatabase((Resolve-Path -LiteralPath $Path).Path, 0)
function Read-Property([string]$name) {
    $view = $database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$name'")
    try { [void]$view.Execute(); $row = $view.Fetch(); if ($row) { return $row.StringData(1) } }
    finally { [void]$view.Close() }
}
try {
    if ((Read-Property 'ProductName') -ne 'ScribbleEverywhere') { throw 'Unexpected product name' }
    if ((Read-Property 'UpgradeCode') -ne '{3C728B29-96A2-45AD-8A0A-5B5523FD3E28}') { throw 'Upgrade identity changed' }
    if (Read-Property 'ALLUSERS') { throw 'Expected a per-user package' }
    $view = $database.OpenView('SELECT `FileName` FROM `File`')
    $names = @()
    try { $view.Execute(); while ($row = $view.Fetch()) { $names += ($row.StringData(1) -split '\|')[-1] } }
    finally { $view.Close() }
    if ($names -notcontains 'ScribbleEverywhere.exe' -or $names -notcontains 'swiftCore.dll') { throw 'Executable or Swift runtime missing' }
    $view = $database.OpenView('SELECT `Component`,`Attributes`,`KeyPath` FROM `Component`')
    $components = 0
    try {
        $view.Execute()
        while ($row = $view.Fetch()) {
            if (($row.IntegerData(2) -band 4) -eq 0) { throw "Component $($row.StringData(1)) lacks a registry key path" }
            $key = $row.StringData(3).Replace("'", "''")
            $registryView = $database.OpenView("SELECT ``Root`` FROM ``Registry`` WHERE ``Registry``='$key'")
            try {
                $registryView.Execute(); $registry = $registryView.Fetch()
                if (-not $registry -or $registry.IntegerData(1) -ne 1) { throw 'Component key path is not in HKCU' }
            } finally { $registryView.Close() }
            $components++
        }
    } finally { $view.Close() }
    if ($components -eq 0) { throw 'No components found' }
    Write-Host "MSI metadata and $components per-user component key paths validated; $($names.Count) files present."
} finally {
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
}
