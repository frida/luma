# Provision everything LumaGtk needs to build on Windows.
#
#     .\scripts\windows\bootstrap.ps1          # everything that is missing
#     .\scripts\windows\bootstrap.ps1 -Force   # rebuild it anyway
#
# Each component is skipped when its prefix already looks populated, so
# re-running after a failure picks up where it stopped. CI calls the same
# script one component at a time, between its cache restore and save:
#
#     .\scripts\windows\bootstrap.ps1 -Only frida-core -FridaPrefix D:\a\_temp\frida-prefix
#
# so the recipes below are the only copy there is. The upstream revisions
# live in .github/dependency-refs.env, which the workflow loads too.

[CmdletBinding()]
param(
    [ValidateSet('vcpkg', 'gnu-tools', 'frida-core', 'radare2', 'pharo-vm')]
    [string[]] $Only,

    [string] $DepsRoot = (Join-Path $env:LOCALAPPDATA 'Luma\windows-deps'),

    [string] $VcpkgRoot,
    [string] $VcpkgPrefix,
    [string] $FridaPrefix,
    [string] $R2Prefix,
    [string] $PharoPrefix,

    [ValidateSet('x64', 'arm64')]
    [string] $Arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }),

    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDir '..\..\..')).Path

$triplet = "$Arch-windows-release"

if (-not $VcpkgRoot) { $VcpkgRoot = Join-Path $DepsRoot 'vcpkg' }
if (-not $VcpkgPrefix) { $VcpkgPrefix = Join-Path $VcpkgRoot "installed\$triplet" }
if (-not $FridaPrefix) { $FridaPrefix = Join-Path $DepsRoot 'frida-prefix' }
if (-not $R2Prefix) { $R2Prefix = Join-Path $DepsRoot 'r2-prefix' }
if (-not $PharoPrefix) { $PharoPrefix = Join-Path $DepsRoot 'pharo-prefix' }

$sourceRoot = Join-Path $DepsRoot 'src'

function Test-Wanted {
    param([string] $Component)
    return (-not $Only) -or ($Only -contains $Component)
}

function Write-Step {
    param([string] $Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-Checked {
    param([string] $What, [scriptblock] $Body)
    & $Body
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" }
}

$refs = @{}
Get-Content (Join-Path $repoRoot '.github\dependency-refs.env') | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#')) {
        $name, $value = $line -split '=', 2
        $refs[$name.Trim()] = $value.Trim()
    }
}

function Sync-Checkout {
    param([string] $Url, [string] $Ref, [string] $Path, [switch] $Submodules)
    if (-not (Test-Path (Join-Path $Path '.git'))) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        Invoke-Checked "git clone $Url" { git clone $Url $Path }
    }
    Push-Location $Path
    try {
        & git rev-parse --quiet --verify "$Ref^{commit}" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Invoke-Checked 'git fetch' { git fetch --tags origin }
        }
        Invoke-Checked 'git checkout' { git checkout --quiet --detach $Ref }
        Invoke-Checked 'git reset' { git reset --quiet --hard $Ref }
        if ($Submodules) {
            Invoke-Checked 'git submodule update' { git submodule update --init --recursive --depth 1 }
        }
    } finally {
        Pop-Location
    }
}

function Repair-PkgConfigPrefix {
    param([string] $Prefix)
    $dir = Join-Path $Prefix 'lib\pkgconfig'
    if (-not (Test-Path $dir)) { return }
    Get-ChildItem -Path $dir -Filter '*.pc' -File | ForEach-Object {
        $content = Get-Content -Raw -LiteralPath $_.FullName
        if ($content -match '(?m)^prefix=\$\{pcfiledir\}') { return }
        $patched = $content -replace '(?m)^prefix=.*', 'prefix=${pcfiledir}/../..'
        [System.IO.File]::WriteAllText($_.FullName, $patched, [System.Text.UTF8Encoding]::new($false))
    }
}

function Show-QuarantineReport {
    param([string] $Path)
    $detections = try {
        Get-MpThreatDetection -ErrorAction Stop |
            Where-Object { $_.Resources -like "*$Path*" }
    } catch {
        return
    }
    if (-not $detections) { return }

    $files = $detections.Resources |
        Where-Object { $_ -like "*$Path*" } |
        ForEach-Object { $_ -replace '^file:_', '' } |
        Select-Object -Unique -First 5
    Write-Host ""
    Write-Warning @"
Windows Defender quarantined files from the dependency tree:
  $($files -join "`n  ")

radare2 ships shellcode as source, and Defender takes it while the
build is compiling it. To build radare2 here, exclude the dependency
tree and re-run -- from an *elevated* PowerShell, and only if you are
happy excluding it:

  Add-MpPreference -ExclusionPath "$Path"

Nothing here changes your antivirus settings. If you would rather not
exclude anything, pass -R2Prefix pointing at a radare2 you already
have and the rest still builds.
"@
}

