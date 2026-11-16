# Build a GTK checkout against the vcpkg prefix, for trying a change to
# our GTK fork without going through vcpkg, which rebuilds GTK from
# scratch on every change.
#
#     .\Scripts\windows\build-gtk.ps1                # ..\..\..\gtk beside luma
#     .\Scripts\windows\build-gtk.ps1 -Source C:\src\gtk
#     .\Scripts\windows\run.ps1 -GtkBuild C:\Work\gtk\build-luma
#
# The first run configures and builds all of GTK; after that ninja
# recompiles only what changed and relinks gtk-4-1.dll. run.ps1 puts that
# DLL ahead of the vcpkg one.

[CmdletBinding()]
param(
    [string] $Source = (Join-Path $PSScriptRoot '..\..\..\..\gtk'),
    [string] $BuildDir,
    [string] $VcpkgPrefix
)

$ErrorActionPreference = 'Stop'

$Source = (Resolve-Path -LiteralPath $Source).Path
if (-not $BuildDir) { $BuildDir = Join-Path $Source 'build-luma' }

if (-not $VcpkgPrefix) {
    $triplet = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64-windows-release' } else { 'x64-windows-release' }
    $VcpkgPrefix = $env:VCPKG_PREFIX
    if (-not $VcpkgPrefix) {
        $VcpkgPrefix = Join-Path $env:LOCALAPPDATA "Luma\windows-deps\vcpkg\installed\$triplet"
    }
}
$VcpkgPrefix = (Resolve-Path -LiteralPath $VcpkgPrefix).Path

. (Join-Path $PSScriptRoot 'msvc-env.ps1')

$env:PATH = "$VcpkgPrefix\bin;$VcpkgPrefix\tools\pkgconf;$VcpkgPrefix\tools\glib;$env:PATH"
$env:PKG_CONFIG_PATH = "$VcpkgPrefix\lib\pkgconfig;$VcpkgPrefix\share\pkgconfig"
$env:INCLUDE = "$VcpkgPrefix\include;$env:INCLUDE"
$env:LIB = "$VcpkgPrefix\lib;$env:LIB"

$meson = @('python', '-m', 'mesonbuild.mesonmain')

if (-not (Test-Path (Join-Path $BuildDir 'build.ninja'))) {
    # The glib tools are extensionless Python scripts and sassc sits in a
    # directory of its own, so neither is found on PATH; vcpkg names them
    # to meson the same way.
    # Build tools are installed for vcpkg's host triplet, which lacks the
    # -release suffix of the target one.
    $hostPrefix = ($VcpkgPrefix -replace '-release$', '') -replace '\\', '/'
    $glib = "$hostPrefix/tools/glib"
    $sassc = "$hostPrefix/tools/sassc/bin/sassc.exe"
    New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
    $nativeFile = Join-Path $BuildDir 'vcpkg-tools.ini'
    @"
[binaries]
glib-genmarshal = ['python', '$glib/glib-genmarshal']
glib-mkenums = ['python', '$glib/glib-mkenums']
gdbus-codegen = ['python', '$glib/gdbus-codegen']
glib-compile-resources = '$glib/glib-compile-resources.exe'
glib-compile-schemas = '$glib/glib-compile-schemas.exe'
sassc = '$sassc'
"@ | Set-Content -Encoding ascii $nativeFile

    # Keep these in step with .github/vcpkg-ports/gtk/portfile.cmake.
    # Introspection is left out: nothing here needs it and it is the
    # slowest part of a GTK build.
    & $meson[0] $meson[1..2] setup $BuildDir $Source `
        --native-file $nativeFile `
        --buildtype=release `
        -Dx11-backend=false -Dbroadway-backend=false `
        -Dwin32-backend=true -Dmacos-backend=false `
        -Dbuild-demos=false -Dbuild-testsuite=false -Dbuild-examples=false -Dbuild-tests=false `
        -Ddocumentation=false -Dman-pages=false `
        -Dmedia-gstreamer=disabled -Dprint-cups=disabled -Dvulkan=disabled `
        -Dcloudproviders=disabled -Dsysprof=disabled -Dtracker=disabled -Dcolord=disabled `
        -Df16c=disabled -Dintrospection=disabled `
        --wrap-mode=nodownload
    if ($LASTEXITCODE) { throw "meson setup failed ($LASTEXITCODE)" }
}

& $meson[0] $meson[1..2] compile -C $BuildDir gtk-4
if ($LASTEXITCODE) { throw "meson compile failed ($LASTEXITCODE)" }

Write-Host "Built $(Join-Path $BuildDir 'gtk\gtk-4-1.dll')"
