#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Stage the Adwaita icon theme under <ShareDir>\icons\Adwaita.

.DESCRIPTION
    vcpkg has no adwaita-icon-theme port, so fetch the upstream tarball and
    lay the theme out as a GTK icon theme. Symbolic icons (e.g.
    accessories-dictionary-symbolic in NotebookPane's empty state) live here,
    and libadwaita falls back to this theme when it can't resolve a name from
    its own GResource bundle. Idempotent, and reuses an already-downloaded
    tarball in CacheDir.

.PARAMETER ShareDir
    Data dir to populate; the theme lands at <ShareDir>\icons\Adwaita.

.PARAMETER CacheDir
    Where the tarball is downloaded and extracted. Defaults to ShareDir.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ShareDir,
    [string] $CacheDir
)
$ErrorActionPreference = 'Stop'
if (-not $CacheDir) { $CacheDir = $ShareDir }

$version = '50.0'
$sha256  = 'fac6e0401fca714780561a081b8f7e27c3bc1db34ebda4da175081f26b24d460'

$theme = Join-Path $ShareDir 'icons\Adwaita'
if (Test-Path (Join-Path $theme 'index.theme')) { return }

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
$tar = Join-Path $CacheDir "adwaita-icon-theme-$version.tar.xz"
$src = Join-Path $CacheDir "adwaita-icon-theme-$version"
if (-not (Test-Path $tar)) {
    $url = "https://download.gnome.org/sources/adwaita-icon-theme/50/adwaita-icon-theme-$version.tar.xz"
    Invoke-WebRequest -Uri $url -OutFile $tar
}
if ((Get-FileHash $tar -Algorithm SHA256).Hash.ToLower() -ne $sha256) {
    throw "Adwaita tarball SHA-256 mismatch"
}

# bsdtar (System32\tar.exe) wedges extracting this tarball on hosted runners
# for hours; 7-Zip extracts the same 1848 plain files cleanly. Two passes,
# since .tar.xz nests tar inside xz, and bound the inner extract so a
# regression can't hang the build again.
$sevenZip = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Path
if (-not $sevenZip) { $sevenZip = 'C:\Program Files\7-Zip\7z.exe' }
if (-not (Test-Path $sevenZip)) { throw "7z.exe not found for Adwaita extraction" }

if (Test-Path $src) { Remove-Item -Recurse -Force $src }
& $sevenZip x $tar "-o$CacheDir" -y -bso0 -bsp0
if ($LASTEXITCODE -ne 0) { throw "Adwaita xz decompress failed ($LASTEXITCODE)" }

$innerTar = Join-Path $CacheDir "adwaita-icon-theme-$version.tar"
$stderr = [System.IO.Path]::GetTempFileName()
$proc = Start-Process -FilePath $sevenZip `
    -ArgumentList 'x', $innerTar, "-o$CacheDir", '-y', '-bso0', '-bsp0' `
    -NoNewWindow -PassThru -RedirectStandardError $stderr
if (-not $proc.WaitForExit(120000)) {
    $proc.Kill()
    throw "Adwaita extraction hung (>120s)"
}
$exit = $proc.ExitCode
Remove-Item $stderr, $innerTar -ErrorAction SilentlyContinue
if ($exit -ne 0) { throw "Adwaita tar extract failed (exit $exit)" }

# Skip cursors/ (15 MB of X bitmap cursors Windows can't use).
New-Item -ItemType Directory -Force -Path $theme | Out-Null
Copy-Item (Join-Path $src 'index.theme') $theme
foreach ($size in '16x16', 'scalable', 'symbolic') {
    Copy-Item -Recurse -Force (Join-Path $src "Adwaita\$size") (Join-Path $theme $size)
}
