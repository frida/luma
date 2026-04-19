#!/usr/bin/env bash
# Stage a /usr tree ready for rpmbuild/dpkg-deb.
#
# usage: stage.sh STAGE_DIR FRIDA_LIBDIR SWIFT_LIBDIR
#
#   STAGE_DIR    - empty directory that will be populated with /usr/...
#   FRIDA_LIBDIR - directory holding libfrida-core-1.0.so.* and frida-1.0/
#   SWIFT_LIBDIR - directory holding the Swift runtime .so files
#                  (usually .../lib/swift/linux)

set -euo pipefail

if [ $# -ne 3 ]; then
    echo "usage: $0 STAGE_DIR FRIDA_LIBDIR SWIFT_LIBDIR" >&2
    exit 1
fi

stage="$1"
frida_libdir="$2"
swift_libdir="$3"

here="$(dirname "$(readlink -f "$0")")"
lumagtk_root="$(readlink -f "$here/../..")"

exe="$(ls "$lumagtk_root"/.build/*/release/LumaGtk 2>/dev/null | head -1)"
if [ -z "$exe" ]; then
    echo "LumaGtk binary not found under $lumagtk_root/.build/*/release/" >&2
    exit 1
fi

luma_lib="$stage/usr/lib/luma"
install -d "$stage/usr/bin" \
           "$stage/usr/share/applications" \
           "$stage/usr/share/mime/packages" \
           "$luma_lib" "$luma_lib/swift"

install -m755 "$exe" "$stage/usr/bin/luma"

cp -P "$frida_libdir"/libfrida-core-1.0.so* "$luma_lib/"
rsync -aL --exclude='frida-gadget*' "$frida_libdir/frida-1.0/" "$luma_lib/frida-1.0/"

for so in "$swift_libdir"/*.so; do
    case "$(basename "$so")" in
        libXCTest.so|libTesting.so|lib_Testing_Foundation.so) continue ;;
    esac
    cp -P "$so" "$luma_lib/swift/"
done

# Swift's libFoundationXML keeps DT_NEEDED on libxml2.so.2, but
# Ubuntu 25.10+ (and eventually Fedora) ships only libxml2.so.16.
# Bundle whichever libxml2 the build host offers under the legacy
# SONAME so the app runs on distros that have already moved on.
xml_src=""
for candidate in "$frida_libdir/libxml2.so.2" "$frida_libdir/libxml2.so.16" \
                 /usr/lib/x86_64-linux-gnu/libxml2.so.2 /usr/lib/x86_64-linux-gnu/libxml2.so.16 \
                 /usr/lib64/libxml2.so.2 /usr/lib64/libxml2.so.16; do
    if [ -e "$candidate" ]; then
        xml_src="$(readlink -f "$candidate")"
        break
    fi
done
if [ -n "$xml_src" ]; then
    install -m644 "$xml_src" "$luma_lib/swift/libxml2.so.2"
fi

strip --strip-unneeded "$stage/usr/bin/luma"
find "$luma_lib" -name '*.so*' -type f -exec strip --strip-unneeded {} +

patchelf --set-rpath '$ORIGIN/../lib/luma:$ORIGIN/../lib/luma/swift' "$stage/usr/bin/luma"
for so in "$luma_lib/frida-1.0"/*/*.so; do
    [ -f "$so" ] || continue
    patchelf --set-rpath '$ORIGIN/../..' "$so"
done

install -Dm644 "$lumagtk_root/data/re.frida.Luma.desktop" "$stage/usr/share/applications/re.frida.Luma.desktop"
install -Dm644 "$lumagtk_root/data/re.frida.Luma.xml" "$stage/usr/share/mime/packages/re.frida.Luma.xml"
for size in 32 48 64 128 256 512; do
    install -Dm644 "$lumagtk_root/data/icons/hicolor/${size}x${size}/apps/re.frida.Luma.png" \
                   "$stage/usr/share/icons/hicolor/${size}x${size}/apps/re.frida.Luma.png"
done
