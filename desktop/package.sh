#!/bin/sh
set -eu
cd "$(dirname "$0")"
./build.sh
out="$(pwd)/../target/desktop"
archive="$out/okay-mlx-desktop-macos-arm64.zip"
stage=$(mktemp -d "$out/package.XXXXXX")
trap 'rmdir "$stage"' EXIT

ditto -c -k --keepParent "$out/okay-mlx.app" "$stage/okay-mlx-desktop-macos-arm64.zip"
mv "$stage/okay-mlx-desktop-macos-arm64.zip" "$archive"
(cd "$out" && shasum -a 256 okay-mlx-desktop-macos-arm64.zip > SHA256SUMS)
printf '%s\n' "$archive"