function Test-Provisioned {
    param([string] $Prefix, [string] $PkgConfigName)
    if ($Force) { return $false }
    return Test-Path (Join-Path $Prefix "lib\pkgconfig\$PkgConfigName")
}

function Get-BashPath {
    $bash = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($bash -and $bash.Source -notmatch '\\WindowsApps\\') { return $bash.Source }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
        'C:\msys64\usr\bin\bash.exe'
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    throw "No bash.exe found. Install Git for Windows."
}

foreach ($tool in @('git', 'python', 'node')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool is not on PATH. See the Windows section of README.md for the prerequisites."
    }
}

. (Join-Path $scriptDir 'msvc-env.ps1') -Arch $Arch

foreach ($tool in @('meson', 'ninja')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Step "Installing $tool"
        Invoke-Checked "pip install $tool" { python -m pip install --user --quiet meson ninja setuptools }
        $userScripts = & python -c "import site, os; print(os.path.join(site.USER_BASE, 'Scripts'))"
        if (-not (($env:PATH -split ';') -contains $userScripts)) {
            $env:PATH = "$userScripts;$env:PATH"
        }
        break
    }
}

if (Test-Wanted 'vcpkg') {
    Write-Step "vcpkg ($triplet) -> $VcpkgPrefix"
    $vcpkgExe = Join-Path $VcpkgRoot 'vcpkg.exe'
    if (-not (Test-Path $vcpkgExe)) {
        if (-not (Test-Path (Join-Path $VcpkgRoot '.git'))) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $VcpkgRoot) | Out-Null
            Invoke-Checked 'git clone vcpkg' { git clone https://github.com/microsoft/vcpkg.git $VcpkgRoot }
        }
        Invoke-Checked 'bootstrap-vcpkg' { & (Join-Path $VcpkgRoot 'bootstrap-vcpkg.bat') -disableMetrics }
    }

    $ports = @(
        'glib', 'glib-networking', 'json-glib', 'libsoup', 'libffi', 'openssl',
        'gtk[introspection]', 'atk[introspection]', 'libadwaita[introspection]',
        'gtksourceview[introspection]', 'libepoxy', 'librsvg', 'libxml2',
        'graphite2', 'sqlite3[snapshot]', 'webview2'
    )
    Invoke-Checked 'vcpkg install' {
        & $vcpkgExe install `
            "--overlay-triplets=$repoRoot\.github\vcpkg-triplets" `
            "--overlay-ports=$repoRoot\.github\vcpkg-ports" `
            --triplet $triplet `
            @ports
    }
}

function Enable-PkgConfig {
    $tools = Join-Path $VcpkgPrefix 'tools\pkgconf'
    $pkgconf = Join-Path $tools 'pkgconf.exe'
    if (-not (Test-Path $pkgconf)) { return }
    $alias = Join-Path $tools 'pkg-config.exe'
    if (-not (Test-Path $alias)) { Copy-Item $pkgconf $alias }
    if (-not (($env:PATH -split ';') -contains $tools)) {
        $env:PATH = "$tools;$env:PATH"
    }
    $pcDir = (Join-Path $VcpkgPrefix 'lib\pkgconfig') -replace '\\', '/'
    if (($env:PKG_CONFIG_PATH -split ';') -notcontains $pcDir) {
        $env:PKG_CONFIG_PATH = (@($pcDir) + @($env:PKG_CONFIG_PATH | Where-Object { $_ })) -join ';'
    }
    $env:PKG_CONFIG_ALLOW_SYSTEM_CFLAGS = '1'
    $env:PKG_CONFIG_ALLOW_SYSTEM_LIBS = '1'
}
Enable-PkgConfig

if (Test-Wanted 'gnu-tools') {
    $native = @(
        'C:\msys64\usr\bin\sed.exe',
        'C:\Program Files (x86)\GnuWin32\bin\sed.exe',
        'C:\ProgramData\chocolatey\bin\sed.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($native -and -not $Force) {
        Write-Step "GNU tools already present ($native)"
    } else {
        Write-Step 'Installing native sed/awk'
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            & winget install --silent --accept-source-agreements --accept-package-agreements `
                --id GnuWin32.Sed
            & winget install --silent --accept-source-agreements --accept-package-agreements `
                --id GnuWin32.Gawk
        } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
            & choco install -y --no-progress sed gawk
        } else {
            throw @"
Neither winget nor choco is available to install sed/awk.
Install MSYS2 (https://www.msys2.org/) under C:\msys64, or GnuWin32's
sed and gawk, and re-run.
"@
        }
        $gnuBin = 'C:\Program Files (x86)\GnuWin32\bin'
        if (Test-Path (Join-Path $gnuBin 'gawk.exe')) {
            Copy-Item (Join-Path $gnuBin 'gawk.exe') (Join-Path $gnuBin 'awk.exe') -Force
        }
    }
}

