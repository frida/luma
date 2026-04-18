# Clone and build GTK 4 from git into a standalone prefix so we can
# prototype against its upstream HEAD without touching the vcpkg
# install. Keeps LumaGtk's other dependencies (libadwaita, glib,
# cairo, pango, ...) on vcpkg — setup-env.ps1 just prepends this
# prefix to PKG_CONFIG_PATH / PATH so gtk4.pc resolves here first.
#
#     .\scripts\windows\build-gtk-from-git.ps1
#     .\scripts\windows\build-gtk-from-git.ps1 -Ref main
#     .\scripts\windows\build-gtk-from-git.ps1 -Ref main -Clean   # wipe and rebuild from scratch
#
# Requires a Developer PowerShell for VS, meson + ninja on PATH,
# and vcpkg deps at $env:VCPKG_PREFIX (or the default path).

[CmdletBinding()]
param(
    [string] $Ref      = 'main',
    [string] $SrcDir   = 'C:\src\gtk',
    [string] $Prefix   = 'C:\src\gtk-prefix',
    [string] $VcpkgPrefix,
    [switch] $Clean
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command cl -ErrorAction SilentlyContinue)) {
    throw "cl.exe not on PATH. Launch a Developer PowerShell for VS (or run vcvars64.bat) first."
}
foreach ($tool in 'meson','ninja','git','pkg-config') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not on PATH. Install it (or re-run from a shell with vcpkg tools prepended)."
    }
}

if (-not $VcpkgPrefix) {
    if ($env:VCPKG_PREFIX) {
        $VcpkgPrefix = $env:VCPKG_PREFIX
    } else {
        foreach ($c in @('C:\vcpkg\installed\x64-windows-release','C:\src\vcpkg\installed\x64-windows-release')) {
            if (Test-Path $c) { $VcpkgPrefix = $c; break }
        }
    }
}
if (-not $VcpkgPrefix -or -not (Test-Path $VcpkgPrefix)) {
    throw "Could not locate vcpkg prefix. Pass -VcpkgPrefix."
}

Write-Host "VCPKG_PREFIX : $VcpkgPrefix"
Write-Host "GTK src      : $SrcDir"
Write-Host "GTK prefix   : $Prefix"
Write-Host "GTK ref      : $Ref"

if (-not (Test-Path $SrcDir)) {
    git clone https://gitlab.gnome.org/GNOME/gtk.git $SrcDir
    if ($LASTEXITCODE -ne 0) { throw "git clone failed ($LASTEXITCODE)" }
}

Push-Location $SrcDir
try {
    git fetch --tags origin
    git checkout $Ref
    if ($LASTEXITCODE -ne 0) { throw "git checkout $Ref failed" }
    git pull --ff-only origin $Ref 2>$null  # no-op for tags

    if ($Clean -and (Test-Path 'build')) {
        Remove-Item -Recurse -Force 'build'
    }

    # Let GTK's meson find its deps through vcpkg pkg-config files.
    # Prepend the vcpkg pkgconfig first so it's preferred for glib,
    # cairo, pango, graphene, etc.
    $vcpkgPkg = Join-Path $VcpkgPrefix 'lib\pkgconfig'
    $env:PKG_CONFIG_PATH = "$vcpkgPkg;$env:PKG_CONFIG_PATH"
    $env:PATH = "$VcpkgPrefix\bin;$VcpkgPrefix\tools;$VcpkgPrefix\tools\pkgconf;$env:PATH"

    $mesonArgs = @(
        'setup','build',
        "--prefix=$Prefix",
        '--buildtype=release',
        '-Dbuild-demos=false',
        '-Dbuild-examples=false',
        '-Dbuild-tests=false',
        '-Dbuild-testsuite=false',
        '-Dintrospection=enabled',
        '-Dman-pages=false',
        '-Ddocumentation=false'
    )
    if (Test-Path 'build') {
        & meson @(,'configure','build') + $mesonArgs[2..($mesonArgs.Count-1)]
    } else {
        & meson @mesonArgs
    }
    if ($LASTEXITCODE -ne 0) { throw "meson setup failed ($LASTEXITCODE)" }

    & ninja -C build
    if ($LASTEXITCODE -ne 0) { throw "ninja failed ($LASTEXITCODE)" }

    # Install into the standalone prefix. Safe to run repeatedly.
    if (Test-Path $Prefix) {
        Remove-Item -Recurse -Force $Prefix
    }
    & ninja -C build install
    if ($LASTEXITCODE -ne 0) { throw "ninja install failed ($LASTEXITCODE)" }

    # Rewrite the absolute `prefix=` in the installed .pc files to a
    # pcfiledir-relative form. pkgconf's colon-in-drive-letter parser
    # trips over absolute Windows paths otherwise (same fix we apply
    # to frida-core / radare2).
    Get-ChildItem (Join-Path $Prefix 'lib\pkgconfig\*.pc') -ErrorAction SilentlyContinue | ForEach-Object {
        $content = Get-Content -Raw -LiteralPath $_.FullName
        $patched = $content -replace '(?m)^prefix=.*', 'prefix=${pcfiledir}/../..'
        [System.IO.File]::WriteAllText($_.FullName, $patched, [System.Text.UTF8Encoding]::new($false))
    }

    Write-Host ""
    Write-Host "GTK installed to $Prefix"
    Write-Host "setup-env.ps1 will pick it up automatically on next build.ps1 run."
} finally {
    Pop-Location
}
