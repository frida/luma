# Build LumaGtk on Windows.
#
#     .\scripts\windows\build.ps1                 # debug
#     .\scripts\windows\build.ps1 -Configuration release
#
# Requires a Developer PowerShell for VS (or otherwise pre-loaded MSVC
# environment) and Swift for Windows on PATH.

[CmdletBinding()]
param(
    [ValidateSet('debug','release')]
    [string] $Configuration = 'debug',

    [string] $VcpkgPrefix,
    [string] $FridaPrefix,
    [string] $R2Prefix,

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]] $ExtraArgs
)

$ErrorActionPreference = 'Stop'
$script = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkg    = Resolve-Path (Join-Path $script '..\..')

if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
    throw "swift.exe not on PATH. Install Swift for Windows and re-run from a Developer PowerShell for VS."
}
if (-not (Get-Command cl -ErrorAction SilentlyContinue)) {
    throw "cl.exe not on PATH. Launch a Developer PowerShell for VS (or run vcvars64.bat) first."
}

& (Join-Path $script 'setup-env.ps1') `
    -VcpkgPrefix $VcpkgPrefix `
    -FridaPrefix $FridaPrefix `
    -R2Prefix    $R2Prefix

Push-Location $pkg
try {
    $swiftArgs = @('build', '-c', $Configuration) + $ExtraArgs
    & swift @swiftArgs
    if ($LASTEXITCODE -ne 0) { throw "swift build failed ($LASTEXITCODE)" }
} finally {
    Pop-Location
}
