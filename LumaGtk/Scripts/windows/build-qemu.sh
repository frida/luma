#!/bin/sh
#
# Build the emulators the virtual machines run, from unmodified QEMU
# source, in an MSYS2 MinGW environment. Only what the app drives is
# kept: the dbus display, QMP and the gdb stub; the GTK, SDL, VNC and
# curses frontends the upstream Windows build carries are left out, and
# with them the second copy of GTK the installer used to ship.
#
#     build-qemu.sh <upstream-version> <prefix> <vcpkg-prefix>
#
# GLib and pixman are taken from the same vcpkg prefix the app itself
# links against, so the installer carries one copy of each rather than
# a MinGW set beside the MSVC one. That is a MinGW compiler linking
# MSVC-built DLLs, which holds because both sides sit on the UCRT: the
# MSYS2 environments this runs in -- UCRT64 and CLANGARM64 -- are UCRT
# environments, so a file descriptor or a FILE* means the same thing on
# either side of the call.
#
# Stages <prefix> the way package-msi.ps1 reads it onward: emulators,
# qemu-img and the MinGW runtime DLLs at the root beside COPYING and
# COPYING.LIB, firmware in share/ and keymaps in share/keymaps.
# Everything vcpkg already provides is left where the app's own copy
# is, one directory up from where the emulators land.

set -eu

version=$1
prefix=$2
vcpkg=$(cygpath -u "$3")

case $MSYSTEM in
UCRT64|CLANGARM64) ;;
*) echo "build-qemu.sh wants a UCRT environment; $MSYSTEM is not one." >&2; exit 1 ;;
esac

# The .pc files vcpkg writes name Windows paths, so pkgconf has to be
# told about them the way Windows writes a list.
PKG_CONFIG_LIBDIR=$(cygpath -m "$vcpkg/lib/pkgconfig")
export PKG_CONFIG_LIBDIR
unset PKG_CONFIG_PATH
PATH="$vcpkg/bin:$vcpkg/tools/glib:$PATH"
export PATH

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

curl -sSfLO "https://download.qemu.org/qemu-$version.tar.xz"
# The tarball carries symlinks that dangle -- edk2's X11IncludeHack among
# them -- and MSYS2 copies a symlink's target by default, so extraction
# fails on them. Shortcuts are made without looking at the target.
MSYS=winsymlinks:lnk tar xf "qemu-$version.tar.xz"

staging="$workdir/install"
bzip2_headers="$workdir/bzip2-headers"
mkdir -p "$bzip2_headers"
cp "$vcpkg/include/bzlib.h" "$bzip2_headers/"

mkdir build
cd build
"../qemu-$version/configure" \
    --prefix="$staging" \
    --extra-cflags="-I$(cygpath -m "$bzip2_headers")" \
    --extra-ldflags="-L$(cygpath -m "$vcpkg/lib")" \
    --target-list=i386-softmmu,x86_64-softmmu,arm-softmmu,aarch64-softmmu \
    --enable-dbus-display \
    --enable-bzip2 \
    --enable-zstd \
    --enable-tools \
    --disable-gtk \
    --disable-sdl \
    --disable-vnc \
    --disable-curses \
    --disable-docs \
    --disable-plugins \
    --disable-guest-agent \
    --disable-guest-agent-msi \
    --disable-slirp \
    --disable-werror
make -j"$(nproc)"
make install
cd ..

stage=$(cygpath -u "$prefix")
rm -rf "$stage"
mkdir -p "$stage/share/keymaps"

find "$staging" -name 'qemu-system-*.exe' -exec cp {} "$stage/" \;
find "$staging" -name 'qemu-img.exe' -exec cp {} "$stage/" \;

datadir=$(dirname "$(find "$staging" -name 'bios-256k.bin')")
find "$datadir" -maxdepth 1 -type f -exec cp {} "$stage/share/" \;
cp -R "$datadir/keymaps/." "$stage/share/keymaps/"

cp "qemu-$version/COPYING" "qemu-$version/COPYING.LIB" "$stage/"

# Only what MinGW itself contributes travels with the emulators; the
# vcpkg DLLs are already beside the app, which is where the emulators
# find them from.
for exe in "$stage"/*.exe; do
    ntldd -R "$exe"
done | grep -io '[a-z0-9_.+-]*\.dll => [a-z]:[^ ]*' | cut -d' ' -f3 | sort -u | while read -r dll; do
    case $(cygpath -u "$dll") in
    "$MINGW_PREFIX"/bin/*)
        [ -f "$vcpkg/bin/$(basename "$dll")" ] || cp "$(cygpath -u "$dll")" "$stage/"
        ;;
    esac
done
