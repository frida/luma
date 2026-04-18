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

# Prepend vcpkg's pkgconf + tools so pkg-config / other vcpkg-shipped
# helpers are reachable from any shell.
$vcpkgPkgconfTools = Join-Path $VcpkgPrefix 'tools\pkgconf'
$pkgconfExe  = Join-Path $vcpkgPkgconfTools 'pkgconf.exe'
$pkgConfigExe = Join-Path $vcpkgPkgconfTools 'pkg-config.exe'
if ((Test-Path $pkgconfExe) -and -not (Test-Path $pkgConfigExe)) {
    Copy-Item $pkgconfExe $pkgConfigExe
}
if (Test-Path $vcpkgPkgconfTools) {
    $env:PATH = "$vcpkgPkgconfTools;$env:PATH"
}

# Auto-load the MSVC dev env if cl isn't on PATH yet (mirrors build.ps1).
if (-not (Get-Command cl -ErrorAction SilentlyContinue)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        throw "cl.exe not on PATH and vswhere.exe not found. Launch a Developer PowerShell for VS (or run vcvars64.bat) first."
    }
    $vsRoot = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsRoot) { throw "No Visual Studio with MSVC toolchain found. Install VS Build Tools and try again." }
    $devShellDll = Join-Path $vsRoot 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
    if (-not (Test-Path $devShellDll)) { throw "VS DevShell module not found at $devShellDll." }
    Import-Module $devShellDll
    Enter-VsDevShell -VsInstallPath $vsRoot -SkipAutomaticLocation `
        -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
    if (-not (Get-Command cl -ErrorAction SilentlyContinue)) {
        throw "Failed to load MSVC environment from $vsRoot."
    }
}

foreach ($tool in 'meson','ninja','git','pkg-config') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not on PATH. Install it and re-run."
    }
}

Write-Host "VCPKG_PREFIX : $VcpkgPrefix"
Write-Host "GTK src      : $SrcDir"
Write-Host "GTK prefix   : $Prefix"
Write-Host "GTK ref      : $Ref"

# Wrap native commands so PowerShell doesn't surface their stderr
# progress output as "RemoteException" (git and friends write
# "Cloning into ..." / "From ..." / etc. to stderr). Let the native
# tool print directly so its output is captured by the parent pipe
# rather than sunk into PowerShell's object pipeline.
function Invoke-Native {
    param([string] $Command, [string[]] $Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Command exited with $LASTEXITCODE"
        }
    } finally {
        $ErrorActionPreference = $prev
    }
}

if (-not (Test-Path $SrcDir)) {
    Invoke-Native git @('clone','https://gitlab.gnome.org/GNOME/gtk.git',$SrcDir)
}

Push-Location $SrcDir
try {
    Invoke-Native git @('fetch','--tags','origin')
    Invoke-Native git @('checkout',$Ref)
    # Try fast-forward; silently ignore if $Ref is a tag or detached.
    try { Invoke-Native git @('pull','--ff-only','origin',$Ref) } catch {}

    # Always nuke the build dir — the meson version, compiler toolchain,
    # or the gtk tree itself may have changed between invocations, and
    # `meson configure` aborts with "No such build data file" if the
    # previous run's state is incompatible. Cheaper to re-setup than
    # to diagnose which piece drifted.
    if (Test-Path 'build') {
        Remove-Item -Recurse -Force 'build'
    }
    $Clean = $true  # existing build dir gone, so the "configure" branch below is unreachable

    # Let GTK's meson find its deps through vcpkg pkg-config files.
    # Prepend the vcpkg pkgconfig first so it's preferred for glib,
    # cairo, pango, graphene, etc.
    $vcpkgPkg = Join-Path $VcpkgPrefix 'lib\pkgconfig'
    $vcpkgLib = Join-Path $VcpkgPrefix 'lib'
    $vcpkgInclude = Join-Path $VcpkgPrefix 'include'
    $env:PKG_CONFIG_PATH = "$vcpkgPkg;$env:PKG_CONFIG_PATH"
    # vcpkg's gobject-introspection ships _giscanner as a .cp312 pyd,
    # so g-ir-scanner needs Python 3.12 at runtime. vcpkg keeps its
    # own 3.12 venv under buildtrees; put it first on PATH so meson
    # picks `python` from there instead of whatever system Python
    # happens to be installed.
    $vcpkgRoot = Split-Path (Split-Path $VcpkgPrefix -Parent) -Parent
    $vcpkgPy312 = Join-Path $vcpkgRoot 'buildtrees\gobject-introspection\x64-windows-release-gir-venv\Scripts'
    $venvPy     = Join-Path $vcpkgPy312 'python.exe'
    # g-ir-scanner is a shebang-only Python script and vcpkg's
    # _giscanner.pyd is built for CPython 3.12. Meson resolves the
    # script's `#!/usr/bin/env python3` via its own detection and
    # happily picks up the first python3 it finds — on this box
    # that's system 3.10, which then can't load the 3.12 .pyd. Hide
    # g-ir-scanner behind a .cmd wrapper that hardcodes vcpkg's 3.12
    # interpreter, and put that wrapper dir first on PATH so meson
    # sees our version before the raw script.
    $scannerWrapDir = Join-Path $env:TEMP 'luma-gtk-gir-wrap'
    New-Item -ItemType Directory -Force -Path $scannerWrapDir | Out-Null
    $scannerScript = Join-Path $VcpkgPrefix 'tools\gobject-introspection\g-ir-scanner'
    @"
