# Frame map — input to present

**Status: PARTIAL.** This records what has actually been read and verified in
the upstream sources, and says plainly what has not. It is not yet the complete
Phase 0.1 deliverable — the GPU command processor has been located and its
failure mode read from upstream's own comments, but not read line by line.
Do not treat the GPU section as authoritative until that is done.

## Component map (verified by reading the build files and sources)

```
GoldenEye-Recomp (game layer, ~3.3k lines hand-written)
  src/main.cpp            -> GeApp::Create
  src/ge_app.h            -> GeApp : rex::ReXApp   boot cvars, pause menu, post-FX
  src/ge_hooks.cpp        1575 lines: midasm hooks, mouse-look, GPU freeze watchdog
  src/ge_ce_patches.cpp   Community Edition patch set applied at runtime
  src/ge_menu.cpp         ImGui pause menu
  src/ge_postfx.cpp       always-on colour-grade overlay
  generated/              2.18M lines of recompiled PPC C++ (never committed)

ReXGlue SDK
  src/codegen/    18k   AOT PPC -> C++ recompiler (XenonRecomp lineage)
  src/system/     12k   rexruntime: kernel state, XEX loader, threads, memory
  src/kernel/     19k   xboxkrnl / XAM / XBDM emulation
  src/graphics/  256k   Xenos command processor + shader translation (Xenia-derived)
       vulkan/    21k   Vulkan backend
       d3d12/     18k   D3D12 backend
  src/ui/         30k   window, presenter, ImGui, per-backend presenters
  src/audio/      1.9k  SDL3 audio + XMA decode (FFmpeg)
  src/input/      1.6k  SDL3 gamepad, raw mouse/keyboard, XInput
```

Library graph: `rexglue` (CLI) → `rexcodegen` → {`rexcore`, `rexruntime`}.
`rexruntime` is a **shared** library and additionally links `rexgraphics`,
`rexui`, `rexaudio`, `rexinput` (`src/kernel/CMakeLists.txt:70`) — the XAM layer
calls into all of them, which is why a backend-free build needs stub definitions
(D-003).

## Platform seams that must be built for Apple (verified)

The runtime's platform layer is **GTK + XCB on Unix, Win32 on Windows**. SDL3 is
used for audio and input only, *not* windowing. So there is no free ride:

| seam | Linux | Windows | Apple — to be written |
|---|---|---|---|
| window | `window_gtk.cpp` | `window_win.cpp` | — |
| surface | `surface_gnulinux.cpp` (XCB) | `surface_win.cpp` | — |
| app context | `windowed_app_context_gtk.cpp` | `windowed_app_context_win.cpp` | — |
| entry | `windowed_app_main_posix.cpp` | `windowed_app_main_win.cpp` | reusable? |
| VK surface | `VK_KHR_xcb_surface` | `VK_KHR_win32_surface` | `VK_EXT_metal_surface` |

`vulkan_presenter.cpp:803/817` branches on exactly two surface types. Adding a
`MetalWindowSurface` alongside `XcbWindowSurface` is the shape of the change.

One item already noted as latent: `rex_app.cpp:368` tests
`#if defined(REX_PLATFORM_WINDOWS)` for GPU-vendor-based backend selection, and
that macro *is* defined (top-level `CMakeLists.txt:126`) — so the `#else` branch
(`use_vulkan = true; // Linux/macOS native`) is what Apple will take. Good
default for us; no change needed.

## Backend selection (verified)

`ReXApp::SetupPresentation` picks Vulkan on everything except NVIDIA-on-Windows.
Upstream's own comment says D3D12 "black-screens / TDRs on AMD and Intel Arc"
for this title, and the top-level CMake comment says the same. **The Vulkan path
is the well-exercised one for GoldenEye specifically** — which is the single
strongest argument for spiking MoltenVK first in Phase 0.5.

## The CPU↔GPU semaphore deadlock (read from upstream's comments, not yet traced)

`src/ge_hooks.cpp:124–460` carries a "freeze watchdog": a detached thread that
watches for the guest continuing to present while the picture is frozen. Its own
comments describe the failure precisely:

- The command processor **parks in `WAIT_REG_MEM`** on a semaphore the CPU never
  releases → permanent visual freeze while the guest keeps running.
- Recovery: write 0 to the semaphore block (`idblk`) to release the CP, which
  then drains the ring buffer and delivers the interrupt
  (`ge_hooks.cpp:163–172`).
- Three lines of defence are documented at `ge_hooks.cpp:440–460`: (a) and (b)
  are normal paths that feed the ring, and (c) is the watchdog, which fires after
  ~80 ms and turns "a permanent freeze into a recoverable hitch".
- The watchdog also dumps ring `rpi`/`wpi`, present counts, GPU fences, the
  render gate at `dword_8242043C`, and guest thread stacks.

The SDK has its own `include/rex/gpu_stall_recovery.h` in addition to this.

**Not yet done:** reading `src/graphics/command_processor.cpp` and the Vulkan
command processor to establish *why* the semaphore is missed, and whether
MoltenVK's semaphore/fence semantics change the shape of it. That is the first
real Phase 0.5 risk and it is explicitly still open.

## Frame flow — pacing chain traced 2026-08-02

The vblank-to-present chain is now traced and documented in
**docs/pacing.md** ("The chain as it exists"): the emulated vblank worker
(graphics_system.cpp:177) is the guest's clock, `max_fps` can only slow it,
PM4_XE_SWAP -> IssueSwap -> presenter is the present path, and the
CADisplayLink integration replaced the wall-clock timer (patch 0053). The
remaining untraced item from the original list:
1. `ReXApp` main loop → `Presenter::Paint` → backend presenter.
2. Guest `VdSwap` path (`ge_hooks.cpp` has a `ge_diag_vdswap` midasm hook at
   `0x82199944`) → ring buffer → CP → present.
3. Where the 60 fps cap (`max_fps`, default set in `ge_app.h:55`) is enforced,
   and how that must become a `CADisplayLink` on Apple (`docs/pacing.md`,
   not yet written).
4. Input: the xenia-canary mouse-look injection in `ge_hooks.cpp` is the channel
   the charter wants touch/gyro mapped onto — its entry point needs naming here.

## What is verified vs. assumed in this document

**Verified by reading source or build files:** the component map, LOC counts,
the library graph, the platform-seam table, backend selection, the watchdog's
existence and location, the two Vulkan surface branches.

**Read from upstream comments, not independently confirmed:** the mechanism of
the CPU↔GPU deadlock and the recovery write.

**Not yet established:** the frame flow itself, pacing enforcement point, and
the input injection entry point.
