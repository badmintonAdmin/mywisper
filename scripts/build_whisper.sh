#!/bin/bash
# Clone and build whisper.cpp natively for a given macOS arch.
#   arm64  → Metal embedded (GPU) + generic CPU
#   x86_64 → CPU + Accelerate, no Metal (Intel Macs don't run whisper.cpp's Metal backend)
# Produces a self-contained set of binaries that bundle_whisper.sh copies into the app.
#
# Usage: build_whisper.sh [build_root]
#   build_root         where to clone whisper.cpp (default: <project>/build/whisper.cpp)
#   ARCH=arm64|x86_64  (env) target architecture (default: arm64)
# Prints the per-arch CMake build dir (…/build-<arch>) on the last line.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

SRC="${1:-$PROJECT_DIR/build/whisper.cpp}"
ARCH="${ARCH:-arm64}"
BUILD="$SRC/build-$ARCH"                # per-arch build dir so arm64/x86_64 don't collide
WHISPER_REF="${WHISPER_REF:-v1.8.5}"   # pin so bundle_whisper.sh's dylib list stays valid
XCODE_DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "[whisper] using Xcode at $XCODE_DEV (arch: $ARCH)" >&2

if [ ! -d "$SRC/.git" ]; then
  echo "[whisper] cloning whisper.cpp @ $WHISPER_REF" >&2
  rm -rf "$SRC"
  git clone --depth 1 --branch "$WHISPER_REF" https://github.com/ggerganov/whisper.cpp.git "$SRC" >&2
fi

# Metal is arm64-only here; Intel builds fall back to CPU + Accelerate.
if [ "$ARCH" = "arm64" ]; then
  METAL_FLAGS=(-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
  echo "[whisper] configuring (arm64, Metal embedded, generic CPU)" >&2
else
  METAL_FLAGS=(-DGGML_METAL=OFF)
  echo "[whisper] configuring ($ARCH, CPU + Accelerate, no Metal)" >&2
fi

if [ ! -f "$BUILD/bin/whisper-cli" ]; then
  DEVELOPER_DIR="$XCODE_DEV" cmake -B "$BUILD" -S "$SRC" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_NATIVE=OFF \
    "${METAL_FLAGS[@]}" \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF >&2
  echo "[whisper] building" >&2
  DEVELOPER_DIR="$XCODE_DEV" cmake --build "$BUILD" --config Release -j >&2
fi

echo "[whisper] ready: $BUILD/bin/whisper-cli" >&2
echo "$BUILD"
