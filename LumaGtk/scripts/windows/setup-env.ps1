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

# frida-core and radare2 install .pc files with an absolute prefix
# like `prefix=C:/src/dist`. vcpkg's pkgconf trips over the colon in
# the drive letter and emits "Expected a value for variable 'prefix'",
# leaving every ${prefix}-derived variable unresolved — which in turn
# makes Swift's .systemLibrary(pkgConfig:) resolver return no include
# paths. Rewrite the prefix to a pcfiledir-relative form so the file
# is relocatable and colon-free. Idempotent.
function Repair-PkgConfigPrefix {
    param([string] $PkgConfigDir)
    if (-not (Test-Path $PkgConfigDir)) { return }
    Get-ChildItem -Path $PkgConfigDir -Filter '*.pc' -File | ForEach-Object {
        $content = Get-Content -Raw -LiteralPath $_.FullName
        if ($content -match '(?m)^prefix=\$\{pcfiledir\}') { return }
        $patched = $content -replace '(?m)^prefix=.*', 'prefix=${pcfiledir}/../..'
        [System.IO.File]::WriteAllText($_.FullName, $patched, [System.Text.UTF8Encoding]::new($false))
    }
}
Repair-PkgConfigPrefix (Join-Path $frida 'lib\pkgconfig')
Repair-PkgConfigPrefix (Join-Path $r2    'lib\pkgconfig')

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

# Root-level vcpkg headers (WebView2.h, sqlite3.h, ...) aren't visible
# through pkg-config, so point clang at the vcpkg-shim staging dir that
# mirrors $VCPKG_PREFIX/include minus the dirent.h polyfill that would
# clash with Swift's _FoundationCShims. Everything else (gtk4, glib,
# libadwaita, frida-core, radare2, ...) is reachable via pkg-config now
# that the relocatable .pc prefix is in place.
$shimDir = (Join-Path $vcpkg 'include\vcpkg-shim') -replace '\\','/'

$env:VCPKG_PREFIX          = $vcpkg
$env:FRIDA_PREFIX          = $frida
$env:R2_PREFIX             = $r2
$env:PKG_CONFIG_PATH       = $pkgConfigDirs -join ';'
$env:GIR_EXTRA_SEARCH_PATH = (Join-Path $vcpkg 'share\gir-1.0') -replace '\\','/'
$env:CPATH                 = $shimDir
$env:CPLUS_INCLUDE_PATH    = $shimDir

# Put the dependency prefixes on PATH so pkg-config and the built
# executable (via run.ps1) can find the runtime DLLs.
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

# rc.exe lives in the Windows SDK bin and isn't on PATH in plain
# cmd / PowerShell. Package.swift uses it to compile the exe icon
# resource when swift build runs outside a Developer prompt.
if (-not (Get-Command rc.exe -ErrorAction SilentlyContinue)) {
    $sdkRoot = 'C:\Program Files (x86)\Windows Kits\10\bin'
    if (Test-Path $sdkRoot) {
        $sdkBin = Get-ChildItem $sdkRoot -Directory |
            Where-Object { $_.Name -match '^10\.' } |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'x64' } |
            Where-Object { Test-Path (Join-Path $_ 'rc.exe') } |
            Select-Object -First 1
        if ($sdkBin) { $env:PATH = "$sdkBin;$env:PATH" }
    }
}

Write-Host "LumaGtk build env configured:"
Write-Host "  VCPKG_PREFIX  = $vcpkg"
Write-Host "  FRIDA_PREFIX  = $frida"
Write-Host "  R2_PREFIX     = $r2"
