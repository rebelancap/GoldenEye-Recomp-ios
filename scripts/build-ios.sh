#!/usr/bin/env bash
#
# Configure + build the ReXGlue runtime and the GoldenEye app for one Apple
# target platform. This is the script that should always have existed: before
# it, the four iOS build directories were configured by hand and the exact
# invocations survived only in their own CMakeCache.txt files.
#
#   scripts/build-ios.sh <ios|iossim|visionos|visionossim> [--configure-only]
#
# Layout, one set per platform (never shared -- a simulator Mach-O carries a
# different LC_BUILD_VERSION and is not interchangeable with the device one):
#
#   build/rexglue-<plat>   runtime build dir
#   build/ge-<plat>        app build dir  -> GoldenEye.app/GoldenEye
#   build/overlay/rexglue/out/<plat>-arm64/librexruntime.dylib
#
# The <plat> suffix in out/ is chosen by build/overlay/rexglue/CMakeLists.txt
# from CMAKE_SYSTEM_NAME + CMAKE_OSX_SYSROOT; the names below must agree with
# it ("ios", "iossim", "visionos", "visionossim").
#
# Codegen is NOT part of this script: the generated/ tree is architecture
# independent C++ produced once by scripts/build-macos.sh. Run that first on a
# clean checkout.
#
set -euo pipefail

# /etc/zshenv appends to these unconditionally and a leading empty element makes
# the repo-root VERSION file shadow libc++'s <version>. Non-negotiable.
unset CPATH LIBRARY_PATH

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

PLAT="${1:-}"
CONFIGURE_ONLY=0
[[ "${2:-}" == "--configure-only" ]] && CONFIGURE_ONLY=1

case "$PLAT" in
  # visionOS deployment target is 26.0: that is the first xrOS SDK the toolchain
  # here ships and matches the sibling ports (dhewm3 scripts/build-sdl3-ios.sh).
  ios)          SYSTEM=iOS       SYSROOT=iphoneos      DEPLOY=16.0 ;;
  iossim)       SYSTEM=iOS       SYSROOT=iphonesimulator DEPLOY=16.0 ;;
  visionos)     SYSTEM=visionOS  SYSROOT=xros          DEPLOY=26.0 ;;
  visionossim)  SYSTEM=visionOS  SYSROOT=xrsimulator   DEPLOY=26.0 ;;
  *) echo "usage: $0 <ios|iossim|visionos|visionossim> [--configure-only]" >&2; exit 1 ;;
esac

RUNTIME_DIR="$REPO/build/rexglue-$PLAT"
APP_DIR="$REPO/build/ge-$PLAT"
SDK_SRC="$REPO/build/overlay/rexglue"
GE_SRC="$REPO/build/overlay/GoldenEye-Recomp"
OUT="$SDK_SRC/out/$PLAT-arm64"

[[ -d "$SDK_SRC" ]] || { echo "FATAL: no overlay tree at $SDK_SRC -- run scripts/apply-overlay.sh" >&2; exit 1; }
[[ -d "$GE_SRC/generated" ]] || { echo "FATAL: no generated/ tree -- run scripts/build-macos.sh first" >&2; exit 1; }

# Family trap: never build while another session is mid-build on this machine.
if pgrep -fl 'Developer/usr/bin/xcodebuild|cmake --build' > /dev/null 2>&1; then
  echo "FATAL: another build is running on this machine:" >&2
  pgrep -fl 'Developer/usr/bin/xcodebuild|cmake --build' >&2
  exit 1
fi

# Shared across both configures. REXGLUE_HOST_TOOLS_OFF drops the codegen CLI
# and every host-only tool (they cannot cross-compile and are not needed:
# generated/ already exists). REXGLUE_USE_VULKAN is the only backend that
# exists on Apple -- MoltenVK provides it (D-009).
# PUBLIC=1 builds the release flavour: the :8773 console bridge is compiled out
# (it is a dev-only remote control and must never ship in a GitHub asset). The
# OTA/dev builds keep it ON. make-ipa.sh re-checks the binary either way.
BRIDGE=ON
if [[ "${PUBLIC:-0}" == "1" ]]; then BRIDGE=OFF; fi
echo "==> [$PLAT] console bridge: $BRIDGE (PUBLIC=${PUBLIC:-0})"
COMMON=(
  -G Ninja
  -DCMAKE_SYSTEM_NAME="$SYSTEM"
  -DCMAKE_OSX_SYSROOT="$SYSROOT"
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY"
  -DCMAKE_BUILD_TYPE=Release
  -DREXGLUE_HOST_TOOLS_OFF=ON
  -DREXGLUE_USE_VULKAN=ON
  -DREXGLUE_ENABLE_TRACY=OFF
  -DREXGLUE_ENABLE_PERF_COUNTERS=ON
  -DREXGLUE_BUILD_TESTS=OFF
  # The :8773 driveability bridge. On in every OTA build; compiled out of a
  # public release build only (charter, Delivery).
  -DREX_CONSOLE_BRIDGE="$BRIDGE"
)

echo "==> [$PLAT] configuring runtime  ($SYSTEM / $SYSROOT / min $DEPLOY)"
cmake -S "$SDK_SRC" -B "$RUNTIME_DIR" "${COMMON[@]}" \
      > "$REPO/build/cmake-rexglue-$PLAT.log" 2>&1 \
  || { echo "FATAL: runtime configure failed, see build/cmake-rexglue-$PLAT.log" >&2
       tail -30 "$REPO/build/cmake-rexglue-$PLAT.log" >&2; exit 1; }

echo "==> [$PLAT] configuring app"
cmake -S "$GE_SRC" -B "$APP_DIR" "${COMMON[@]}" \
      -DREXSDK_DIR="$SDK_SRC" \
      > "$REPO/build/cmake-ge-$PLAT.log" 2>&1 \
  || { echo "FATAL: app configure failed, see build/cmake-ge-$PLAT.log" >&2
       tail -30 "$REPO/build/cmake-ge-$PLAT.log" >&2; exit 1; }

if (( CONFIGURE_ONLY )); then
  echo "OK (configure only). $RUNTIME_DIR  $APP_DIR"
  exit 0
fi

echo "==> [$PLAT] building runtime"
ninja -C "$RUNTIME_DIR" rexruntime

echo "==> [$PLAT] building app"
ninja -C "$APP_DIR"

# Assert the artefacts rather than trust the exit code: a stale out/ dir from a
# different platform is exactly the failure this script exists to prevent.
RUNTIME_LIB="$OUT/librexruntime.dylib"
APP_EXE="$APP_DIR/GoldenEye.app/GoldenEye"
for f in "$RUNTIME_LIB" "$APP_EXE"; do
  [[ -f "$f" ]] || { echo "FATAL: expected artefact missing: $f" >&2; exit 1; }
done

echo
echo "OK [$PLAT]"
for f in "$RUNTIME_LIB" "$APP_EXE"; do
  printf '    %s\n        %s\n' "$f" \
    "$(vtool -show-build "$f" 2>/dev/null | awk '/platform|minos|sdk/{printf "%s=%s ", $1, $2}')"
done
