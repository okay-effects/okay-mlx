#!/bin/sh
# Build the complete Apple Silicon server archive, including MLX, for macOS 14 or later.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
mlx_scala="${MLX_SCALA_SOURCE:-$root/../mlx-scala}"
work="$root/target/macos14"
source="${MLX_C_SOURCE:-$work/src}"
out="$work/out"
package="$root/target/server"

mkdir -p "$work"
if [ ! -d "$source" ]; then
  git clone --depth 1 --branch v0.8.0 https://github.com/ml-explore/mlx-c.git "$source"
fi
cmake -S "$source" -B "$work/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
  -DMLX_C_BUILD_EXAMPLES=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DCMAKE_INSTALL_PREFIX="$out"
cmake --build "$work/build" -j "${MLX_BUILD_JOBS:-4}"
cmake --install "$work/build"
clang -O2 -dynamiclib -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
  "$mlx_scala/native-lib/okm.c" -I "$out/include" -L "$out/lib" -lmlxc \
  -Wl,-rpath,@loader_path -install_name @rpath/libokm.dylib -o "$out/lib/libokm.dylib"
MLX_SCALA_LIB="$out/lib" sbt "appNative/nativeLink"

stage=$(mktemp -d "$work/package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/bin" "$stage/lib" "$package"
cp app/.native/target/scala-*/okay-mlx "$stage/bin/okay-mlx"
cp "$out/lib/"*.dylib "$out/lib/mlx.metallib" "$stage/lib/"
mkdir -p "$stage/lib/licenses"
cp LICENSE "$stage/lib/licenses/okay-mlx.txt"
cp "$source/LICENSE" "$stage/lib/licenses/mlx-c.txt"
for dependency in mlx fmt json gguflib metal_cpp; do
  directory="$work/build/_deps/$dependency-src"
  # FetchContent may reuse sources from another build directory.
  configured=$(sed -n "s|^FETCHCONTENT_SOURCE_DIR_$(printf '%s' "$dependency" | tr '[:lower:]' '[:upper:]'):PATH=||p" \
    "$work/build/CMakeCache.txt")
  if [ -n "$configured" ]; then directory="$configured"; fi
  for license in "$directory"/LICENSE*; do
    if [ -f "$license" ]; then cp "$license" "$stage/lib/licenses/$dependency-$(basename "$license")"; fi
  done
done
# Distribute only relative runtime paths so the archive cannot fall back to the builder's MLX installation.
install_name_tool -delete_rpath "$out/lib" "$stage/bin/okay-mlx"
for binary in "$stage/bin/okay-mlx" "$stage/lib/"*.dylib; do
  codesign --force --sign - "$binary"
done
tar czf "$package/okay-mlx-macos-arm64.tar.gz" -C "$stage" bin lib
(cd "$package" && shasum -a 256 okay-mlx-macos-arm64.tar.gz > SHA256SUMS)
printf '%s\n' "$package/okay-mlx-macos-arm64.tar.gz"
