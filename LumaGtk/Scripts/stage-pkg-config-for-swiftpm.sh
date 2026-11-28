#!/bin/sh
set -eu

destination=$1
staging=$destination.new
rm -rf "$staging"
mkdir -p "$destination" "$staging"

search_path="${PKG_CONFIG_PATH:+$PKG_CONFIG_PATH:}$(pkg-config --variable=pc_path pkg-config)"

set --
IFS=:
for directory in $search_path; do
    [ "$directory" != "$destination" ] || continue
    for pc in "$directory"/*.pc; do
        [ -f "$pc" ] && set -- "$@" "$directory"/*.pc
        break
    done
done
unset IFS

[ $# -eq 0 ] || awk -v staging="$staging" '
    function allowed(flag, prefixes,   i, count, list) {
        count = split(prefixes, list, " ")
        for (i = 1; i <= count; i++) {
            if (index(flag, list[i]) == 1)
                return list[i]
        }
        return ""
    }

    function sanitized(line,   key, prefixes, count, tokens, i, flag, prefix, result) {
        key = substr(line, 1, index(line, ":"))
        if (tolower(key) !~ /^(cflags|libs):$/)
            return line
        prefixes = tolower(key) == "cflags:" ? "-I -F" : "-L -l -F -framework -w"
        count = split(substr(line, length(key) + 1), tokens, /[ \t]+/)
        result = key
        for (i = 1; i <= count; i++) {
            flag = tokens[i]
            if (flag == "")
                continue
            prefix = allowed(flag, prefixes)
            if (prefix == "" || (prefix == "-w" && flag != "-w")) {
                dropped = 1
                continue
            }
            result = result " " flag
            if (flag == prefix && flag != "-w" && i < count)
                result = result " " tokens[++i]
        }
        return result
    }

    function flush(   i, path) {
        if (dropped) {
            path = staging "/" name
            for (i = 1; i <= lines; i++)
                print buffered[i] > path
            close(path)
        }
        lines = 0
        dropped = 0
    }

    FNR == 1 {
        flush()
        name = FILENAME
        sub(/.*\//, "", name)
        directory = substr(FILENAME, 1, length(FILENAME) - length(name) - 1)
        skipping = name in seen
        seen[name] = 1
    }

    skipping {
        next
    }

    {
        line = $0
        gsub(/\$\{pcfiledir\}/, directory, line)
        buffered[++lines] = sanitized(line)
    }

    END {
        flush()
    }
' "$@"

for copy in "$destination"/*.pc; do
    [ -f "$copy" ] || continue
    [ -e "$staging/${copy##*/}" ] || rm "$copy"
done
for staged in "$staging"/*.pc; do
    [ -f "$staged" ] || continue
    cmp -s "$staged" "$destination/${staged##*/}" || mv "$staged" "$destination/"
done
rm -rf "$staging"
