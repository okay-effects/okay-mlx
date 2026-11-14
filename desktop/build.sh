#!/bin/sh
set -eu
cd "$(dirname "$0")"
out="$(pwd)/../target/desktop"
app="$out/okay-mlx.app"

mkdir -p "$out"
stage=$(mktemp -d "$out/build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/okay-mlx.app"
mkdir -p "$bundle/Contents/MacOS"
cp Info.plist "$bundle/Contents/Info.plist"
ditto Resources "$bundle/Contents/Resources"
cp ../LICENSE "$bundle/Contents/Resources/LICENSE"
xcrun swiftc -swift-version 6 -target arm64-apple-macosx14.0 -O \
    Service.swift ModelCache.swift Installation.swift InstallView.swift Resources.swift Library.swift Admin.swift \
    Clients.swift ModelsView.swift ClientsView.swift OkayMLX.swift \
    -o "$bundle/Contents/MacOS/OkayMLX"
codesign --force --sign - "$bundle"
ditto "$bundle" "$app"
printf '%s\n' "$app"
