#!/bin/sh
# Prints the next release version as "version=X.Y.Z" (GitHub Actions output format).
#
# - CFBundleShortVersionString in Resources/Info.plist is the floor: bump it (e.g. to 0.2.0 or 1.0.0)
#   to start a new series.
# - Otherwise the patch number of the latest vX.Y.Z tag is incremented (v0.1.0 -> 0.1.1).
set -eu

base=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
latest=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)

if [ -z "$latest" ]; then
    next="$base"
else
    highest=$(printf '%s\n%s\n' "$base" "$latest" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
    if [ "$highest" = "$base" ] && [ "$base" != "$latest" ]; then
        next="$base"
    else
        major=${latest%%.*}
        rest=${latest#*.}
        minor=${rest%%.*}
        patch=${rest#*.}
        next="$major.$minor.$((patch + 1))"
    fi
fi

echo "version=$next"