@echo off
"$venvPy" "$scannerScript" %*
"@ | Set-Content -LiteralPath (Join-Path $scannerWrapDir 'g-ir-scanner.cmd') -Encoding ASCII

    $env:PATH = "$scannerWrapDir;$vcpkgPy312;$VcpkgPrefix\bin;$VcpkgPrefix\tools;$VcpkgPrefix\tools\pkgconf;$VcpkgPrefix\tools\gobject-introspection;$VcpkgPrefix\tools\glib;$env:PATH"

    # Meson's gnome module reads `g_ir_scanner` from
    # gobject-introspection-1.0.pc instead of doing a PATH lookup,
    # so the PATH wrapper above isn't enough. Mirror the .pc file
    # into a temp dir with `g_ir_scanner` pointing at our wrapper
    # and prepend that dir to PKG_CONFIG_PATH.
    $pcShimDir = Join-Path $env:TEMP 'luma-gtk-pc-shim'
    New-Item -ItemType Directory -Force -Path $pcShimDir | Out-Null
    $pcSrc = Join-Path $VcpkgPrefix 'lib\pkgconfig\gobject-introspection-1.0.pc'
    $pcDst = Join-Path $pcShimDir 'gobject-introspection-1.0.pc'
    $wrapperForward = (Join-Path $scannerWrapDir 'g-ir-scanner.cmd') -replace '\\','/'
    $pcContent = Get-Content -Raw -LiteralPath $pcSrc
    # The original file has `prefix=${pcfiledir}/../..`, which would
    # resolve to our temp dir when the .pc lives in pcShimDir and
    # break every other path it derives. Pin prefix to vcpkg's
    # absolute prefix instead.
    $vcpkgPrefixForward = $VcpkgPrefix -replace '\\','/'
    $pcContent = $pcContent -replace '(?m)^prefix=.*', "prefix=$vcpkgPrefixForward"
    $pcContent = $pcContent -replace '(?m)^g_ir_scanner=.*', "g_ir_scanner=$wrapperForward"
    [System.IO.File]::WriteAllText($pcDst, $pcContent, [System.Text.UTF8Encoding]::new($false))
    $env:PKG_CONFIG_PATH = "$pcShimDir;$env:PKG_CONFIG_PATH"
    # link.exe uses $LIB and cl.exe uses $INCLUDE for default search
    # paths. pkg-config gives meson explicit -L/-I for most libs, but
    # GTK's gsk Direct3D path pulls in DirectX-Headers.lib /
    # DirectX-Guids.lib by bare name — they live in vcpkg's lib dir
    # with no .pc reference, so put that dir on $LIB / $INCLUDE.
    $env:LIB     = "$vcpkgLib;$env:LIB"
    $env:INCLUDE = "$vcpkgInclude;$env:INCLUDE"

    # Pin Python via a meson native file so detection can't pick up
    # a different `python3.exe` from PATH (e.g. WindowsApps stub,
    # system Python 3.10). vcpkg's Python 3.12 is the one that
    # matches the shipped _giscanner.cp312-win_amd64.pyd.
    $nativeFile = Join-Path $env:TEMP 'luma-gtk-native.ini'
    $venvPyForward = $venvPy -replace '\\','/'
    @"
[binaries]
python = '$venvPyForward'
python3 = '$venvPyForward'
"@ | Set-Content -LiteralPath $nativeFile -Encoding ASCII

    $mesonArgs = @(
        'setup','build',
        "--native-file=$nativeFile",
        "--prefix=$Prefix",
        '--buildtype=release',
        # Default wrap-mode: prefer pkg-config (vcpkg's C dep graph
        # covers glib, cairo, pango, graphene, harfbuzz,
        # gobject-introspection, libepoxy, ...), fall back to
        # subprojects only when a package isn't findable. sassc has
        # no vcpkg equivalent, so the bundled sassc.wrap gets built;
        # wrap-mode=nofallback would block that because
        # --force-fallback-for doesn't cover find_program().
        '-Dbuild-demos=false',
        '-Dbuild-examples=false',
        '-Dbuild-tests=false',
        '-Dbuild-testsuite=false',
        '-Dintrospection=enabled',
        '-Dman-pages=false',
        '-Ddocumentation=false',
        # LumaGtk doesn't need video playback, print dialogs, Vulkan,
        # cloud-providers or sysprof integration.
        '-Dmedia-gstreamer=disabled',
        '-Dprint-cups=disabled',
        '-Dvulkan=disabled',
        '-Dcloudproviders=disabled',
        '-Dsysprof=disabled'
    )
    if (Test-Path 'build') {
        Invoke-Native meson (@('configure','build') + $mesonArgs[2..($mesonArgs.Count-1)])
    } else {
        Invoke-Native meson $mesonArgs
    }

    Invoke-Native ninja @('-C','build')

    # Install into the standalone prefix. Safe to run repeatedly.
    if (Test-Path $Prefix) {
        Remove-Item -Recurse -Force $Prefix
    }
    Invoke-Native ninja @('-C','build','install')

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
