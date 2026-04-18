# Launch the LumaGtk executable built by build.ps1 with the runtime
# environment (PATH, GDK_PIXBUF_MODULE_FILE, XDG_DATA_DIRS) configured
# for a working GTK install.
#
#     .\scripts\windows\run.ps1                      # debug
#     .\scripts\windows\run.ps1 -Configuration release
#     .\scripts\windows\run.ps1 --monaco-demo
#
# Extra arguments after -Configuration are forwarded to the exe.

[CmdletBinding()]
param(
    [ValidateSet('debug','release')]
    [string] $Configuration = 'debug',

    [string] $VcpkgPrefix,
    [string] $FridaPrefix,

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

$exe = Join-Path $pkg ".build\$Configuration\LumaGtk.exe"
if (-not (Test-Path $exe)) {
    throw "LumaGtk.exe not found at $exe. Build it first with build.ps1."
}

# Prefer the gtk-from-git prefix when present so the launched exe
# loads the locally built gtk4 / gdk DLLs instead of vcpkg's copies.
$gtkPrefix = if ($env:GTK_PREFIX) { $env:GTK_PREFIX } else { 'C:\src\gtk-prefix' }
$gtkBin = Join-Path $gtkPrefix 'bin'
$pathParts = @()
if (Test-Path $gtkBin) { $pathParts += $gtkBin }
$pathParts += "$VcpkgPrefix\bin","$VcpkgPrefix\tools","$FridaPrefix\bin",$env:PATH
$env:PATH = ($pathParts -join ';')
$env:GDK_PIXBUF_MODULE_FILE = "$VcpkgPrefix\lib\gdk-pixbuf-2.0\2.10.0\loaders.cache"
$env:XDG_DATA_DIRS = if ($env:XDG_DATA_DIRS) {
    "$VcpkgPrefix\share;$env:XDG_DATA_DIRS"
} else {
    "$VcpkgPrefix\share"
}

# /SUBSYSTEM:WINDOWS means the shell won't wait for the exe by
# default; Start-Process -Wait keeps the script synchronous.
$startArgs = @{ FilePath = $exe; Wait = $true; NoNewWindow = $false }
if ($ExtraArgs) { $startArgs.ArgumentList = $ExtraArgs }
Start-Process @startArgs
