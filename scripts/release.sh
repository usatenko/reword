#!/bin/bash
# Builds a Developer ID–signed, notarized and stapled Reword-<version>.dmg in ./dist.
#
# Usage: scripts/release.sh <version>            e.g. scripts/release.sh 1.0.0
#
# Environment:
#   REWORD_SIGN_IDENTITY   defaults to the first "Developer ID Application" identity in the keychain.
#   Notarization (one of):
#     NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID   App Store Connect API key (.p8)  — used in CI
#     NOTARY_PROFILE                                         keychain profile from `xcrun notarytool store-credentials`
#   REQUIRE_NOTARIZATION=1  fail instead of skipping when no notarization credentials are set (CI sets this).
set -euo pipefail
VERSION="${1:?usage: scripts/release.sh <version>}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}([-.][0-9A-Za-z.]+)?$ ]] || { echo "error: invalid version '$VERSION'" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY="${REWORD_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[ -n "$IDENTITY" ] || { echo "error: no Developer ID Application identity found" >&2; exit 1; }

REWORD_SIGN_IDENTITY="$IDENTITY" REWORD_HARDENED=1 REWORD_VERSION="$VERSION" \
    REWORD_BUILD="${GITHUB_RUN_NUMBER:-1}" "$ROOT/scripts/build_app.sh"
APP="$ROOT/build/Reword.app"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"        # captured first: grep -q in a pipe trips pipefail
[[ "$SIGNATURE" == *"flags="*"(runtime)"* ]] || { echo "error: hardened runtime is not enabled" >&2; exit 1; }
[[ "$SIGNATURE" == *"Authority=Developer ID Application"* ]] || { echo "error: app is not Developer ID signed" >&2; exit 1; }

# Disk image with the app and an Applications shortcut.
DIST="$ROOT/dist"
DMG="$DIST/Reword-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$DIST"
rm -f "$DMG"
ditto "$APP" "$STAGE/Reword.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Reword $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

# Notarize the disk image (Apple scans the app inside), then staple the ticket for offline Gatekeeper checks.
NOTARY_ARGS=()
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
    NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
elif [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
fi
if [ ${#NOTARY_ARGS[@]} -gt 0 ]; then
    echo "Notarizing ${DMG}..."
    xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait --timeout 30m
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature -vv "$DMG"
    spctl --assess --type execute -vv "$APP"
elif [ "${REQUIRE_NOTARIZATION:-0}" = "1" ]; then
    echo "error: notarization credentials are not set" >&2
    exit 1
else
    echo "warning: no notarization credentials; $DMG is signed but not notarized" >&2
fi

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Release artifact: $DMG"
cat "$DMG.sha256"
