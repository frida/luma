# Set environment variables needed to build LumaGtk on Windows.
#
# This script is intended to be dot-sourced from build.ps1 or from an
# interactive PowerShell prompt when iterating on the build manually.
#
#     . .\scripts\windows\setup-env.ps1
#
# Prefix locations can be overridden via -VcpkgPrefix / -FridaPrefix /
# -R2Prefix, or via the VCPKG_PREFIX / FRIDA_PREFIX / R2_PREFIX env
# vars.

[CmdletBinding()]
param(
    [string] $VcpkgPrefix,
    [string] $FridaPrefix,
    [string] $R2Prefix
)

$ErrorActionPreference = 'Stop'

function Resolve-Prefix {
    param([string] $Explicit, [string] $EnvName, [string[]] $Candidates)
    if ($Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
    if ($fromEnv) { return (Resolve-Path -LiteralPath $fromEnv).Path }
    foreach ($c in $Candidates) {
        if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path }
    }
    throw "Could not locate $EnvName. Pass -$($EnvName.Replace('_PREFIX','Prefix')) or set `$env:$EnvName."
}

$vcpkg = Resolve-Prefix $VcpkgPrefix 'VCPKG_PREFIX' @(
    'C:\vcpkg\installed\x64-windows-release',
    'C:\src\vcpkg\installed\x64-windows-release'
)
$frida = Resolve-Prefix $FridaPrefix 'FRIDA_PREFIX' @('C:\src\dist')
$r2    = Resolve-Prefix $R2Prefix    'R2_PREFIX'    @('C:\src\dist')

# vcpkg ships pkgconf.exe but SwiftGtk's Package.swift invokes
# "pkg-config". Provide an alias next to pkgconf.exe.
$pkgconfTools = Join-Path $vcpkg 'tools\pkgconf'
$pkgconf  = Join-Path $pkgconfTools 'pkgconf.exe'
$pkgAlias = Join-Path $pkgconfTools 'pkg-config.exe'
if ((Test-Path $pkgconf) -and -not (Test-Path $pkgAlias)) {
    Copy-Item $pkgconf $pkgAlias
}

# vcpkg drops a dirent.h polyfill at $prefix/include that conflicts with
# Swift's _FoundationCShims. Mirror the root headers into a staging dir
# excluding dirent.h so clang still finds WebView2.h, sqlite3.h, etc.
$shim = Join-Path $vcpkg 'include\vcpkg-shim'
New-Item -ItemType Directory -Force -Path $shim | Out-Null
Get-ChildItem (Join-Path $vcpkg 'include\*.h') -File | Where-Object {
    $_.Name -ne 'dirent.h'
} | ForEach-Object {
    $dest = Join-Path $shim $_.Name
    if (-not (Test-Path $dest) -or $_.LastWriteTimeUtc -gt (Get-Item $dest).LastWriteTimeUtc) {
        Copy-Item $_.FullName $dest
    }
}

$pkgConfigDirs = @(
    (Join-Path $frida 'lib\pkgconfig'),
    (Join-Path $r2    'lib\pkgconfig'),
    (Join-Path $vcpkg 'lib\pkgconfig')
) | ForEach-Object { $_ -replace '\\','/' } | Select-Object -Unique

$cpathDirs = @(
    'include\gtk-4.0',
    'include\pango-1.0',
    'include\harfbuzz',
    'include\gdk-pixbuf-2.0',
    'include\cairo',
    'include\graphene-1.0',
    'lib\graphene-1.0\include',
    'include\glib-2.0',
    'lib\glib-2.0\include',
    'include\vcpkg-shim'
) | ForEach-Object { (Join-Path $vcpkg $_) -replace '\\','/' }
$cpathDirs += (Join-Path $frida 'include\frida-1.0') -replace '\\','/'
$cpathDirs += (Join-Path $r2    'include')           -replace '\\','/'

$env:VCPKG_PREFIX          = $vcpkg
$env:FRIDA_PREFIX          = $frida
$env:R2_PREFIX             = $r2
$env:PKG_CONFIG_PATH       = $pkgConfigDirs -join ';'
$env:GIR_EXTRA_SEARCH_PATH = (Join-Path $vcpkg 'share\gir-1.0') -replace '\\','/'
$env:CPATH                 = $cpathDirs -join ';'
$env:CPLUS_INCLUDE_PATH    = $cpathDirs -join ';'

# Put the dependency prefixes on PATH so pkg-config and the built
# executable (via run.bat) can find the runtime DLLs.
$prefixBins = @(
    $pkgconfTools,
    (Join-Path $vcpkg 'bin'),
    (Join-Path $vcpkg 'tools'),
    (Join-Path $frida 'bin'),
    (Join-Path $r2    'bin')
) | Where-Object { Test-Path $_ }
foreach ($p in $prefixBins) {
    if (-not (($env:PATH -split ';') -contains $p)) {
        $env:PATH = "$p;$env:PATH"
    }
}

Write-Host "LumaGtk build env configured:"
Write-Host "  VCPKG_PREFIX  = $vcpkg"
Write-Host "  FRIDA_PREFIX  = $frida"
Write-Host "  R2_PREFIX     = $r2"
