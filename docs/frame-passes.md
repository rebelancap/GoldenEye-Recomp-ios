# The Dam frame, pass by pass

**Status: SETTLED for the gameplay frame.** Every label below is backed by a
register value or an address arithmetic identity read out of a live process,
not by inference from pass ordering. Where something is still inference it says
so in the "evidence" column and the open questions at the end name it.

Instrument: the `passes` console command (rx-0067) extended by **rx-0086**,
which adds per-pass distinct window-offset and shader-hash sets and a
`GERESOLVE` record per PM4 copy (source EDRAM rect, destination guest address,
pitch, format, sample select, clears). Captured on the macOS arm64 bench
(`build/ge-macos`, MoltenVK, `rtpath=fbo`), Dam, standing at the spawn, at
`resolution_scale` 1 and 2, in **both** visual modes. Raw censuses and the
method are in MEASUREMENTS.md **M-109**.

---

## The one-sentence answer

The scene is submitted three times per frame because **bean renders 720p with
4x MSAA through Xbox 360 predicated tiling**: at 4x MSAA a 1280-wide
colour+depth pair fills the 10 MB EDRAM in 256 pixel rows, so the guest renders
the frame as three horizontal bands — 256 + 256 + 208 = 720 — each with its own
window offset, each resolved to its own third of one contiguous 1280x720 image
in guest memory. **The three passes are three different thirds of the picture,
not three versions of it.** None is redundant and none is skippable.

![the three tile bands](../artifacts/M-109-dam-three-tile-bands.png)

## The proof, in four independent facts

1. **Window offsets 0 / −256 / −512.** `PA_SC_WINDOW_OFFSET` across each pass
   (rx-0086 `wofsU=`): tile A `[0]`, tile B `[0,0x7f000000]`, tile C
   `[0,0x7e000000]`. The field is a signed 15-bit y in bits 30:16 —
   `0x7f00` = −256, `0x7e00` = −512. M-100 could not name tile C because the
   original census recorded only the first draw's value.
2. **Resolve destinations are one image, three offsets.** The three scene
   resolves write `0x1EB80000`, `0x1ECC0000`, `0x1EE00000`. Each gap is
   `0x140000` = 1,310,720 bytes = **1280 × 256 × 4** — exactly 256 rows of a
   1280-wide 32bpp image. The resolve source heights are 256, 256 and **208**,
   summing to 720.
3. **Viewports shrink by the offset.** Tile A's viewport union is 1280x720,
   tile B's is **1280x464** (= 720 − 256) with the tile scissor at 1280x256.
   The guest sets "everything from here down" and lets the scissor and the
   render-target extent clip it to the band.
4. **The bands cost different amounts of GPU time.** M-099's Metal System
   Trace medians for the three scene submissions on device: **8.35 ms / 2.24 ms
   / 3.02 ms** (plus their sub-passes). Three copies of the same image would
   cost the same; three different thirds of a scene whose top band is sky,
   trees, dam wall and water do not.

## The pass map — Dam, standing at spawn, `resolution_scale=1`

Host extents are given in host pixels; with the M-101 host-MSAA downgrade the
guest's 4x sample space maps to host pixels 1:1, so the guest render target
`1280x512` **is** one 1280x256-pixel tile at 4 samples. Draw/vertex counts are
one representative frame (they drift a few percent frame to frame with
animation); the structure does not drift.

| pass | kind | render target | draws | verts | what it is | evidence |
|---|---|---|---|---|---|---|
| 00 | xfer | 1280x512 | — | — | EDRAM ownership transfer into the scene colour RT | transfer pass, no draws |
| 01 | guest | scene RT `c0=0x00110000 b=0t p=32t s=4x` + `d=0x00310400 b=1024t` | 1 | 4 | full-screen quad, one PS (`2e372ea2…`), no blend — the frame-opening clear/copy quad | 1 draw, 4 verts, quad-shaped |
| 02–07 | xfer ×6 | 1280x512 | — | — | three depth+colour transfer pairs, each preceded by `resolve:3` | `pre=resolve:3` on 02/04/06 |
| — | resolve 00–08 | — | — | — | the **previous** frame's three tiles copied out and cleared: per tile a colour copy to `0x1E9C0000` and a depth copy (`fmt=22`, kD24S8) to `0x1E9B0000` — both **linear** (`pitch=0`) — plus a tiled colour copy to `0x1F660000 / 0x1F7A0000 / 0x1F8E0000` with `clears=3` (colour+depth). Same 256/256/208 heights, same `0x140000` stride. | GERESOLVE 00–08 |
| 08 | guest | scene RT | 1 | 4 | second full-screen quad, same PS as 01 | identical shader hash |
| **09** | guest | scene RT | 329 | 275,387 | **tile A**, opaque scene geometry, `blend=0` | `wofsU=[0]`; M-099 pos 9 = 8.35 ms |
| **10** | guest | scene RT | 130 | 110,718 | tile A, the scissored part: `scis=1280x256`, `vp=1280x720` | the tile band, explicitly scissored |
| **11** | guest | scene RT | 37 | 13,990 | tile A, trailing effects/blend | |
| 12–13 | xfer | | — | — | depth+colour transfer, preceded by `resolve:1` | |
| — | resolve 09 | | | | **tile A → `0x1EB80000`**, src `1280x256`, `samplesel=6` (resolve all 4 samples), `clears=3` | GERESOLVE 09 |
| **14–16** | guest | scene RT | 329 / 130 / 37 | identical to 09–11 | **tile B**, `wofs y=−256`, `vp=1280x464`, `scis=1280x256` | `wofsU` contains `0x7f000000` |
| — | resolve 10 | | | | **tile B → `0x1ECC0000`** (= A + 0x140000), src `1280x256` | GERESOLVE 10 |
| **19** | guest | scene RT | 496 | 400,095 | **tile C**, `wofs y=−512`; the three sub-groups do not split into separate host passes here (496 = 329+130+37) | `wofsU` contains `0x7e000000` |
| — | resolve 11 | | | | **tile C → `0x1EE00000`** (= B + 0x140000), src `1280x**208**` | GERESOLVE 11 |
| 20–21 | xfer | | — | — | depth+colour transfer | |
| 22 | xfer | 1280x2048 | — | — | `pre=texload:1` — the resolved 1280x720 scene image loaded back as a texture into the composite RT | `texload` dispatch |
| 23 | guest | composite RT `c0=0x00008000 b=0t p=16t s=1x` | 50 | 300 | the 2D composite: full-screen quads (6 verts each) at `scis=1280x720`, `vp=1280x720`, three distinct PS | 1x samples, quad geometry, screen-sized scissor |
| 24 | guest | composite RT | 31 | 186 | HUD / watch overlay quads, all blended (`blend=31` of 31) | every draw blends |
| 25 | xfer | 1280x2048 | — | — | preceded by `resolve:1` | |
| — | resolve 12 | | | | composite → **`0x1EF20000`**, src `1280x720` at `s=1x`, the presented front buffer | GERESOLVE 12 |

