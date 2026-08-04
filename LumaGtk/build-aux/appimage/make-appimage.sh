#!/bin/sh

set -eu

ARCH=$(uname -m)
VERSION=${LUMA_VERSION:-1.0.0}

# echo "Installing package dependencies..."
# echo "---------------------------------------------------------------"
# pacman -Syu --noconfirm PACKAGESHERE

echo "Installing debloated packages..."
echo "---------------------------------------------------------------"
get-debloated-pkgs --add-common --prefer-nano

mkdir -p ./AppDir/
bsdtar -xOf ./luma-$VERSION-ubuntu-26.04-x86_64.deb data.tar.xz | bsdtar -xf - --strip-components=2 -C ./AppDir/
mv -f ./AppDir/lib/luma/* ./AppDir/bin/
rm -rf ./AppDir/lib

export ARCH VERSION
export OUTPATH=$(pwd)
export ADD_HOOKS="self-updater.hook"
export UPINFO="gh-releases-zsync|${GITHUB_REPOSITORY%/*}|${GITHUB_REPOSITORY#*/}|latest|*$ARCH.AppImage.zsync"
export ICON=./AppDir/share/icons/hicolor/512x512/apps/re.frida.Luma.png
export DESKTOP=./AppDir/share/applications/re.frida.Luma.desktop
export GTK_CLASS_FIX=1

quick-sharun ./AppDir/bin/*

quick-sharun --make-appimage
