#!/bin/bash
# Clone and build whisper.cpp natively for Apple Silicon (arm64, Metal embedded).
# Produces a self-contained set of binaries that bundle_whisper.sh copies into the app.
#
# Usage: build_whisper.sh [build_root]
#   build_root  where to clone/build whisper.cpp (default: <project>/build/whisper.cpp)
# Prints the CMake build dir (…/build) on the last line.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

SRC="${1:-$PROJECT_DIR/build/whisper.cpp}"
BUILD="$SRC/build"
WHISPER_REF="${WHISPER_REF:-v1.8.5}"   # pin so bundle_whisper.sh's dylib list stays valid
XCODE_DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "[whisper] using Xcode at $XCODE_DEV" >&2

if [ ! -d "$SRC/.git" ]; then
  echo "[whisper] cloning whisper.cpp @ $WHISPER_REF" >&2
  rm -rf "$SRC"
  git clone --depth 1 --branch "$WHISPER_REF" https://github.com/ggerganov/whisper.cpp.git "$SRC" >&2
fi

if [ ! -f "$BUILD/bin/whisper-cli" ]; then
  echo "[whisper] configuring (arm64, Metal embedded, generic CPU)" >&2
  DEVELOPER_DIR="$XCODE_DEV" cmake -B "$BUILD" -S "$SRC" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_NATIVE=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF >&2
  echo "[whisper] building" >&2
  DEVELOPER_DIR="$XCODE_DEV" cmake --build "$BUILD" --config Release -j >&2
fi

echo "[whisper] ready: $BUILD/bin/whisper-cli" >&2
echo "$BUILD"
