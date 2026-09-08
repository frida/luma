# Load the MSVC toolchain environment into the current PowerShell session.
#
# Dot-source it, or run it from a script that wants cl.exe, link.exe and
# the Windows SDK on PATH without the caller having had to start a
# Developer PowerShell:
#
#     . .\scripts\windows\msvc-env.ps1
#
# Does nothing when cl.exe is already reachable, so it is safe to call
# from a Developer PowerShell too.

[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string] $Arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' })
)

$ErrorActionPreference = 'Stop'

if (Get-Command cl.exe -ErrorAction SilentlyContinue) { return }

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    throw @"
vswhere.exe not found at $vswhere.
Install Visual Studio 2022 (or the Build Tools) with the "Desktop
development with C++" workload, or start this from a Developer
PowerShell for VS.
"@
}

$vsRoot = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $vsRoot) {
    throw "No Visual Studio installation with the MSVC toolchain found. Install the `"Desktop development with C++`" workload."
}

$vcvarsName = if ($Arch -eq 'x64') { 'vcvars64.bat' } else { "vcvars$Arch.bat" }
$vcvars = Join-Path $vsRoot "VC\Auxiliary\Build\$vcvarsName"
if (-not (Test-Path $vcvars)) { throw "$vcvarsName not found under $vsRoot." }

& $env:ComSpec /c "call `"$vcvars`" >nul 2>&1 && set" | ForEach-Object {
    $name, $value = $_ -split '=', 2
    if ($name -and $null -ne $value) {
        Set-Item -Path "env:$name" -Value $value
    }
}

if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    throw "Ran $vcvars but cl.exe is still not on PATH."
}
