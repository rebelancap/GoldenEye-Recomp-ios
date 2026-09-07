#!/usr/bin/env bash
#
# Assemble, sign and package the iOS app into an installable IPA.
#
# CMake owns the build (2.18M generated sources make an xcodegen project
# impractical -- see DECISIONS.md), so this script does what `xcodebuild
# archive` would otherwise do: lay out the bundle, embed and re-path the
# dynamic libraries, drop in the provisioning profile, and codesign.
#
# Usage: scripts/make-ipa.sh [--sim|--visionos|--visionos-sim]
#          (default)        iOS device        -> dist/goldeneye-xbla-<version>-iOS.ipa
#          --sim            iOS simulator     -> dist/sim/Payload/GoldenEye.app (ad-hoc)
#          --visionos       visionOS device   -> dist/goldeneye-xbla-<version>-visionOS.ipa
#          --visionos-sim   visionOS simulator-> dist/visionos-sim/Payload/... (ad-hoc)
#
# The visionOS bundle is NOT the iOS bundle with a different slice in it: it
# carries UIDeviceFamily 7, a UIApplicationSceneManifest, a layered-imagestack
# icon compiled into Assets.car, and none of the iPhone-only keys (see D-024).
#
set -euo pipefail

# Hermetic: /etc/zshenv appends to these unconditionally and a leading empty
# element makes the repo-root VERSION file shadow libc++'s <version>.
unset CPATH LIBRARY_PATH

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# SIM        -> ad-hoc signed .app for a simulator, no IPA
# VISION     -> visionOS bundle shape (device family 7, scene manifest, imagestack)
SIM=0
VISION=0
case "${1:-}" in
  "")             ;;
  --sim)          SIM=1 ;;
  --visionos)     VISION=1 ;;
  --visionos-sim) VISION=1; SIM=1 ;;
  *) echo "usage: $0 [--sim|--visionos|--visionos-sim]" >&2; exit 1 ;;
esac

# Signing identity. Nothing personal lives in this script: set DEV_TEAM and
# CODESIGN_IDENTITY in the environment, or put them in scripts/signing.local.sh
# (gitignored), e.g.
#   DEV_TEAM=ABCDE12345
#   CODESIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"
[[ -f "$REPO/scripts/signing.local.sh" ]] && source "$REPO/scripts/signing.local.sh"
TEAM="${DEV_TEAM:?set DEV_TEAM (your Apple Developer Team ID) or create scripts/signing.local.sh}"
BUNDLE_ID="com.rebelancap.goldeneye"
IDENTITY="${CODESIGN_IDENTITY:?set CODESIGN_IDENTITY (e.g. 'Apple Development: Your Name (XXXXXXXXXX)') or create scripts/signing.local.sh}"

VERSION="$(cat VERSION)"
DEV_ITERATION="$(cat DEV_ITERATION)"
# Program versioning rule (~/dev/CLAUDE.md): the hub version is the plain base
# when DEV_ITERATION is 0, and base.N otherwise. CFBundleShortVersionString is
# the string SideStore compares, so it carries the same value.
if [[ "$DEV_ITERATION" == "0" ]]; then
  SHORT_VERSION="$VERSION"
else
  SHORT_VERSION="$VERSION.$DEV_ITERATION"
fi
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

# MoltenVK 1.4.2 ships all four slices we need in one xcframework; picking the
# wrong PLATFORM_DIR produces a bundle that installs and then fails to dlopen.
if (( VISION )); then
  if (( SIM )); then
    PLAT=visionossim; PLATFORM_DIR="xros-arm64_x86_64-simulator"; STAGE="$REPO/dist/visionos-sim"
  else
    PLAT=visionos;    PLATFORM_DIR="xros-arm64";                  STAGE="$REPO/dist/visionos-stage"
  fi
else
  if (( SIM )); then
    PLAT=iossim; PLATFORM_DIR="ios-arm64_x86_64-simulator"; STAGE="$REPO/dist/sim"
  else
    PLAT=ios;    PLATFORM_DIR="ios-arm64";                  STAGE="$REPO/dist/stage"
  fi
