#!/bin/sh
# Re-vendors Mermaid (rendered in the markdown preview) at a pinned version.
# Usage: scripts/update-mermaid.sh 12.3.0
# npm verifies the tarball against the registry's integrity hash before it's unpacked.
set -eu
VERSION="${1:?usage: scripts/update-mermaid.sh <version>}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && npm pack "mermaid@$VERSION" --silent >/dev/null && tar -xzf "mermaid-$VERSION.tgz")
cp "$TMP/package/dist/mermaid.min.js" Resources/Vendor/mermaid.min.js
cp "$TMP/package/LICENSE" Resources/Vendor/MERMAID-LICENSE
echo "Vendored mermaid $VERSION ($(wc -c < Resources/Vendor/mermaid.min.js | tr -d ' ') bytes)"
