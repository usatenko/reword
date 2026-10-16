#!/bin/bash
# Downloads the prebuilt llama.cpp XCFramework that Package.swift links against (checksum-verified).
set -euo pipefail
TAG=b11655
SHA256=10d493b202c36e1d121ec19f28a816b637d50592485d5b81a7c9a11e5d54d0ce
VENDOR="$(cd "$(dirname "$0")/.." && pwd)/Vendor"
mkdir -p "$VENDOR"
cd "$VENDOR"
[ -f build-apple/.verified-$TAG ] && { echo "llama.xcframework $TAG already present"; exit 0; }
ZIP="llama-$TAG-xcframework.zip"
[ -f "$ZIP" ] || curl -fL --proto '=https' --tlsv1.2 -o "$ZIP.part" \
    "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/$ZIP" && { [ -f "$ZIP" ] || mv "$ZIP.part" "$ZIP"; }
echo "$SHA256  $ZIP" | shasum -a 256 -c - || { rm -f "$ZIP"; exit 1; }
# Extract next to the final location and swap it in, so a partial extraction is never used.
TMP="$(mktemp -d "$VENDOR/extract.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
unzip -q "$ZIP" -d "$TMP"
rm -rf build-apple
mv "$TMP/build-apple" build-apple
touch "build-apple/.verified-$TAG"