fi
BUILD_DIR="build/ge-$PLAT"
OUT_DIR="build/overlay/rexglue/out/$PLAT-arm64"

EXE="$BUILD_DIR/GoldenEye.app/GoldenEye"
RUNTIME="$OUT_DIR/librexruntime.dylib"
MVK="work/moltenvk/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/$PLATFORM_DIR/MoltenVK.framework/MoltenVK"

for f in "$EXE" "$RUNTIME" "$MVK"; do
  [[ -f "$f" ]] || { echo "FATAL: missing build input: $f" >&2; exit 1; }
done

APP="$STAGE/Payload/GoldenEye.app"
rm -rf "$STAGE"
mkdir -p "$APP/Frameworks"

echo "==> Assembling GoldenEye.app ($SHORT_VERSION build $BUILD_NUMBER)"
cp "$EXE" "$APP/GoldenEye"
cp "$RUNTIME" "$APP/Frameworks/librexruntime.dylib"
# The runtime dlopen()s "@rpath/libMoltenVK.dylib" (rex/platform/dynlib.h), so
# the framework binary is embedded under that plain dylib name rather than as a
# .framework. Sideloaded apps may embed bare dylibs; we already do for the
# runtime itself.
cp "$MVK" "$APP/Frameworks/libMoltenVK.dylib"

echo "==> Re-pathing dynamic libraries"
# The executable was linked with an absolute rpath into the build tree. Replace
# it with the bundle-relative one or nothing resolves once installed.
OLD_RPATH="$(otool -l "$APP/GoldenEye" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; exit}')"
if [[ -n "$OLD_RPATH" ]]; then
  install_name_tool -delete_rpath "$OLD_RPATH" "$APP/GoldenEye"
fi
install_name_tool -add_rpath "@executable_path/Frameworks" "$APP/GoldenEye"

install_name_tool -id "@rpath/librexruntime.dylib" "$APP/Frameworks/librexruntime.dylib"
install_name_tool -id "@rpath/libMoltenVK.dylib"   "$APP/Frameworks/libMoltenVK.dylib"
# dlopen("@rpath/...") resolves against the LC_RPATHs of both the main
# executable and the calling image. The runtime is the caller and shipped with
# none at all, so give it one relative to its own location.
install_name_tool -add_rpath "@loader_path" "$APP/Frameworks/librexruntime.dylib"

if (( VISION )); then

echo "==> Writing Info.plist (visionOS)"
# Deliberately NOT the iOS plist with keys added: four of the iOS keys are
# wrong here (LSRequiresIPhoneOS, UIRequiresFullScreen, the orientation lists,
# CADisableMinimumFrameDurationOnPhone -- an iPhone ProMotion gate), and two
# keys below would be wrong on iOS. See the charter, Phase 5.
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>GoldenEye</string>
  <key>CFBundleExecutable</key><string>GoldenEye</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>GoldenEye</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>MinimumOSVersion</key><string>26.0</string>
  <!-- 7 == vision. Not 1,2: an iPhone/iPad family here makes the app install
       as a compatible iPad app in a 2D shim instead of as a native one. -->
  <key>UIDeviceFamily</key><array><integer>7</integer></array>
  <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string><string>metal</string></array>
  <key>UILaunchScreen</key><dict><key>UIColorName</key><string></string></dict>
  <!-- UIApplicationSupportsMultipleScenes MUST be INSIDE the scene manifest.
       Outside it, it is silently ignored and the app gets a single-scene
       lifecycle it never asked for. -->
  <key>UIApplicationSceneManifest</key>
  <dict>
    <key>UIApplicationSupportsMultipleScenes</key><true/>
  </dict>
  <!-- Required for the app to receive pinch/gaze and indirect pad input. -->
  <key>UIApplicationSupportsIndirectInputEvents</key><true/>
  <key>UIFileSharingEnabled</key><true/>
  <key>LSSupportsOpeningDocumentsInPlace</key><true/>
  <!-- actool owns CFBundleIcons on visionOS, but the NAME still has to be
       declared or SpringBoard shows the blank placeholder. -->
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
      <key>CFBundleURLSchemes</key><array><string>goldeneye</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "==> Compiling the layered app icon"
