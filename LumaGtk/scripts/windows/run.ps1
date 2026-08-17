# Launch the LumaGtk executable built by build.ps1 with the runtime
# environment (PATH, GDK_PIXBUF_MODULE_FILE, XDG_DATA_DIRS) configured
# for a working GTK install.
#
#     .\scripts\windows\run.ps1                      # debug
#     .\scripts\windows\run.ps1 -Configuration release
#
# Extra arguments after -Configuration are forwarded to the exe.

[CmdletBinding()]
param(
    [ValidateSet('debug','release')]
    [string] $Configuration = 'debug',

    [string] $VcpkgPrefix,
    [string] $FridaPrefix,
    [string] $R2Prefix,
    [string] $PharoPrefix,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ExtraArgs
)

$ErrorActionPreference = 'Stop'
$script = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkg    = Resolve-Path (Join-Path $script '..\..')

function Resolve-PrefixDir {
    param([string] $Explicit, [string] $EnvName, [string[]] $Candidates)
    if ($Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
    if ($fromEnv) { return (Resolve-Path -LiteralPath $fromEnv).Path }
    foreach ($c in $Candidates) {
        if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path }
    }
    throw "Could not locate $EnvName. Pass -$($EnvName.Replace('_PREFIX','Prefix')) or set `$env:$EnvName."
}

$VcpkgPrefix = Resolve-PrefixDir $VcpkgPrefix 'VCPKG_PREFIX' @(
    'C:\vcpkg\installed\x64-windows-release',
    'C:\src\vcpkg\installed\x64-windows-release'
)
$FridaPrefix = Resolve-PrefixDir $FridaPrefix 'FRIDA_PREFIX' @('C:\src\dist')
$R2Prefix    = Resolve-PrefixDir $R2Prefix    'R2_PREFIX'    @('C:\src\dist')
$PharoPrefix = Resolve-PrefixDir $PharoPrefix 'PHARO_PREFIX' @('C:\src\pharo')

$exe = Join-Path $pkg ".build\$Configuration\LumaGtk.exe"
if (-not (Test-Path $exe)) {
    throw "LumaGtk.exe not found at $exe. Build it first with build.ps1."
}

# GTK/libadwaita read their settings from GSettings; without a compiled
# schema source they abort with "g_settings_schema_source_lookup: source
# != NULL". vcpkg ships the schema XML but not the compiled cache.
$schemaDir = Join-Path $VcpkgPrefix 'share\glib-2.0\schemas'
if (-not (Test-Path (Join-Path $schemaDir 'gschemas.compiled'))) {
    & (Join-Path $VcpkgPrefix 'tools\glib\glib-compile-schemas.exe') $schemaDir
}

$adwaitaShare = Join-Path $pkg 'build\share'
& (Join-Path $script 'fetch-adwaita.ps1') -ShareDir $adwaitaShare -CacheDir (Join-Path $pkg 'build')

$env:PATH = "$VcpkgPrefix\bin;$VcpkgPrefix\tools;$FridaPrefix\bin;$R2Prefix\bin;$PharoPrefix\bin;$env:PATH"
$env:GDK_PIXBUF_MODULE_FILE = "$VcpkgPrefix\lib\gdk-pixbuf-2.0\2.10.0\loaders.cache"
$env:GIO_EXTRA_MODULES = "$VcpkgPrefix\plugins\glib-networking"
$dataDirs = @("$VcpkgPrefix\share", $adwaitaShare)
if ($env:XDG_DATA_DIRS) { $dataDirs += $env:XDG_DATA_DIRS }
$env:XDG_DATA_DIRS = $dataDirs -join ';'

# /SUBSYSTEM:WINDOWS means the shell won't wait for the exe by
# default; Start-Process -Wait keeps the script synchronous.
$stderrLog = Join-Path $pkg 'build\luma-stderr.log'
Write-Host "stderr -> $stderrLog"
$startArgs = @{ FilePath = $exe; Wait = $true; NoNewWindow = $false; RedirectStandardError = $stderrLog }
if ($ExtraArgs) { $startArgs.ArgumentList = $ExtraArgs }
Start-Process @startArgs
