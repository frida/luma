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

if (-not $VcpkgPrefix) {
    $VcpkgPrefix = if ($env:VCPKG_PREFIX) { $env:VCPKG_PREFIX } else { 'C:\vcpkg\installed\x64-windows-release' }
}
if (-not $FridaPrefix) {
    $FridaPrefix = if ($env:FRIDA_PREFIX) { $env:FRIDA_PREFIX } else { 'C:\src\dist' }
}

$exe = Join-Path $pkg ".build\$Configuration\LumaGtk.exe"
if (-not (Test-Path $exe)) {
    throw "LumaGtk.exe not found at $exe. Build it first with build.ps1."
}

$env:PATH = "$VcpkgPrefix\bin;$VcpkgPrefix\tools;$FridaPrefix\bin;$env:PATH"
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