# visionOS icons are a three-layer imagestack, not a flat PNG: the system
# parallaxes Front over Middle over Back as the user's gaze moves. The catalog
# is generated here rather than committed so no binaries live in the repo --
# every layer comes from vendor/GoldenEye-Recomp/Icon.ico.
ICON_SRC="$REPO/vendor/GoldenEye-Recomp/Icon.ico"
XCA="$STAGE/Assets-visionos.xcassets"
rm -rf "$XCA"
printf '{ "info" : { "author" : "gedev", "version" : 1 } }\n' > /dev/null
mkdir -p "$XCA"
echo '{ "info" : { "author" : "gedev", "version" : 1 } }' > "$XCA/Contents.json"
mkdir -p "$XCA/AppIcon.solidimagestack"
cat > "$XCA/AppIcon.solidimagestack/Contents.json" <<'JSON'
{
  "info" : { "author" : "gedev", "version" : 1 },
  "layers" : [
    { "filename" : "Front.solidimagestacklayer" },
    { "filename" : "Middle.solidimagestacklayer" },
    { "filename" : "Back.solidimagestacklayer" }
  ]
}
JSON
# Back carries the artwork (it must be opaque and fill the circle); Front and
# Middle are transparent for now -- a real three-layer parallax treatment is a
# design job, tracked in QUESTIONS.md, not a blocker for bring-up.
sips -s format png -z 1024 1024 "$ICON_SRC" --out "$STAGE/icon-back.png" >/dev/null
python3 - "$STAGE/icon-clear.png" <<'PYPNG'
import struct, sys, zlib
w = h = 1024
raw = b"".join(b"\x00" + b"\x00\x00\x00\x00" * w for _ in range(h))
def chunk(t, d):
    c = t + d
    return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))
open(sys.argv[1], "wb").write(png)
PYPNG
for spec in "Back icon-back.png" "Middle icon-clear.png" "Front icon-clear.png"; do
  set -- $spec
  L="$XCA/AppIcon.solidimagestack/$1.solidimagestacklayer"
  mkdir -p "$L/Content.imageset"
  echo '{ "info" : { "author" : "gedev", "version" : 1 } }' > "$L/Contents.json"
  cat > "$L/Content.imageset/Contents.json" <<'JSON'
{
  "images" : [ { "filename" : "img.png", "idiom" : "vision", "scale" : "2x" } ],
  "info" : { "author" : "gedev", "version" : 1 }
}
JSON
  cp "$STAGE/$2" "$L/Content.imageset/img.png"
done
xcrun actool "$XCA" --compile "$APP" \
  --app-icon AppIcon --output-partial-info-plist "$STAGE/actool.plist" \
  --platform xros --minimum-deployment-target 26.0 --target-device vision \
  --output-format human-readable-text > "$STAGE/actool.log" 2>&1 \
  || { echo "FATAL: actool failed -- see $STAGE/actool.log" >&2; cat "$STAGE/actool.log" >&2; exit 1; }
[[ -f "$APP/Assets.car" ]] || { echo "FATAL: actool produced no Assets.car" >&2; exit 1; }
# Loose grep on purpose: assetutil prints JSON-escaped slashes ("AppIcon\/Back")
# and trying to spell that inside a shell BRE is how a good icon gets reported
# as FATAL (dhewm3 D-018).
xcrun assetutil --info "$APP/Assets.car" 2>/dev/null | grep -q 'AppIcon.*Back.*Content' \
  || { echo "FATAL: Assets.car has no layered AppIcon Back layer" >&2; exit 1; }
rm -f "$STAGE/icon-back.png" "$STAGE/icon-clear.png"

else

