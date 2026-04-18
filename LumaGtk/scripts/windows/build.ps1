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
