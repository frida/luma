# Stage the Pharo image the way scripts/stage-pharo-image.sh does for the
# other platforms.
#
# The image is a resource of LumaCore, and PharoWorkspace.boot() takes its
# absence for a broken build rather than something to handle -- so a Windows
# build that skips this links fine and then dies on launch, unwrapping nil.
#
# The release is read out of the shell script rather than repeated here, so
# there is still only one place that says which image the build wants. A
# sibling ../SwiftyPharo checkout wins over the published one, the way the VM
# and the shader toolchain already work.

[CmdletBinding()]
param(
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDir '..\..\..')).Path

$staged = Join-Path $repoRoot 'Sources\LumaCore\Resources\pharo-image'
$stagedImage = Join-Path $staged 'SwiftyPharo.image'

if ((Test-Path $stagedImage) -and -not $Force) { return }

$shellScript = Join-Path $repoRoot 'scripts\stage-pharo-image.sh'
$release = (Select-String -Path $shellScript -Pattern '^release="([^"]+)"').Matches[0].Groups[1].Value
if (-not $release) { throw "Could not read the image release from $shellScript." }

$local = Join-Path $repoRoot '..\SwiftyPharo\artifacts\SwiftyPharo.image'
if (Test-Path $local) {
    $image = (Resolve-Path $local).Path
} else {
    $cache = Join-Path $repoRoot "build\.pharo\$release"
    $image = Join-Path $cache 'SwiftyPharo.image'
    if (-not (Test-Path $image)) {
        Write-Host "Fetching Pharo image $release"
        New-Item -ItemType Directory -Force -Path $cache | Out-Null
        $zip = Join-Path $cache 'image.zip'
        Invoke-WebRequest -UseBasicParsing `
            -Uri "https://github.com/frida/SwiftyPharo/releases/download/$release/SwiftyPharo.image.zip" `
            -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $cache -Force
    }
}

New-Item -ItemType Directory -Force -Path $staged | Out-Null
Copy-Item $image $stagedImage -Force
Copy-Item ([System.IO.Path]::ChangeExtension($image, 'changes')) (Join-Path $staged 'SwiftyPharo.changes') -Force
Write-Host "Staged the Pharo image from $image"