echo "==> Writing Info.plist (iOS)"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>GoldenEye</string>
  <key>CFBundleExecutable</key><string>GoldenEye</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>GoldenEye</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>16.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string><string>metal</string></array>
  <key>UILaunchScreen</key><dict><key>UIColorName</key><string></string></dict>
  <key>UIRequiresFullScreen</key><true/>
  <!-- Without this an app driving its own Metal layer is paced to the panel's
       minimum frame duration on ProMotion iPhones, which caps and then drags
       the achievable rate. Required to ask for anything above it. -->
  <key>CADisableMinimumFrameDurationOnPhone</key><true/>
  <key>UIStatusBarHidden</key><true/>
  <key>UIViewControllerBasedStatusBarAppearance</key><false/>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>UISupportedInterfaceOrientations~ipad</key>
  <array>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <!-- Game controllers deliver presses as indirect input events; without this
       key UIKit reports them as touches at the pointer location instead. -->
  <key>UIApplicationSupportsIndirectInputEvents</key><true/>
  <!-- The game ships with no data: the user drops their own file set into
       Documents/assets through the Files app, which needs both of these. -->
  <key>UIFileSharingEnabled</key><true/>
  <key>LSSupportsOpeningDocumentsInPlace</key><true/>
  <key>CFBundleIcons</key>
  <dict>
    <key>CFBundlePrimaryIcon</key>
    <dict>
      <key>CFBundleIconFiles</key><array><string>AppIcon60x60</string></array>
      <key>CFBundleIconName</key><string>AppIcon</string>
    </dict>
  </dict>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
      <key>CFBundleURLSchemes</key><array><string>goldeneye</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "==> Generating icons"
ICON_SRC="$REPO/vendor/GoldenEye-Recomp/Icon.ico"
# Icon.ico is 256x256; iOS wants 1024 for the store slot and 120/152 on device.
# Upscaling is acceptable for a pre-release build (noted in QUESTIONS.md).
for spec in "AppIcon60x60@2x.png 120" "AppIcon60x60@3x.png 180" \
            "AppIcon76x76~ipad.png 76" "AppIcon76x76@2x~ipad.png 152" \
            "AppIcon83.5x83.5@2x~ipad.png 167" "AppIcon1024x1024.png 1024"; do
  set -- $spec
  sips -s format png -z "$2" "$2" "$ICON_SRC" --out "$APP/$1" >/dev/null
done


fi

plutil -convert binary1 "$APP/Info.plist"

if (( SIM )); then
  # The simulator does not check *who* signed, but dyld still refuses to load a
  # Mach-O with no signature at all -- and install_name_tool above stripped the
  # linker's ad-hoc one off every library it touched. Re-sign ad-hoc, nested
  # code first, same order as the device path below.
  echo "==> Ad-hoc signing for the simulator"
  for lib in "$APP/Frameworks/"*.dylib; do
    codesign --force --sign - "$lib"
  done
  codesign --force --sign - "$APP"
  echo "==> Simulator app at $APP"
  exit 0
fi

echo "==> Embedding provisioning profile"
PROFILE=""
for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision; do
  appid="$(security cms -D -i "$f" 2>/dev/null | plutil -extract Entitlements.application-identifier raw - 2>/dev/null || true)"
  if [[ "$appid" == "$TEAM.*" || "$appid" == "$TEAM.$BUNDLE_ID" ]]; then
    PROFILE="$f"
    # An exact-match profile beats the wildcard; keep looking only if wildcard.
    [[ "$appid" == "$TEAM.$BUNDLE_ID" ]] && break
  fi
done
[[ -n "$PROFILE" ]] || { echo "FATAL: no provisioning profile for $TEAM.$BUNDLE_ID" >&2; exit 1; }
echo "    $(basename "$PROFILE")"
cp "$PROFILE" "$APP/embedded.mobileprovision"

