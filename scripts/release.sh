#!/usr/bin/env bash
#
# release.sh vX.Y.Z — build the signed + notarized DMG, tag the commit, and
# publish a GitHub Release with the DMG attached.
set -euo pipefail

VER="${1:?usage: scripts/release.sh vX.Y.Z}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

[ -z "$(git status --porcelain)" ] || { echo "Working tree is not clean; commit first."; exit 1; }

echo "==> [1/3] Signed macOS DMG"
./scripts/package.sh

echo "==> [2/3] Tagging $VER"
git tag "$VER"
git push origin "$VER"

echo "==> [3/3] GitHub Release $VER"
gh release create "$VER" --title "MaccessHub $VER" --notes \
"\`MaccessHub.dmg\` is signed with Developer ID and notarized: open it and drag MaccessHub to Applications.

On first launch, grant the Accessibility permission when asked (and Input Monitoring if key clicks stay silent). See the README for what each shortcut does." \
  dist/MaccessHub.dmg

echo; echo "Released: https://github.com/masonasons/MaccessHub/releases/tag/$VER"
