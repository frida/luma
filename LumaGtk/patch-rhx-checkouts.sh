#!/bin/sh
#
# Patches rhx/Swift* checkouts for compatibility with recent
# Homebrew versions of GLib (2.88+) and GTK (4.22+).
#
# Run after `swift package resolve`:
#   sh patch-rhx-checkouts.sh

set -e

CHECKOUTS="${1:-.build/checkouts}"

# --- Fix gir2swift plugin path resolution ---------------------------------
# The gir2swift build plugin sets -w to the consuming package, but .sed,
# .awk, and .blacklist files live at each Swift* package root. The tool
# only finds them if they're also in the Sources/<Module>/ directory, so
# copy them there.

for pkg_dir in "$CHECKOUTS"/Swift*; do
    [ -d "$pkg_dir" ] || continue
    for f in "$pkg_dir"/*.sed "$pkg_dir"/*.awk "$pkg_dir"/*.blacklist; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        pkg=$(basename "$pkg_dir")
        module=$(echo "$pkg" | sed 's/^Swift//')
        target_dir="$pkg_dir/Sources/$module"
        [ -d "$target_dir" ] || continue
        if [ ! -f "$target_dir/$base" ]; then
            cp "$f" "$target_dir/$base"
            echo "Copied $base → $module/"
        fi
    done
done

# --- SwiftGLib: GLib 2.88 compat ------------------------------------------

GLIB_BH="$CHECKOUTS/SwiftGLib/Sources/CGLib/glib_bridging.h"
if [ -f "$GLIB_BH" ]; then
    if ! grep -q 'G_NSEC_PER_SEC.*guint64' "$GLIB_BH"; then
        echo "Patching $GLIB_BH …"
        sed -i.bak '
/^#include <glib\/gtimer\.h>$/a\
#if GLIB_MAJOR_VERSION == 2 \&\& GLIB_MINOR_VERSION >= 88\
#undef G_NSEC_PER_SEC\
#define G_NSEC_PER_SEC ((guint64) 1000000000)\
#endif
' "$GLIB_BH"

        sed -i.bak '
/^struct _GDtlsServerConnection {};$/a\
\
#if GLIB_MAJOR_VERSION == 2 \&\& GLIB_MINOR_VERSION >= 88\
struct _GIPTosMessage {};\
struct _GIPv6TclassMessage {};\
#endif
' "$GLIB_BH"

        rm -f "$GLIB_BH.bak"
    fi
fi

# --- SwiftGtk: GTK 4.22 compat --------------------------------------------

GTK_BH="$CHECKOUTS/SwiftGtk/Sources/CGtk/gtk_bridging.h"
if [ -f "$GTK_BH" ]; then
    if ! grep -q 'GtkPopoverBin' "$GTK_BH"; then
        echo "Patching $GTK_BH …"
        sed -i.bak '
/^#include <gtk\/gtk\.h>$/a\
\
#if GTK_MAJOR_VERSION == 4 \&\& GTK_MINOR_VERSION >= 22\
struct _GtkAccessibleHyperlink {};\
struct _GtkAccessibleHypertext {};\
struct _GtkPopoverBin {};\
struct _GtkSvg {};\
struct _GtkTryExpression {};\
#undef GTK_SVG_DEFAULT_FEATURES\
#define GTK_SVG_DEFAULT_FEATURES 15\
#endif
' "$GTK_BH"

        rm -f "$GTK_BH.bak"
    fi
fi

GTK_SED="$CHECKOUTS/SwiftGtk/Gtk-4.0.sed"
if [ -f "$GTK_SED" ]; then
    if ! grep -q 'popover_bin_set_popover' "$GTK_SED"; then
        echo "Patching $GTK_SED …"
        cat >> "$GTK_SED" << 'PATCH'
s/gtk_popover_bin_set_popover(\([^,]*\), \([^)]*\)\.popover_ptr)/gtk_popover_bin_set_popover(\1, \2.widget_ptr)/g
s/UnsafeMutablePointer<GtkWidget>(newValue?\.popover_ptr)/newValue?.widget_ptr/g
PATCH
    fi
fi

# --- frida-swift: USE_SYSTEM_FRIDA compat ----------------------------------

for f in \
    "$CHECKOUTS/frida-swift/Frida/SignalConnection.swift" \
    "$CHECKOUTS/frida-swift/Frida/CustomAuthenticationService.swift"; do
    [ -f "$f" ] || continue
    if grep -q 'GConnectFlags(0)\|GTypeFlags(0)' "$f"; then
        echo "Patching $(basename "$f") …"
        sed -i.bak \
            -e 's/GConnectFlags(0)/GConnectFlags(rawValue: 0)/g' \
            -e 's/GTypeFlags(0)/GTypeFlags(rawValue: 0)/g' \
            "$f"
        rm -f "$f.bak"
    fi
done

echo "Done."