# The increased-memory-limit entitlement (M-108) raises the jetsam ceiling, and
# on a headset that is the difference between 1440p/2160p render scale booting
# and the app being killed 150 ms into GPU init. It may ONLY be signed in if
# the embedded profile actually carries it: signing an entitlement the profile
# lacks makes the install fail outright, so this is conditional and says which
# case it took.
MEMLIMIT_ENT=""
if security cms -D -i "$PROFILE" \
     | plutil -extract 'Entitlements.com\.apple\.developer\.kernel\.increased-memory-limit' raw - \
       >/dev/null 2>&1; then
  MEMLIMIT_ENT='  <key>com.apple.developer.kernel.increased-memory-limit</key><true/>'
  echo "    profile carries increased-memory-limit: signing it in"
else
  echo "    profile does NOT carry increased-memory-limit: omitting it (signing it anyway would fail the install)"
fi

ENT="$STAGE/entitlements.plist"
cat > "$ENT" <<ENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>application-identifier</key><string>$TEAM.$BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
  <key>get-task-allow</key><true/>
$MEMLIMIT_ENT
</dict>
</plist>
ENTS

echo "==> Codesigning"
# Nested code first, outside-in, or the outer signature seals stale hashes.
for lib in "$APP/Frameworks/"*.dylib; do
  codesign --force --timestamp=none --sign "$IDENTITY" "$lib"
done
codesign --force --timestamp=none --sign "$IDENTITY" --entitlements "$ENT" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# Public builds must not carry the :8773 console bridge. The bridge greets every
# connection with this banner, so its presence in any Mach-O in the bundle means
# build-ios.sh was run without PUBLIC=1 -- refuse to package it.
if [[ "${PUBLIC:-0}" == "1" ]]; then
  if grep -qa "GoldenEye console" "$APP/GoldenEye" "$APP/Frameworks/"*.dylib; then
    echo "FATAL: PUBLIC=1 but the console bridge banner is present in the bundle -- rebuild with PUBLIC=1 scripts/build-ios.sh" >&2
    exit 1
  fi
  echo "    public build: console bridge absent (verified)"
fi

mkdir -p dist
# The visionOS asset name must contain "vision" and the iOS one must not --
# stage-ota.sh routes the two platforms' install links off exactly that.
if (( VISION )); then
  IPA="$REPO/dist/goldeneye-xbla-$SHORT_VERSION-visionOS.ipa"
else
  IPA="$REPO/dist/goldeneye-xbla-$SHORT_VERSION-iOS.ipa"
fi
rm -f "$IPA"
( cd "$STAGE" && zip -qry "$IPA" Payload )

# Assert the shape of what was actually packaged, not what the script meant to
# write: a plist typo here shows up as a blank icon or a 2D-shim install on the
# headset, days later and with nothing to point at.
PB=/usr/libexec/PlistBuddy
PLIST_IN_APP="$APP/Info.plist"
if (( VISION )); then
  [[ "$($PB -c 'Print :UIDeviceFamily:0' "$PLIST_IN_APP")" == "7" ]] \
    || { echo "FATAL: visionOS bundle is not UIDeviceFamily 7" >&2; exit 1; }
  $PB -c 'Print :UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes' "$PLIST_IN_APP" >/dev/null \
    || { echo "FATAL: UIApplicationSupportsMultipleScenes is not inside the scene manifest" >&2; exit 1; }
  [[ "$($PB -c 'Print :CFBundleIconName' "$PLIST_IN_APP")" == "AppIcon" ]] \
    || { echo "FATAL: no CFBundleIconName -- SpringBoard will show the blank placeholder" >&2; exit 1; }
  [[ -f "$APP/Assets.car" ]] || { echo "FATAL: no Assets.car in the bundle" >&2; exit 1; }
else
  $PB -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$PLIST_IN_APP" >/dev/null \
    || { echo "FATAL: no CFBundleIconName in the iOS bundle" >&2; exit 1; }
  [[ -f "$APP/AppIcon60x60@2x.png" ]] || { echo "FATAL: AppIcon60x60@2x.png missing" >&2; exit 1; }
fi

echo
echo "==> $IPA"
ls -lh "$IPA" | awk '{print "    " $5}'
echo "    CFBundleShortVersionString = $SHORT_VERSION"
echo "    CFBundleVersion            = $BUILD_NUMBER"
