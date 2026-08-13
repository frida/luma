#!/bin/sh

set -eu

here=$(dirname "$0")
ARCH=$(uname -m)
VERSION=${LUMA_VERSION:-1.0.0}

echo "Installing package dependencies..."
echo "---------------------------------------------------------------"
pacman -Syu --noconfirm libgee libadwaita webkitgtk-6.0 libepoxy libzip \
    libnice gtksourceview5 librsvg patchelf

echo "Installing debloated packages..."
echo "---------------------------------------------------------------"
get-debloated-pkgs --add-common --prefer-nano

mkdir -p ./AppDir/
bsdtar -xOf ./luma-$VERSION-ubuntu-26.04-x86_64.deb data.tar.zst | bsdtar -xf - --strip-components=2 -C ./AppDir/

# Sharun maps the interpreter itself and builds the stack it jumps to, which
# leaves the auxiliary vector saying the program has no interpreter at all.
# Gum reads that vector to find the program and its modules, so a library
# preloaded ahead of it puts the vector back.
g++ -std=c++23 -O2 -fPIC -shared -fno-exceptions -fno-rtti -Wall -Wextra \
    -static-libstdc++ -static-libgcc \
    "$here"/auxv-patch.cpp -o ./libpatch.so
echo 'libpatch.so' > ./AppDir/.preload

mv -f ./AppDir/lib/luma/* ./AppDir/bin/
rm -rf ./AppDir/lib

export ARCH VERSION
export OUTPATH=$(pwd)
export ADD_HOOKS="self-updater.hook"
export UPINFO="gh-releases-zsync|${GITHUB_REPOSITORY%/*}|${GITHUB_REPOSITORY#*/}|latest|*$ARCH.AppImage.zsync"
export ICON=./AppDir/share/icons/hicolor/512x512/apps/re.frida.Luma.png
export DESKTOP=./AppDir/share/applications/re.frida.Luma.desktop
export STARTUPWMCLASS=re.frida.Luma
export GTK_CLASS_FIX=1
export LD_LIBRARY_PATH=./AppDir/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

quick-sharun ./AppDir/bin/*
install -Dm755 ./libpatch.so ./AppDir/shared/lib/libpatch.so
quick-sharun --make-appimage
