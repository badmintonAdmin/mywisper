#!/bin/bash
# Bundle whisper-cli + its dylibs into a directory so the binary is self-contained
# (no dependency on ~/Downloads/whisper.cpp or absolute build paths).
#
# Usage: bundle_whisper.sh <dest_dir> <whisper_cpp_build_dir> [codesign_identity] [arch]
#   dest_dir              where whisper-cli + dylibs should live (e.g. App/Contents/Resources)
#   whisper_cpp_build_dir whisper.cpp CMake build dir (contains bin/ and ggml/src/)
#   codesign_identity     optional; "-" for ad-hoc (default), or a Developer ID
#   arch                  optional; arm64 (default) or x86_64. x86_64 has no Metal dylib.
#
# After running, whisper-cli loads all its libraries via @loader_path (the dest dir),
# so the whole set can be dropped anywhere and still run.
set -euo pipefail

DEST="${1:?dest dir required}"
BUILD="${2:?whisper.cpp build dir required}"
IDENTITY="${3:--}"
ARCH="${4:-arm64}"

CLI="$BUILD/bin/whisper-cli"
[ -f "$CLI" ] || { echo "ERROR: whisper-cli not found at $CLI"; exit 1; }

# The dylibs whisper-cli (and its libs) need, by soname. All live in the build tree.
DYLIBS=(
  "src/libwhisper.1.dylib"
  "ggml/src/libggml.0.dylib"
  "ggml/src/libggml-base.0.dylib"
  "ggml/src/libggml-cpu.0.dylib"
  "ggml/src/ggml-blas/libggml-blas.0.dylib"
)
# Metal backend is built only for arm64 (Apple Silicon).
if [ "$ARCH" = "arm64" ]; then
  DYLIBS+=("ggml/src/ggml-metal/libggml-metal.0.dylib")
fi

mkdir -p "$DEST"

# Clean any whisper artifacts from a previous (possibly different-arch) bundle so stale
# dylibs — e.g. an arm64 libggml-metal left over when re-bundling for x86_64 — don't linger.
echo "  [bundle] cleaning previous whisper artifacts in $DEST"
rm -f "$DEST/whisper-cli" "$DEST"/libwhisper*.dylib "$DEST"/libggml*.dylib

echo "  [bundle] copying whisper-cli + dylibs into $DEST"
cp -f "$CLI" "$DEST/whisper-cli"
chmod +x "$DEST/whisper-cli"

for rel in "${DYLIBS[@]}"; do
  src="$BUILD/$rel"
  name="$(basename "$rel")"
  # Resolve through symlinks to the real Mach-O file, but keep the soname as the filename.
  real="$(readlink -f "$src" 2>/dev/null || python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$src")"
  [ -f "$real" ] || { echo "ERROR: dylib not found: $src"; exit 1; }
  cp -f "$real" "$DEST/$name"
  chmod +w "$DEST/$name"
done

# Strip the stale absolute LC_RPATHs (point at the original build tree) and add @loader_path,
# so every @rpath/lib*.dylib reference resolves to a sibling in DEST.
relink() {
  local f="$1"
  # Remove any rpath that isn't already @loader_path.
  while read -r rp; do
    [ -z "$rp" ] && continue
    [ "$rp" = "@loader_path" ] && continue
    install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true
  done < <(otool -l "$f" | awk '/LC_RPATH/{getline;getline; print $2}')
  # Ensure @loader_path is present exactly once.
  if ! otool -l "$f" | awk '/LC_RPATH/{getline;getline; print $2}' | grep -qx "@loader_path"; then
    install_name_tool -add_rpath "@loader_path" "$f"
  fi
}

echo "  [bundle] rewriting rpaths -> @loader_path"
relink "$DEST/whisper-cli"
for rel in "${DYLIBS[@]}"; do
  relink "$DEST/$(basename "$rel")"
done

echo "  [bundle] codesigning (identity: $IDENTITY)"
for rel in "${DYLIBS[@]}"; do
  codesign --force --timestamp=none -s "$IDENTITY" "$DEST/$(basename "$rel")" 2>/dev/null
done
codesign --force --timestamp=none -s "$IDENTITY" "$DEST/whisper-cli" 2>/dev/null

echo "  [bundle] done"
