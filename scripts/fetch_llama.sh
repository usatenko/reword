#!/bin/bash
# Downloads the prebuilt llama.cpp XCFramework that Package.swift links against.
set -euo pipefail
TAG=b11655
SHA256=10d493b202c36e1d121ec19f28a816b637d50592485d5b81a7c9a11e5d54d0ce
cd "$(dirname "$0")/../Vendor" 2>/dev/null || { mkdir -p "$(dirname "$0")/../Vendor"; cd "$(dirname "$0")/../Vendor"; }
[ -d build-apple/llama.xcframework ] && { echo "llama.xcframework already present"; exit 0; }
curl -fL -o "llama-$TAG-xcframework.zip" "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-xcframework.zip"
echo "$SHA256  llama-$TAG-xcframework.zip" | shasum -a 256 -c -
unzip -q -o "llama-$TAG-xcframework.zip"
