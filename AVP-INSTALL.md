# Installing GoldenEye 007 on Apple Vision Pro

This is the GoldenEye 007 XBLA remaster, Rare's Xbox 360 remake, finished in 2007 and never released, as a static recompilation for Apple silicon. It is not an emulator: built on [GoldenEye-Recomp](https://github.com/SunJaycy/GoldenEye-Recomp) and the [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk), the original PowerPC game code is translated ahead of time into C++, with the Xbox 360 GPU, audio and kernel layers reimplemented on Vulkan via [MoltenVK](https://github.com/KhronosGroup/MoltenVK) on Metal. On Apple Vision Pro it runs in a resizable 2D window, and the remaster's instant switch between the 2007 art and the original N64 look works mid-game.

## What you need

- Apple Vision Pro on visionOS 26 or later
- The game's complete file set (around 750 MB), supplied by you. See below.
- A game controller (MFi, Xbox or PlayStation) is strongly recommended in the headset. Without one, the touch layer is driven by pinch.
- For the prebuilt app: SideStore on the headset, installed with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos)
- To build from source: macOS with Xcode and its visionOS SDK, plus `cmake` and `ninja` (`brew install cmake ninja`), your own game files (the build reads `default.xex`), a MoltenVK xcframework, and an Apple Developer signing identity with a provisioning profile

## Your game files

The app ships with no game data: there is no game content, no executable, no textures and no audio in this repository or in the app. You supply the complete file set yourself. This project can't help you obtain it and won't answer questions about where to find it. Please don't ask, and don't post links in the issue tracker.

If you already have the file set:

1. Open the **Files** app and go to **On My Apple Vision Pro → GoldenEye**.
2. Put your game files in a folder named exactly **`assets`**. Either form of the file set works:
   - **Extracted:** `assets/default.xex` (the November 2007 build), `assets/files/` (the asset tree), and the `.xwb` / `.xsb` / `.xgs` sound banks beside them.
   - **Unextracted:** drop the whole container folder in as `assets`. The app finds the package by its header and mounts it.
3. It's around 750 MB either way, so let the copy finish before tapping **Check Again** on the first-run screen. That screen tells you what it found and what is missing. `files/original` and `files/new` are the N64 and remastered model sets: a set missing one of them boots, but the graphics switch only half-works.

Your settings and saves live in the app's own folder, separate from the game data. The README's [You bring the game](README.md#you-bring-the-game) section covers the same steps for iPhone.

## Install the prebuilt app

1. Install SideStore on the headset with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos). SideStore and AltStore can't be installed on visionOS the usual way; iloader is what gets SideStore there. No Xcode or Dev Strap required.
2. In SideStore, go to *Sources → +* and paste this source, then install GoldenEye:

   ```
   https://raw.githubusercontent.com/rebelancap/all-ports/main/apps-visionos.json
   ```

   This is a shared source that carries the other ports too, and the app updates from it when new versions ship.

To install by hand instead, download `goldeneye-xbla-<VERSION>-visionOS.ipa` from the [latest release](https://github.com/rebelancap/GoldenEye-Recomp-ios/releases/latest) and install it through SideStore or AltStore.

## Build from source

The build needs your own game files: the recompiler runs over your `default.xex` and writes the game's code out as C++ in `generated/`, which is then compiled for Apple silicon. The generated code and any game data stay on your Mac and are never committed. From a checkout of this repo:

1. Put your extracted file set in `work/gamedata/Bean/`, so that `work/gamedata/Bean/default.xex` exists. (`work/` is not committed.)
2. Build:

   ```sh
   scripts/bootstrap.sh                      # clone the upstream trees at their pinned commits
   scripts/build-macos.sh                    # overlay + recompile default.xex -> generated/ (once)
   PUBLIC=1 scripts/build-ios.sh visionos    # the runtime and app for Apple Vision Pro
   PUBLIC=1 scripts/make-ipa.sh --visionos   # -> dist/goldeneye-xbla-<VERSION>-visionOS.ipa
   ```

- `scripts/bootstrap.sh` clones [GoldenEye-Recomp](https://github.com/SunJaycy/GoldenEye-Recomp) and [SunJaycy's ReXGlue tree](https://github.com/SunJaycy/GoldenEye-Recomp-rexglue) into `vendor/` at the commits pinned in `vendor/PINS`. `scripts/build-macos.sh` runs it again itself, applies the overlay with `scripts/apply-overlay.sh`, builds the recompiler and runs it over `default.xex`. Its last stage calls `scripts/compile-generated-probe.sh`, which isn't in the repository, so the script ends with an error there; `generated/` is already written by then, and it's all `build-ios.sh` needs.
- `PUBLIC=1` builds the release flavour. Without it, `build-ios.sh` compiles in a developer console that listens on port 8773 on every network interface and takes unauthenticated commands; with it, the console is compiled out, and `make-ipa.sh` checks that it's gone.
- `make-ipa.sh` embeds MoltenVK from `work/moltenvk/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework` (its comments name MoltenVK 1.4.2) and stops if it isn't there. No script fetches it.
- Signing: set `DEV_TEAM` (your Apple Developer Team ID) and `CODESIGN_IDENTITY` (such as `Apple Development: Your Name (XXXXXXXXXX)`) in the environment, or in `scripts/signing.local.sh`, which is gitignored. The script embeds a provisioning profile from `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` whose app ID is your team plus `com.rebelancap.goldeneye` (the bundle ID is fixed in the script) or your team's wildcard.
- It signs in the increased-memory-limit entitlement only when that profile carries it. The script's comments say that on the headset this entitlement is what lets the 1440p and 2160p render scales start; a launch that's cut short at a higher scale falls back to a lower one the next time.

The result is a signed `.ipa`, the same kind of file as the release download. Upstream GoldenEye-Recomp and ReXGlue are vendored unmodified and pinned by commit; every local change is a patch under `patches/`, applied by `scripts/apply-overlay.sh`, and a patch that fails to apply fails the build. iPhone builds are in [Building from source](README.md#building-from-source).

## Notes

- **RB** flips between the remastered and original N64 graphics at any time, even mid-firefight; **Settings → Graphics → Original N64 graphics** does the same. If the two fall out of step, toggle the setting once and they resync.
- Without a controller, a pinch anywhere in the left half of the window raises the move stick, and pinching the on-screen buttons presses them.
- On Apple Vision Pro the default resolution is 1440p (2x), which holds about 60 fps. 2160p (3x) is sharper but runs around 45 fps. Resolution changes take effect on the next launch.
- The first session after installing can show brief flicker or missing effects while shaders compile. They're cached, so it stops after that session and doesn't come back until the next update.
- Multiplayer is not supported; the campaign is. Split-screen and the online modes are out of scope for now.
- Sideloaded apps expire: a free Apple account signs for 7 days, a paid developer account for a year. SideStore refreshes them in the background; open it and let it re-sign if the app stops launching.
- GoldenEye 007 is © Rare / Nintendo / MGM / Danjaq. This project is not affiliated with, endorsed by, or connected to any of them.
