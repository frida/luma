#!/bin/sh
set -eu

destination=$1
staging=$destination.new
rm -rf "$staging"
mkdir -p "$destination" "$staging/.seen"

search_path="${PKG_CONFIG_PATH:+$PKG_CONFIG_PATH:}$(pkg-config --variable=pc_path pkg-config)"

IFS=:
for directory in $search_path; do
    [ "$directory" != "$destination" ] && [ "$directory" != "$staging" ] || continue
    for pc in "$directory"/*.pc; do
        [ -f "$pc" ] || continue
        name=${pc##*/}
        [ ! -e "$staging/.seen/$name" ] || continue
        : > "$staging/.seen/$name"
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
        ' "$pc" > "$staging/$name" || rm "$staging/$name"
    done
done

for copy in "$destination"/*.pc; do
    [ -f "$copy" ] || continue
    [ -e "$staging/${copy##*/}" ] || rm "$copy"
done
for staged in "$staging"/*.pc; do
    [ -f "$staged" ] || continue
    cmp -s "$staged" "$destination/${staged##*/}" || mv "$staged" "$destination/"
done
rm -rf "$staging"
