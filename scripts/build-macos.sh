#!/usr/bin/env bash
# One command from a clean checkout to recompiled, compiled bean on macOS arm64.
#
#   scripts/build-macos.sh [--clean]
#
# Stages:
#   1. vendor trees at their pinned commits          (scripts/bootstrap.sh)
#   2. overlay trees materialised from vendor+patches (scripts/apply-overlay.sh)
#   3. rexglue codegen CLI built for macOS arm64
#   4. default.xex recompiled to generated/ C++
#   5. every generated translation unit compiled to arm64 objects
#
# Stage 5 is a PROBE, not a link: there is no Apple host backend yet (no window,
# renderer, audio or input), so there is nothing to link into. See DECISIONS.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# See docs/environment-traps.md: CPATH on this machine starts with an empty
# element, which puts the CWD on every include path; the repo-root VERSION file
# then shadows libc++'s <version>. Non-negotiable.
unset CPATH LIBRARY_PATH

GAMEDATA="$REPO_ROOT/work/gamedata/Bean"
BUILD="$REPO_ROOT/build"
SDK_BUILD="$BUILD/rexglue-macos"
GE="$BUILD/overlay/GoldenEye-Recomp"
OUT="$BUILD/overlay/rexglue/out/macos-arm64"

if [ "${1:-}" = "--clean" ]; then
  echo "==> wiping build/"
  rm -rf "$BUILD"
fi

# Family trap: never build while another session is mid-build on this machine.
if pgrep -fl 'Developer/usr/bin/xcodebuild|cmake --build' > /dev/null 2>&1; then
  echo "FATAL: another build is running on this machine:" >&2
  pgrep -fl 'Developer/usr/bin/xcodebuild|cmake --build' >&2
  exit 1
fi

echo "==> 1/5 vendor pins"
"$REPO_ROOT/scripts/bootstrap.sh"

echo "==> 2/5 overlay"
"$REPO_ROOT/scripts/apply-overlay.sh"

echo "==> 3/5 rexglue codegen CLI (macos-arm64)"
cmake -S "$BUILD/overlay/rexglue" -B "$SDK_BUILD" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DREXGLUE_TOOLS_ONLY=ON \
      -DREXGLUE_ENABLE_TRACY=OFF > "$BUILD/cmake-configure.log" 2>&1 \
  || { echo "FATAL: cmake configure failed, see $BUILD/cmake-configure.log" >&2; exit 1; }
ninja -C "$SDK_BUILD" rexglue
"$OUT/rexglue" --version

echo "==> 4/5 recompile default.xex"
[ -f "$GAMEDATA/default.xex" ] || {
  echo "FATAL: no game files at $GAMEDATA" >&2
  echo "       See docs/gamedata.md for the expected layout." >&2
  exit 1
}
mkdir -p "$GE/assets"
for f in "$GAMEDATA"/*; do
  b="$(basename "$f")"
  [ -e "$GE/assets/$b" ] || ln -s "$f" "$GE/assets/$b"
done
( cd "$GE" && DYLD_LIBRARY_PATH="$OUT" "$OUT/rexglue" codegen ge_manifest.toml )

tus=$(find "$GE/generated" -name '*.cpp' | wc -l | tr -d ' ')
lines=$(find "$GE/generated" \( -name '*.cpp' -o -name '*.h' \) -print0 \
        | xargs -0 cat | wc -l | tr -d ' ')
echo "    generated: $tus translation units, $lines lines"

echo "==> 5/6 full runtime + GoldenEye app (macos-arm64)"
cmake -S "$BUILD/overlay/rexglue" -B "$BUILD/rexglue-full" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DREXGLUE_ENABLE_TRACY=OFF > "$BUILD/cmake-full.log" 2>&1 \
  || { echo "FATAL: full-runtime configure failed, see $BUILD/cmake-full.log" >&2; exit 1; }
ninja -C "$BUILD/rexglue-full"

cmake -S "$GE" -B "$BUILD/ge-macos" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DREXSDK_DIR="$BUILD/overlay/rexglue" \
      -DREXGLUE_ENABLE_TRACY=OFF > "$BUILD/cmake-ge.log" 2>&1 \
  || { echo "FATAL: app configure failed, see $BUILD/cmake-ge.log" >&2; exit 1; }
ninja -C "$BUILD/ge-macos" GoldenEye

# The app resolves assets as <exe dir>/assets. Use ONE top-level symlink, not
# per-entry ones: the VFS host-path device does not traverse symlinked
# DIRECTORIES, so per-entry links make everything under assets/files/ invisible
# to the guest (M-015 -- it cost ~95 phantom "missing asset" failures).
rm -f "$BUILD/ge-macos/assets"
[ -e "$BUILD/ge-macos/assets" ] || ln -s "$GAMEDATA" "$BUILD/ge-macos/assets"

echo "==> 6/6 compile probe over the generated tree"
"$REPO_ROOT/scripts/compile-generated-probe.sh"

echo
echo "OK. Recompiler: $OUT/rexglue"
echo "    Generated:  $GE/generated"
echo "    App:        $BUILD/ge-macos/GoldenEye"
echo
echo "Run it with:"
echo "  cd $BUILD/ge-macos && \\"
echo "  DYLD_LIBRARY_PATH=$OUT:/opt/homebrew/lib \\"
echo "  VK_ICD_FILENAMES=/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json \\"
echo "  ./GoldenEye --vulkan_require_geometry_shader=false"
