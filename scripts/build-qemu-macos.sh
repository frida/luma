#!/bin/sh
#
# The macOS flavour of LumaGtk/scripts/windows/build-qemu.sh: the same
# slim QEMU, built against Homebrew, whose dylibs are copied in and
# rewritten to @executable_path-relative names so the binaries travel
# on their own. Rewriting breaks the ad-hoc signatures, so every
# touched Mach-O is re-signed.
#
#     build-qemu-macos.sh <upstream-version> <build> <output-dir>
#
# Stages a qemu-<build>-macos-<arch>.zip: emulators and qemu-img at the
# root beside COPYING and COPYING.LIB, their dylibs in lib/, firmware
# in share/ and keymaps in share/keymaps. Prints the artifact's
# checksum and the source it corresponds to.

set -eu

version=$1
build=$2
output=$(cd "$3" && pwd)
arch=$(uname -m)

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
    --disable-slirp \
    --disable-werror
make -j"$(sysctl -n hw.ncpu)"
make install
cd ..

stage="$workdir/stage"
mkdir -p "$stage/lib" "$stage/share/keymaps"

cp "$prefix"/bin/qemu-system-* "$prefix/bin/qemu-img" "$stage/"
datadir=$(dirname "$(find "$prefix" -name 'bios-256k.bin')")
find "$datadir" -maxdepth 1 -type f -exec cp {} "$stage/share/" \;
cp -R "$datadir/keymaps/." "$stage/share/keymaps/"

cp "qemu-$version/COPYING" "qemu-$version/COPYING.LIB" "$stage/"

brew_prefix=$(brew --prefix)

imported_libraries() {
    otool -L "$1" | sed 1d | awk '{print $1}' | grep "^$brew_prefix" || true
}

adopt_libraries() (
    file=$1
    for library in $(imported_libraries "$file"); do
        name=$(basename "$library")
        if [ "$name" = "$(basename "$file")" ]; then
            continue
        fi
        if [ ! -f "$stage/lib/$name" ]; then
            cp -L "$library" "$stage/lib/$name"
            chmod u+w "$stage/lib/$name"
            install_name_tool -id "@executable_path/lib/$name" "$stage/lib/$name"
            adopt_libraries "$stage/lib/$name"
        fi
        install_name_tool -change "$library" "@executable_path/lib/$name" "$file"
    done
)

for binary in "$stage"/qemu-system-* "$stage/qemu-img"; do
    adopt_libraries "$binary"
done
codesign --force -s - "$stage"/qemu-system-* "$stage/qemu-img" "$stage"/lib/*.dylib

artifact="qemu-$build-macos-$arch.zip"
(cd "$stage" && zip -qry "$output/$artifact" .)

checksum=$(shasum -a 256 "$output/$artifact" | cut -d' ' -f1)
cat <<EOF
QEMU $version for macOS ($arch), built from the unmodified source at
https://download.qemu.org/qemu-$version.tar.xz with the GTK, SDL, VNC
and curses frontends disabled. QEMU is GPLv2; COPYING and COPYING.LIB
are in the archive, and the URL above is the complete corresponding
source.

$artifact
SHA256: $checksum
EOF
