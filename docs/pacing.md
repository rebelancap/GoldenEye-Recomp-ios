# Pacing — how frames get their timing, and the display-linked design

**Status: DESIGN + IMPLEMENTATION (2026-08-02).** Written before the
implementation per the charter's Phase 1 rule. Follows the M-067 verdict:
with FSI retired, the felt problem on device ("hitchy and stuttery" at
40–60 fps, Q-009 session) decomposes into judder and hitches, and judder is
owned by this document.

## The chain as it exists (traced, completing frame-map.md §Frame flow)

1. **The guest's clock is an emulated vblank.** `GraphicsSystem::Initialize`
   (graphics_system.cpp:177) starts a "GPU VSync" worker thread that loops:
   sleep 1 ms → compare wall-clock guest ticks → if ≥ interval, `MarkVblank()`.
   `MarkVblank` stamps `g_last_vblank_us`, increments the CP counter, and
   delivers the source-0 interrupt — the guest's vblank ISR, the heartbeat
   that WAIT_REG_MEM waits watch (M-040/M-062 instrumentation).
2. **The cap can only slow it.** `vsync=true` locks the interval to the guest
   video mode (60 Hz); `max_fps` (user setting: 30/60/120/Off) can only ever
   lengthen the interval (graphics_system.cpp:238) — over-driving the vblank
   floods the ISR and freezes the guest. Upstream ships a user-facing 30 cap,
   which is the precedent that a slower-than-60 vblank is safe for this title.
3. **Presents follow guest swaps.** PM4_XE_SWAP → `IssueSwap` → presenter
   refresh; on iOS the paint is coalesced to one per main-loop turn
   (window_uikit.mm:198, which names this document as the deliberate step).
   MoltenVK presents FIFO onto the CAMetalLayer.
4. **Nothing anywhere knows when the panel refreshes.** No CADisplayLink
   exists; Info.plist does not carry `CADisableMinimumFrameDurationOnPhone`,
   so iPhone presents are capped to the 60 Hz grid even on a 120 Hz panel.

## Why this judders (the three mechanisms)

- **Phase noise.** The 1 ms sleep-poll quantizes every vblank; under load the
  scheduler adds more. Every guest frame *starts* at a slightly random time.
- **Beat frequency.** A wall-clock 60.000 Hz free-runs against the panel's
  actual refresh; even a perfect GPU shows a slipped frame at the beat rate.
- **Ugly division.** When the sustained rate is ~40–46 fps (the thermal clamp
  regime, M-064/M-067), frames land on a 60 Hz FIFO grid as alternating
  16.7/33.3 ms — the classic judder that reads as "hitchy" at a number that
  sounds fine. 40 fps presented *evenly* (every third slot of a 120 Hz panel,
  25 ms flat) is dramatically smoother than 46 fps presented raggedly.

## The design

**One principle: the emulated vblank becomes a divided-down copy of the real
display's refresh.** The panel is the only honest clock in the system; the
guest should tick on it.

- **`rex::ui::DisplayPacer`** (new, ui layer): the platform display link feeds
  it ticks (`OnDisplayLinkTick(timestamp_ns, period_ns)`); consumers block in
  `WaitForSlots(divisor, timeout)` and wake on slot multiples. It reports
  `active()`, `refresh_hz()`. iOS: `CADisplayLink` at the panel's full rate
  (`preferredFrameRateRange` 120 where available). macOS: `CADisplayLink` via
  `NSView.displayLink` (macOS 14+). Headless/CI/older macOS: the pacer stays
  inactive and everything falls back to today's timer.
- **The vsync worker keeps its thread, changes its alarm clock.** Same
  XHostThread, same `MarkVblank`, same interrupt path (M-060's lesson: the
  interrupt plumbing is delicate; only the *wait* changes). When
  `pace=displaylink` and the pacer is active it waits for display slots;
  otherwise the existing 1 ms wall-clock loop runs unchanged.
