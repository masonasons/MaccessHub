#!/usr/bin/env bash
#
# package.sh — build MaccessHub (Release) and package it into dist/MaccessHub.dmg.
#
# With a "Developer ID Application" identity in the keychain the app is signed
# with the hardened runtime, the DMG is signed, and — when an ASC API key env
# file is available — the DMG is notarized and stapled so it opens cleanly on
# any Mac. Otherwise an unsigned DMG is produced.
#
# Optional overrides:
#   DEVID_IDENTITY  "Developer ID Application: … (TEAMID)"   (auto-detected)
#   ASC_ENV         path to a file exporting ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER
#                   (default: Signing/asc.env here, else ../DECTalkApple/Signing/asc.env)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
APP=MaccessHub
PROJ="$APP.xcodeproj"
DIST="$HERE/dist"
ENT="Sources/$APP/$APP.entitlements"
ASC_ENV="${ASC_ENV:-}"
if [ -z "$ASC_ENV" ]; then
  for candidate in "$HERE/Signing/asc.env" "$HERE/../DECTalkApple/Signing/asc.env"; do
    [ -f "$candidate" ] && ASC_ENV="$candidate" && break
  done
fi

command -v xcodegen >/dev/null || { echo "xcodegen not found (brew install xcodegen)"; exit 1; }
xcodegen generate >/dev/null
mkdir -p "$DIST"

DEVID="${DEVID_IDENTITY:-}"
if [ -z "$DEVID" ]; then
  DEVID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
fi

echo "==> Building $APP (Release)"
xcodebuild -project "$PROJ" -scheme "$APP" -configuration Release \
  -derivedDataPath build/pkg \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" build >/dev/null
BUNDLE="build/pkg/Build/Products/Release/$APP.app"

if [ -n "$DEVID" ]; then
  echo "==> Signing with Developer ID + hardened runtime ($DEVID)"
  codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$DEVID" "$BUNDLE"
  codesign --verify --deep --strict --verbose=1 "$BUNDLE" 2>&1 | tail -1
else
  echo "==> No Developer ID identity found — building an UNSIGNED DMG"
fi

echo "==> Creating DMG"
STAGE="$(mktemp -d)"
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DIST/$APP.dmg"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$APP.dmg" >/dev/null
rm -rf "$STAGE"

if [ -n "$DEVID" ]; then
  codesign --force --timestamp --sign "$DEVID" "$DIST/$APP.dmg"
  if [ -n "$ASC_ENV" ] && [ -f "$ASC_ENV" ]; then
    # shellcheck disable=SC1090
    source "$ASC_ENV"
    echo "==> Notarizing DMG (can take a few minutes)…"
    xcrun notarytool submit "$DIST/$APP.dmg" \
      --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait
    xcrun stapler staple "$DIST/$APP.dmg"
    echo "==> Notarized + stapled."
  else
    echo "==> Signed with Developer ID but NOT notarized (no ASC env file)."
  fi
fi

echo; ls -lh "$DIST/$APP.dmg"
