#!/bin/bash
# Builds Reword.app (release configuration) into ./build and signs it.
#
# Environment:
#   REWORD_SIGN_IDENTITY  codesign identity; defaults to the first "Apple Development" identity, else ad-hoc.
#                         A stable identity keeps macOS privacy grants (Accessibility, Screen Recording)
#                         across rebuilds; ad-hoc signatures change every build and make macOS ask again.
#   REWORD_HARDENED=1     hardened runtime + secure timestamp (required for notarization).
#   REWORD_VERSION        CFBundleShortVersionString, e.g. 1.2.0
#   REWORD_BUILD          CFBundleVersion, e.g. a CI run number
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
"$ROOT/scripts/fetch_llama.sh"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="$ROOT/build/Reword.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/Reword" "$APP/Contents/MacOS/Reword"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -n "${REWORD_VERSION:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $REWORD_VERSION" "$APP/Contents/Info.plist"
[ -n "${REWORD_BUILD:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $REWORD_BUILD" "$APP/Contents/Info.plist"
ditto "$ROOT/Vendor/build-apple/llama.xcframework/macos-arm64_x86_64/llama.framework" "$APP/Contents/Frameworks/llama.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Reword" 2>/dev/null || true

IDENTITY="${REWORD_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [ "${REWORD_HARDENED:-0}" = "1" ]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
echo "Signing with: $IDENTITY${REWORD_HARDENED:+ (hardened runtime)}"
# Inside-out: the embedded framework first, then the app.
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/llama.framework"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP"
