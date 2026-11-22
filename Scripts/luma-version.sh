#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

if [ -n "${LUMA_VERSION:-}" ]; then
    echo "$LUMA_VERSION"
    exit 0
fi

next_release=$(tr -d '[:space:]' < "$root/VERSION")
if [[ ! "$next_release" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "Unexpected VERSION: $next_release" >&2
    exit 1
fi
next_release_key=$(printf '%06d%06d%06d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")

description=$(git -C "$root" describe --tags --always --long --match='[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)
if [[ "$description" != *-*-g* ]]; then
    echo "$next_release-dev"
    exit 0
fi

tag="${description%-*-g*}"
rest="${description#"$tag"-}"
distance="${rest%-g*}"
if [[ ! "$tag" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-(.+))?$ ]]; then
    echo "Unexpected tag format: $tag" >&2
    exit 1
fi
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
micro="${BASH_REMATCH[3]}"
suffix="${BASH_REMATCH[5]}"

if [ "$distance" -eq 0 ]; then
    echo "$tag"
elif [[ "$next_release_key" > "$(printf '%06d%06d%06d' "$major" "$minor" "$micro")" ]]; then
    echo "$next_release-dev.$((distance - 1))"
elif [ -n "$suffix" ]; then
    echo "$tag-dev.$((distance - 1))"
else
    echo "$major.$minor.$((micro + 1))-dev.$((distance - 1))"
fi