Totals for this frame: 26 passes, 1571 draws, 1,200,779 vertices. The three
scene submissions are **1488 of the 1571 draws (95%) and 1,200,285 of the
1,200,779 vertices (99.96%)**.

### The composite render target is not 2048 rows of content

`1280x2048` and `1280x512` are EDRAM-derived *allocations*, not image sizes: a
pitch of 16 tiles over 2048 EDRAM tiles gives 128 tile rows × 16 = 2048 lines.
The content is bounded by the scissor (1280x720) and by the resolve source rect.
This is worth stating because the extent alone invites the wrong reading — e.g.
"2560x6144 must be three stacked images". It is not; it is one allocation.

## Scale invariance

At `resolution_scale=2` every host extent doubles (`2560x1024` scene RT,
`2560x512` tile scissor, `2560x928` tile-B viewport) and **every guest-side
number is byte-identical**: same three window offsets, same three resolve
destinations, same 256/256/208 source heights, same shader hashes. The Vision
Pro's `2x3` census in the same shape (`2560x1536` = guest `1280x512`) is the
same frame. Tiling is a property of the guest's EDRAM budget, which resolution
scaling does not change.

## The visual toggle is not one of the three

Tested live, both directions, on one process (M-109 §2). Pressing the game's
own RB shortcut (`ge_graphics_toggle_mask` = `0x0200`):

| | passes | draws | verts | tile structure |
|---|---|---|---|---|
| remaster | 26 | 1571 | 1,200,779 | 3 tiles, wofs 0 / −256 / −512 |
| N64 | 22 | 791 | **118,346** | 3 tiles, wofs 0 / −256 / −512 |
| back to remaster | 25 | 1391 | 1,119,752 | unchanged |

The N64 mode drops **90% of the frame's vertices** and swaps the pixel-shader
set (`262d3e00…`/`b926e19d…` give way to `e45ce5a5…`/`7c1a8af6…`), while the
tile count, the window offsets and the three resolve destinations are
identical. The two looks are **alternatives, not simultaneous** — nothing
invisible is being rendered for the benefit of the instant toggle. Content
screenshots of the same camera in both modes:
`artifacts/M-109-bench-dam-remaster-scale1.png`,
`artifacts/M-109-bench-dam-n64-scale1.png`.

## What tiling actually costs

- **Fragment: nothing.** Three tiles shade 256 + 256 + 256 = 768 rows for a
  720-row frame (the last tile's render target is 256 rows but only 208 are
  resolved), so the overdraw is **6.7%**, not 200%. The unequal MST medians
  above are the unequal content of the three bands, not repetition.
- **Vertex: 3x.** Every draw's vertex shader runs once per tile: 1.2 M vertex
  invocations for a ~400 k-vertex scene. M-099 measured the whole Vertex
  channel at 3.1 ms/frame on device (8.5% busy) against 20.8 ms of fragment, so
  the redundant two-thirds is **~2 ms of a ~24 ms frame**.
- **Draw submission: 3x.** ~1000 redundant draw calls per frame of CPU and
  driver work. M-099 found the CPU idle (0.2 core, GPU Commands 11% busy), so
  this is not currently the constraint.
- **Transfers and resolves:** six EDRAM ownership-transfer passes and the
  per-tile resolves, ~1.4 ms + ~1.2 ms on device (M-099).

Because vertex work is resolution-independent and fragment work is not, the
tiling overhead **shrinks as a share of the frame as render scale rises**. At
the Vision Pro's 2x3 it is a smaller fraction of the frame than the ~15% M-100
estimated at 1x.

## Open questions

- **What consumes `0x1E9C0000` (linear colour) and `0x1E9B0000` (linear
  D24S8)?** They are written every frame from the previous frame's tiles, and
  the depth copy in particular implies a depth-consuming effect. Not traced.
- **What is the second tiled 1280x720 image at `0x1F660000`?** Written with
  `clears=3` at the frame top, same three-band stride. Candidates: a
  previous-frame buffer for a post effect, or a second view (watch / security
  camera). Not traced.
- **`stat`'s per-frame dispatch averages are diluted by keep-alive swaps**
  (M-083): a real Dam frame carries 26 passes and 13 resolve operations, while
  `stat` reports `passes/frame=12` and `resolve:6`. The ratio (2.08 and 2.17)
  is consistent, but the averages should not be read as per-frame truth.
- **Whether menu/briefing frames tile twice or three times.** M-100 recorded a
  two-tile menu frame; not re-verified with rx-0086.
