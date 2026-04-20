#!/usr/bin/env bash
# Stage a /usr tree ready for rpmbuild/dpkg-deb.
#
# usage: stage.sh STAGE_DIR BINARY FRIDA_LIBDIR SWIFT_LIBDIR LIBXML2
#
#   STAGE_DIR     - directory to populate with the installable /usr tree
#   BINARY        - path to the freshly built LumaGtk executable. The
#                   SwiftPM *.resources bundles are picked up from the
#                   same build directory.
#   FRIDA_LIBDIR  - directory holding libfrida-core-1.0.so.* and frida-1.0/
#   SWIFT_LIBDIR  - directory holding the Swift runtime .so files
#                   (usually .../lib/swift/linux)
#   LIBXML2       - libxml2 .so to ship beside libFoundationXML; renamed to
#                   libxml2.so.2 so the legacy SONAME the Swift runtime
#                   expects keeps resolving regardless of host ABI bumps

set -euo pipefail

stage="$1"
exe="$2"
frida_libdir="$3"
swift_libdir="$4"
libxml2="$5"

here="$(dirname "$(readlink -f "$0")")"
lumagtk_root="$(readlink -f "$here/../..")"
build_dir="$(dirname "$(readlink -f "$exe")")"

luma_lib="$stage/usr/lib/luma"
install -d "$stage/usr/bin" \
           "$stage/usr/share/applications" \
           "$stage/usr/share/mime/packages" \
           "$luma_lib" "$luma_lib/swift"

# Install the real binary under /usr/lib/luma so the SwiftPM .resources
# bundles that Bundle.module looks up via /proc/self/exe can sit beside
# it without cluttering /usr/bin. /usr/bin/luma becomes a relative
# symlink, which /proc/self/exe resolves to the real path.
install -m755 "$exe" "$luma_lib/luma"
ln -sf ../lib/luma/luma "$stage/usr/bin/luma"

for bundle in "$build_dir"/*.resources; do
    [ -d "$bundle" ] || continue
    cp -a "$bundle" "$luma_lib/"
done

cp -P "$frida_libdir"/libfrida-core-1.0.so* "$luma_lib/"
rsync -aL --exclude='frida-gadget*' "$frida_libdir/frida-1.0/" "$luma_lib/frida-1.0/"

for so in "$swift_libdir"/*.so; do
    case "$(basename "$so")" in
        libXCTest.so|libTesting.so|lib_Testing_Foundation.so) continue ;;
    esac
    cp -P "$so" "$luma_lib/swift/"
done

install -m644 "$libxml2" "$luma_lib/swift/libxml2.so.2"

strip --strip-unneeded "$luma_lib/luma"
find "$luma_lib" -name '*.so*' -type f -exec strip --strip-unneeded {} +

patchelf --set-rpath '$ORIGIN:$ORIGIN/swift' "$luma_lib/luma"
for so in "$luma_lib/frida-1.0"/*/*.so; do
    patchelf --set-rpath '$ORIGIN/../..' "$so"
done

install -Dm644 "$lumagtk_root/data/re.frida.Luma.desktop" "$stage/usr/share/applications/re.frida.Luma.desktop"
install -Dm644 "$lumagtk_root/data/re.frida.Luma.xml" "$stage/usr/share/mime/packages/re.frida.Luma.xml"
for size in 32 48 64 128 256 512; do
    install -Dm644 "$lumagtk_root/data/icons/hicolor/${size}x${size}/apps/re.frida.Luma.png" \
                   "$stage/usr/share/icons/hicolor/${size}x${size}/apps/re.frida.Luma.png"
done
