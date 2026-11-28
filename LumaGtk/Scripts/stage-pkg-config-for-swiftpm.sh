#!/bin/sh
set -eu

destination=$1
rm -rf "$destination"
mkdir -p "$destination/.seen"

search_path="${PKG_CONFIG_PATH:+$PKG_CONFIG_PATH:}$(pkg-config --variable=pc_path pkg-config)"

IFS=:
for directory in $search_path; do
    [ "$directory" != "$destination" ] || continue
    for pc in "$directory"/*.pc; do
        [ -f "$pc" ] || continue
        name=${pc##*/}
        [ ! -e "$destination/.seen/$name" ] || continue
        : > "$destination/.seen/$name"
        awk -v pcfiledir="$directory" '
            function allowed(flag, prefixes,   i, count, list) {
                count = split(prefixes, list, " ")
                for (i = 1; i <= count; i++) {
                    if (index(flag, list[i]) == 1)
                        return list[i]
                }
                return ""
            }

            {
                gsub(/\$\{pcfiledir\}/, pcfiledir)
            }

            tolower(substr($0, 1, index($0, ":"))) ~ /^(cflags|libs):$/ {
                key = substr($0, 1, index($0, ":"))
                prefixes = tolower(key) == "cflags:" ? "-I -F" : "-L -l -F -framework -w"
                count = split(substr($0, length(key) + 1), tokens, /[ \t]+/)
                line = key
                for (i = 1; i <= count; i++) {
                    flag = tokens[i]
                    if (flag == "")
                        continue
                    prefix = allowed(flag, prefixes)
                    if (prefix == "" || (prefix == "-w" && flag != "-w")) {
                        dropped = 1
                        continue
                    }
                    line = line " " flag
                    if (flag == prefix && flag != "-w" && i < count)
                        line = line " " tokens[++i]
                }
                $0 = line
            }

            {
                print
            }

            END {
                exit !dropped
            }
        ' "$pc" > "$destination/$name" || rm "$destination/$name"
    done
done

rm -r "$destination/.seen"
