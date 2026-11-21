#!/bin/sh

set -eu

ARCH=$(uname -m)
VERSION=${LUMA_VERSION:-1.0.0}

echo "Installing package dependencies..."
echo "---------------------------------------------------------------"
pacman -Syu --noconfirm libgee libadwaita libepoxy libzip \
    libnice gtksourceview5 librsvg \
    qemu-system-x86 qemu-system-aarch64 qemu-system-arm qemu-img

echo "Installing debloated packages..."
echo "---------------------------------------------------------------"
get-debloated-pkgs --add-common --prefer-nano

bsdtar -xOf ./luma-$VERSION-ubuntu-26.04-$ARCH.deb data.tar.zst | bsdtar -xf - --strip-components=2 -C /usr/

export ARCH VERSION
export OUTPATH=$(pwd)
export ADD_HOOKS="self-updater.hook"
export UPINFO="gh-releases-zsync|${GITHUB_REPOSITORY%/*}|${GITHUB_REPOSITORY#*/}|latest|*$ARCH.AppImage.zsync"
export ICON=/usr/share/icons/hicolor/512x512/apps/re.frida.Luma.png
export DESKTOP=/usr/share/applications/re.frida.Luma.desktop
export STARTUPWMCLASS=re.frida.Luma
export GTK_CLASS_FIX=1

quick-sharun \
    /usr/lib/luma/* \
    /usr/bin/qemu-system-* \
    /usr/bin/qemu-img \
    /usr/share/qemu

mv -f ./AppDir/lib/luma/*.resources ./AppDir/bin/
patchelf --set-interpreter "$(patchelf --print-interpreter /usr/lib/luma/luma)" ./AppDir/shared/bin/luma

quick-sharun --make-appimage
quick-sharun --test $OUTPATH/*.AppImage