- **Even-cadence governor.** The vblank divisor is chosen so the guest rate is
  a whole division of the panel: on a 120 Hz panel the ladder is
  60 → 40 → 30 → 24 (divisors 2,3,4,5); on 60 Hz it is 60 → 30 → 20. `pace_fps`
  cvar: 0 = auto, else pin a rung. Auto mode watches delivery over a rolling
  window (presented swaps per vblank): persistent misses (< ~90 % for ~4 s)
  step down a rung; clean delivery for ~15 s steps back up. Hysteresis is
  asymmetric on purpose — stepping down must be fast (judder now), stepping up
  can be lazy (a bounce costs a visible cadence change).
- **The guest 60 cap stays the ceiling.** The ladder never exceeds the guest
  video mode rate, exactly like `max_fps` today. `max_fps` below the ladder
  rung wins (user intent).
- **ProMotion unlock**: `CADisableMinimumFrameDurationOnPhone` in Info.plist
  (make-ipa.sh generates it), display link at the panel's native rate. Without
  this the 40-rung would land on a 60 Hz grid (40 does not divide 60) and
  judder right back.

## Measure first (the family protocol applies to feel too)

Judder must be a number before and after:

- **`swap_ms p50/p95/max`** in console `stat`: inter-swap intervals measured at
  `IssueSwap` over the last ~256 swaps. Even cadence = p95 ≈ p50; judder =
  p95 ≫ p50. This is the A/B metric, and `pace` / `pace_fps` are hot-reload so
  `device-ab.sh` can flip them live in one session — the same phone session
  measures timer vs displaylink.
- **`pso=` in `stat`**: graphics pipelines created this session (the hitch
  suspect). A session that hitches while `pso` climbs is compile-bound
  (Metal recompiles every pipeline after any binary update — expected on the
  first session after every OTA, Q-010's prime suspect); one that hitches with
  `pso` flat is not, and the theory dies by measurement.

## What this deliberately does not do

- No triple buffering / deep queues: `vulkan_max_queued_frames=1` stays the
  latency default (M-053 lineage); pacing must work at queue depth 1.
- No game-speed compensation: upstream's shipped 30-cap establishes the title
  keeps real-time speed under a slower vblank. Verified again on device by
  feel at the 40 rung before this ships as default-on.
- No head-tracking concerns yet — Phase 6 inherits this document.

## visionOS: the divisor does not exist (D-024, M-104)

Everything above assumes the panel's refresh is a whole multiple of the guest's
video mode. On iPhone it always is: 60/60 = 1, 120/60 = 2. On the Vision Pro it
is not. The compositor targets **90 Hz** and the guest is **60**, and

    divisor = ceil(90 / 60 - 0.05) = 2   ->  45 Hz vblank

which is not a pacing choice at all — it runs the guest at 0.75x speed. The
only other whole divisor, 1, runs it at 1.5x. There is no third option: the
display-linked path cannot produce a 60 Hz guest vblank from a 90 Hz panel.

So `pace` defaults to **`timer`** on visionOS. The guest keeps its own 60 Hz
clock and the compositor resamples; the cost is an uneven 2:1:2:1 present
cadence rather than an even one. `swap_ms p95 >> p50` is the expected shape
there and is NOT the judder signal it is on iOS — do not read the iOS
thresholds across.

Untested on hardware. The A/B (`set pace displaylink`, `set pace_fps 45`
against the default) is Q-012 item 3, and both cvars are hot-reload, so it is
one session. Phase 6 deletes the question: CompositorServices hands us the
cadence and the guest is driven from `cp_drawable` timing, not a display link.

## Rollout

0.1.0.35 ships instrumentation + pacing with `pace=displaylink`, `pace_fps=0`
(auto) as the default on iOS, `timer` remaining the fallback wherever no
display link exists. If the device feel A/B regresses, `set pace timer` over
the console reverts live — nothing is init-only in this design.
