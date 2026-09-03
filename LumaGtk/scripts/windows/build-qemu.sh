#!/bin/sh
#
# Build the emulators the virtual machines run, from unmodified QEMU
# source, in an MSYS2 MinGW environment. Only what the app drives is
# kept: the dbus display, QMP and the gdb stub; the GTK, SDL, VNC and
# curses frontends the upstream Windows build carries are left out, and
# with them the second copy of GTK the installer used to ship.
#
#     build-qemu.sh <upstream-version> <build> <output-dir>
#
# Stages a qemu-<build>-windows-x86_64.zip laid out the way
# package-msi.ps1 stages it onward: emulators, qemu-img and their DLLs
# at the root beside COPYING and COPYING.LIB, firmware in share/ and
# keymaps in share/keymaps. Prints the artifact's checksum and the
# source it corresponds to, which is what the release notes carry.

set -eu

version=$1
build=$2
output=$(cd "$3" && pwd)

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

curl -sSfLO "https://download.qemu.org/qemu-$version.tar.xz"
tar xf "qemu-$version.tar.xz"

prefix="$workdir/install"
mkdir build
cd build
"../qemu-$version/configure" \
    --prefix="$prefix" \
    --target-list=i386-softmmu,x86_64-softmmu,arm-softmmu,aarch64-softmmu \
    --enable-dbus-display \
    --enable-tools \
    --disable-gtk \
    --disable-sdl \
    --disable-vnc \
    --disable-curses \
    --disable-docs \
    --disable-guest-agent \
    --disable-guest-agent-msi \
    --disable-slirp \
    --disable-werror
make -j"$(nproc)"
make install
cd ..

stage="$workdir/stage"
mkdir -p "$stage/share/keymaps"

find "$prefix" -name 'qemu-system-*.exe' -exec cp {} "$stage/" \;
find "$prefix" -name 'qemu-img.exe' -exec cp {} "$stage/" \;

datadir=$(dirname "$(find "$prefix" -name 'bios-256k.bin')")
find "$datadir" -maxdepth 1 -type f -exec cp {} "$stage/share/" \;
cp -R "$datadir/keymaps/." "$stage/share/keymaps/"

cp "qemu-$version/COPYING" "qemu-$version/COPYING.LIB" "$stage/"

for exe in "$stage"/*.exe; do
    ntldd -R "$exe"
done | grep -io '[a-z0-9_.+-]*\.dll => [a-z]:\\[^ ]*' | cut -d' ' -f3 | sort -u | while read -r dll; do
    case $(cygpath -u "$dll") in
    /mingw*/bin/*)
        cp "$(cygpath -u "$dll")" "$stage/"
        ;;
    esac
done

artifact="qemu-$build-windows-x86_64.zip"
(cd "$stage" && zip -qr "$output/$artifact" .)

checksum=$(sha256sum "$output/$artifact" | cut -d' ' -f1)
cat <<EOF
QEMU $version, built from the unmodified source at
https://download.qemu.org/qemu-$version.tar.xz with the GTK, SDL, VNC
and curses frontends disabled. QEMU is GPLv2; COPYING and COPYING.LIB
are in the archive, and the URL above is the complete corresponding
source.

$artifact
SHA256: $checksum
EOF
