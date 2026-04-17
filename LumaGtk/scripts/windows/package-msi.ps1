# Package LumaGtk as a Windows installer (.msi) using WiX 3.x.
#
#     .\scripts\windows\package-msi.ps1                       # debug
#     .\scripts\windows\package-msi.ps1 -Configuration release
#
# By default builds release if no existing build is found. Produces
# build\Luma-<version>-<arch>.msi.

[CmdletBinding()]
param(
    [ValidateSet('debug','release')]
    [string] $Configuration = 'release',

    [string] $Version       = '0.1.0',
    [string] $OutputDir,
    [string] $VcpkgPrefix,
    [string] $FridaPrefix,
    [string] $R2Prefix,

    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
$script = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkg    = Resolve-Path (Join-Path $script '..\..')

if (-not $OutputDir) { $OutputDir = Join-Path $pkg 'build' }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

if (-not $SkipBuild) {
    & (Join-Path $script 'build.ps1') `
        -Configuration $Configuration `
        -VcpkgPrefix   $VcpkgPrefix `
        -FridaPrefix   $FridaPrefix `
        -R2Prefix      $R2Prefix
    if ($LASTEXITCODE -ne 0) { throw "build failed" }
} else {
    & (Join-Path $script 'setup-env.ps1') `
        -VcpkgPrefix $VcpkgPrefix `
        -FridaPrefix $FridaPrefix `
        -R2Prefix    $R2Prefix
}

$wixRoot = $env:WIX
if (-not $wixRoot) {
    foreach ($candidate in @(
        'C:\Program Files (x86)\WiX Toolset v3.14',
        'C:\Program Files (x86)\WiX Toolset v3.11'
    )) {
        if (Test-Path $candidate) { $wixRoot = $candidate; break }
    }
}
if (-not $wixRoot -or -not (Test-Path $wixRoot)) {
    throw "WiX Toolset not found. Install WiX 3.x or set `$env:WIX."
}
$heat   = Join-Path $wixRoot 'bin\heat.exe'
$candle = Join-Path $wixRoot 'bin\candle.exe'
$light  = Join-Path $wixRoot 'bin\light.exe'

$exe = Join-Path $pkg ".build\$Configuration\LumaGtk.exe"
if (-not (Test-Path $exe)) { throw "LumaGtk.exe not found at $exe. Run build first." }

$stage = Join-Path $OutputDir "stage-$Configuration"
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Copy-Item $exe (Join-Path $stage 'Luma.exe')

$dllSearchPath = @(
    (Join-Path $env:VCPKG_PREFIX 'bin'),
    (Join-Path $env:FRIDA_PREFIX 'bin'),
    (Join-Path $env:R2_PREFIX    'bin')
) | Where-Object { Test-Path $_ }

$dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
if (-not $dumpbin) { throw "dumpbin.exe not on PATH. Run from a Developer PowerShell for VS." }

$seen = @{}
function Add-DllClosure {
    param([string] $Binary)
    $deps = & $dumpbin.Path /DEPENDENTS $Binary 2>$null | ForEach-Object {
        if ($_ -match '^\s+([^\s].*\.dll)\s*$') { $Matches[1] }
    }
    foreach ($dep in $deps) {
        $key = $dep.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        foreach ($dir in $dllSearchPath) {
            $path = Join-Path $dir $dep
            if (Test-Path $path) {
                $seen[$key] = $path
                Copy-Item $path (Join-Path $stage $dep) -Force
                Add-DllClosure $path
                break
            }
        }
    }
}
Add-DllClosure $exe

# GTK data: icons, glib schemas, gdk-pixbuf loaders.
function Copy-Tree {
    param([string] $From, [string] $To)
    if (-not (Test-Path $From)) { return }
    robocopy $From $To /E /NFL /NDL /NJH /NJS /NP /XO | Out-Null
}
Copy-Tree (Join-Path $env:VCPKG_PREFIX 'share\glib-2.0\schemas') (Join-Path $stage 'share\glib-2.0\schemas')
Copy-Tree (Join-Path $env:VCPKG_PREFIX 'share\icons')            (Join-Path $stage 'share\icons')
Copy-Tree (Join-Path $env:VCPKG_PREFIX 'lib\gdk-pixbuf-2.0')     (Join-Path $stage 'lib\gdk-pixbuf-2.0')

$arch    = 'x64'
$msiName = "Luma-$Version-$arch.msi"
$wixObj  = Join-Path $OutputDir 'wixobj'
New-Item -ItemType Directory -Force -Path $wixObj | Out-Null

$componentsWxs = Join-Path $wixObj 'components.wxs'
& $heat dir $stage -cg LumaComponents -gg -sfrag -srd -scom -sreg `
    -dr INSTALLDIR -var var.StageDir -out $componentsWxs
if ($LASTEXITCODE -ne 0) { throw "heat failed ($LASTEXITCODE)" }

$productWxs = Join-Path $wixObj 'product.wxs'
@"
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
  <Product Id="*" Name="Luma" Language="1033" Version="$Version"
           Manufacturer="Frida" UpgradeCode="5d2a2a6f-1c1e-4f80-96bb-2c3e4f6a5b11">
    <Package InstallerVersion="500" Compressed="yes" InstallScope="perMachine" />
    <MajorUpgrade DowngradeErrorMessage="A newer version of Luma is already installed." />
    <MediaTemplate EmbedCab="yes" />
    <Feature Id="Main" Title="Luma" Level="1">
      <ComponentGroupRef Id="LumaComponents" />
      <ComponentRef Id="ApplicationShortcut" />
    </Feature>
    <Directory Id="TARGETDIR" Name="SourceDir">
      <Directory Id="ProgramFiles64Folder">
        <Directory Id="INSTALLDIR" Name="Luma" />
      </Directory>
      <Directory Id="ProgramMenuFolder">
        <Directory Id="ApplicationProgramsFolder" Name="Luma" />
      </Directory>
    </Directory>
    <DirectoryRef Id="ApplicationProgramsFolder">
      <Component Id="ApplicationShortcut" Guid="a7b4e3f2-21d9-4b8a-9f3b-64a2e3b2a001">
        <Shortcut Id="ApplicationStartMenuShortcut" Name="Luma"
                  Description="Interactive dynamic instrumentation"
                  Target="[INSTALLDIR]Luma.exe" WorkingDirectory="INSTALLDIR" />
        <RemoveFolder Id="CleanupApplicationProgramsFolder" On="uninstall" />
        <RegistryValue Root="HKCU" Key="Software\Frida\Luma" Name="installed"
                       Type="integer" Value="1" KeyPath="yes" />
      </Component>
    </DirectoryRef>
  </Product>
</Wix>
"@ | Set-Content -Encoding UTF8 $productWxs

$wixOut = Join-Path $OutputDir $msiName
& $candle -arch $arch "-dStageDir=$stage" -out "$wixObj\" $productWxs $componentsWxs
if ($LASTEXITCODE -ne 0) { throw "candle failed ($LASTEXITCODE)" }
& $light -ext WixUIExtension -sice:ICE91 -sice:ICE64 -sice:ICE60 `
    -b $stage -out $wixOut `
    (Join-Path $wixObj 'product.wixobj') (Join-Path $wixObj 'components.wixobj')
if ($LASTEXITCODE -ne 0) { throw "light failed ($LASTEXITCODE)" }

Write-Host ""
Write-Host "Wrote $wixOut"
