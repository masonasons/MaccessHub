#!/usr/bin/env bash
#
# release.sh vX.Y.Z — build the signed + notarized DMG, tag the commit, and
# publish a GitHub Release with the DMG attached.
set -euo pipefail

VER="${1:?usage: scripts/release.sh vX.Y.Z}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

[ -z "$(git status --porcelain)" ] || { echo "Working tree is not clean; commit first."; exit 1; }

VERSION="${VER#v}"
DOWNLOAD_URL="https://github.com/masonasons/MaccessHub/releases/download/$VER/"

echo "==> [1/4] Signed macOS DMG"
VERSION="$VERSION" ./scripts/package.sh

echo "==> [2/4] Sparkle appcast"
GEN="$(find build -type f -path '*Sparkle/bin/generate_appcast' | head -1)"
[ -n "$GEN" ] || { echo "generate_appcast not found; resolve the Sparkle package first"; exit 1; }
FEED="$(mktemp -d)"
cp dist/MaccessHub.dmg "$FEED/"
"$GEN" --download-url-prefix "$DOWNLOAD_URL" \
  --link "https://github.com/masonasons/MaccessHub" \
  -o appcast.xml "$FEED"
rm -rf "$FEED"
git add appcast.xml
git commit -q -m "Appcast for $VER" || true
git push -q origin main

echo "==> [3/4] Tagging $VER"
git tag "$VER"
git push origin "$VER"

echo "==> [4/4] GitHub Release $VER"
gh release create "$VER" --title "MaccessHub $VER" --notes \
"\`MaccessHub.dmg\` is signed with Developer ID and notarized: open it and drag MaccessHub to Applications.

On first launch, grant the Accessibility permission when asked (and Input Monitoring if key clicks stay silent). See the README for what each shortcut does. Later versions install themselves through Check for Updates." \
  dist/MaccessHub.dmg

echo; echo "Released: https://github.com/masonasons/MaccessHub/releases/tag/$VER"