if (Test-Wanted 'frida-core') {
    if (Test-Provisioned $FridaPrefix 'frida-core-1.0.pc') {
        Write-Step "frida-core already at $FridaPrefix"
    } else {
        Write-Step "Building frida-core -> $FridaPrefix"
        $src = Join-Path $sourceRoot 'frida-core'
        Sync-Checkout -Url 'https://github.com/frida/frida-core.git' `
            -Ref $refs['FRIDA_CORE_REF'] -Path $src -Submodules
        Push-Location $src
        try {
            Invoke-Checked 'frida-core configure' {
                python -c "import sys; sys.path.insert(0, '.'); from releng.meson_configure import main; main()" `
                    . `
                    --enable-shared `
                    --enable-compiler-backend `
                    --without-prebuilds=sdk `
                    "--prefix=$FridaPrefix" `
                    -- --force-fallback-for=openssl,libnghttp2 -Dtests=disabled '-Dfrida-gum:v8=disabled' `
                    '-Dbarebone_backend=enabled'
            }
            Invoke-Checked 'frida-core compile' { python releng/meson/meson.py compile -C build }
            Invoke-Checked 'frida-core install' {
                python releng/meson/meson.py install -C build --no-rebuild --skip-subprojects
            }
        } finally {
            Pop-Location
        }
        Repair-PkgConfigPrefix $FridaPrefix
    }
}

if (Test-Wanted 'radare2') {
    if (Test-Provisioned $R2Prefix 'libr.pc') {
        Write-Step "radare2 already at $R2Prefix"
    } else {
        Write-Step "Building radare2 -> $R2Prefix"
        $src = Join-Path $sourceRoot 'radare2'
        Sync-Checkout -Url 'https://github.com/radareorg/radare2.git' `
            -Ref $refs['RADARE2_REF'] -Path $src
        Push-Location $src
        try {
            $savedCFlags = $env:CFLAGS
            $env:CFLAGS = '/D_Static_assert=static_assert /std:c11'
            try {
                Invoke-Checked 'radare2 setup' {
                    meson setup build "--prefix=$R2Prefix" --buildtype=release `
                        --default-library=shared -Dcli=disabled
                }
                Invoke-Checked 'radare2 compile' { meson compile -C build }
                Invoke-Checked 'radare2 install' { meson install -C build }
            } catch {
                Show-QuarantineReport $DepsRoot
                throw
            } finally {
                $env:CFLAGS = $savedCFlags
            }
        } finally {
            Pop-Location
        }
        Repair-PkgConfigPrefix $R2Prefix
    }
}

if (Test-Wanted 'pharo-vm') {
    if (Test-Provisioned $PharoPrefix 'pharo-vm.pc') {
        Write-Step "Pharo VM already at $PharoPrefix"
    } else {
        Write-Step "Building the Pharo VM -> $PharoPrefix"
        $src = Join-Path $sourceRoot 'SwiftyPharo'
        Sync-Checkout -Url 'https://github.com/frida/SwiftyPharo.git' `
            -Ref $refs['SWIFTY_PHARO_REF'] -Path $src

        $saved = @{}
        foreach ($name in @('LIB', 'PATH')) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        try {
            $env:LIB = "$(Join-Path $VcpkgPrefix 'lib');$env:LIB"
            $env:PATH = "$(Split-Path -Parent (Get-Command cl.exe).Source);$env:PATH"

            $bash = Get-BashPath
            $unixSrc = ($src -replace '\\', '/') -replace '^([A-Za-z]):', '/$1'
            $unixPrefix = $PharoPrefix -replace '\\', '/'
            Invoke-Checked 'build-vm.sh' {
                & $bash -c "cd '$unixSrc' && CC=clang-cl CXX=clang-cl PLATFORM=windows DESTDIR= PREFIX='$unixPrefix' tools/build-vm.sh"
            }
        } finally {
            foreach ($name in $saved.Keys) {
                Set-Item -Path "env:$name" -Value $saved[$name]
            }
        }
        Repair-PkgConfigPrefix $PharoPrefix
    }
}

Write-Host ""
Write-Host "Dependencies ready:" -ForegroundColor Green
Write-Host "  VCPKG_PREFIX = $VcpkgPrefix"
Write-Host "  FRIDA_PREFIX = $FridaPrefix"
Write-Host "  R2_PREFIX    = $R2Prefix"
Write-Host "  PHARO_PREFIX = $PharoPrefix"
Write-Host ""
Write-Host "Next: .\scripts\windows\build.ps1"
