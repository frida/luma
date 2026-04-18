#!/usr/bin/env python3
"""Produce a patched copy of Adw-1.gir for libadwaita < 1.6.

Ubuntu 24.04 (and thus snap core24) ships libadwaita 1.5.x, whose
Adw-1.gir incorrectly declares the return types of four property
getters as ``gboolean`` when they are actually ``int``:

    * adw_action_row_get_subtitle_lines
    * adw_action_row_get_title_lines
    * adw_expander_row_get_subtitle_lines
    * adw_expander_row_get_title_lines

libadwaita 1.6 ships the corrected introspection metadata.

When gir2swift consumes the buggy .gir, it generates a computed
property typed ``Bool`` whose setter calls ``gint(newValue)``, which
fails to compile. This script writes a corrected Adw-1.gir to a
caller-provided directory. The caller should then point
``GIR_EXTRA_SEARCH_PATH`` at that directory so gir2swift picks it up
before the system copy.

Usage: patch-libadwaita-gir.py <source-gir> <destination-directory>
"""
import re
import shutil
import sys
from pathlib import Path


BUGGY_GETTERS = (
    "adw_action_row_get_subtitle_lines",
    "adw_action_row_get_title_lines",
    "adw_expander_row_get_subtitle_lines",
    "adw_expander_row_get_title_lines",
)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 1

    src = Path(sys.argv[1])
    dst_dir = Path(sys.argv[2])
    dst_dir.mkdir(parents=True, exist_ok=True)
    dst = dst_dir / src.name

    text = src.read_text()
    for ident in BUGGY_GETTERS:
        pattern = re.compile(
            r'(c:identifier="' + re.escape(ident) + r'".*?<return-value[^>]*>.*?<type name=")gboolean(" c:type=")gboolean("/>.*?</return-value>)',
            re.DOTALL,
        )
        text, n = pattern.subn(r"\1gint\2gint\3", text)
        if n != 1:
            print(f"warning: {ident}: expected 1 replacement, got {n}", file=sys.stderr)

    dst.write_text(text)

    # Keep any sibling .typelib / doc files co-located so gir2swift sees
    # a self-contained directory, even though it only reads the .gir.
    return 0


if __name__ == "__main__":
    sys.exit(main())
