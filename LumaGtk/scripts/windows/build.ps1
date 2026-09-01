# Build LumaGtk on Windows.
#
#     .\scripts\windows\build.ps1                 # debug
#     .\scripts\windows\build.ps1 -Configuration release
#
# Requires Swift for Windows on PATH and the dependency prefixes that
# bootstrap.ps1 provisions. The MSVC environment is loaded on demand, so
# a plain PowerShell will do.

[CmdletBinding()]
param(
    [ValidateSet('debug','release')]
    [string] $Configuration = 'debug',

    [string] $VcpkgPrefix,
    [string] $FridaPrefix,
    [string] $R2Prefix,
    [string] $PharoPrefix,

    # SwiftPM build directory; defaults to LumaGtk\.build.
    [string] $BuildPath,

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]] $ExtraArgs
)

$ErrorActionPreference = 'Stop'
$script = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkg    = Resolve-Path (Join-Path $script '..\..')

if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
    throw "swift.exe not on PATH. Install Swift for Windows and re-run from a Developer PowerShell for VS."
}
. (Join-Path $script 'msvc-env.ps1')

& (Join-Path $script 'stage-pharo-image.ps1')

& (Join-Path $script 'setup-env.ps1') `
    -VcpkgPrefix $VcpkgPrefix `
    -FridaPrefix $FridaPrefix `
    -R2Prefix    $R2Prefix `
    -PharoPrefix $PharoPrefix

Push-Location $pkg
try {
    # /ignore:importeddllmain silences vcpkg libxml2's DllMain re-export.
    # /ignore:4217 silences LNK4217 — Swift-on-Windows marks every C
    # module import as dllimport even when the C target links into the
    # same binary, and lld-link complains every time Yams calls a
    # yaml_* function. These apply to all link invocations (including
    # plugin tool binaries), so they live here rather than in
    # Package.swift, which only scopes to its own targets.
    $swiftArgs = @(
        'build', '-c', $Configuration,
        '-Xlinker', '/ignore:importeddllmain',
        '-Xlinker', '/ignore:4217'
    )
    if ($BuildPath) { $swiftArgs += @('--build-path', $BuildPath) }
    $swiftArgs += $ExtraArgs
    & swift @swiftArgs
    if ($LASTEXITCODE -ne 0) { throw "swift build failed ($LASTEXITCODE)" }
} finally {
    Pop-Location
}
