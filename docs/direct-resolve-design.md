# Direct host resolve — design (M-062 campaign centerpiece)

Written 2026-08-05 from the full code read. Implement from here; every
anchor is file:line in the current tree (patches rexglue 0049-0060,
goldeneye-recomp 0001-0010).

## Why

Dam gameplay runs 12 EDRAM-shoveling compute passes per frame
(6 `rtdump` + 6 `resolve`; stat's dispatch classifier, M-063). Each
resolve today is TWO passes over the same pixels: DumpRenderTargets
writes the host RT image into the 10 MB `edram_buffer_`, then a
prebuilt resolve-copy shader reads that buffer and writes the guest
destination in shared memory. The direct path fuses them: one pass,
RT image -> guest destination. Payoff: dispatch/frame 14 -> ~8 and the
full EDRAM write+read round-trip per resolved pixel disappears —
energy per frame, which is minutes-at-60 on the phone (M-062).

## What already exists (prior session's scaffolding, all live in-tree)

- `TryResolveCopyDirectly` (render_target_cache.cpp:6403): preflight
  passes in Dam, then deliberately calls the dump path and returns
  (line ~6447). Counters: attempt/success/fallback.
- Pipeline layouts (render_target_cache.cpp:603-631): set 0 =
  single-transient STORAGE BUFFER (compute) = the destination; set 1 =
  sampled image (color) or x2 sampled images (depth+stencil) = the
  source RT; push constants = `DirectResolvePushConstants`
  (render_target_cache.h:776): `{ draw_util::ResolveCopyShaderConstants
  resolve; uint32_t source_base_tiles, source_pitch_tiles,
  dispatch_first_tile; }`.
- `GetDirectResolvePipeline` (rtc.cpp:6386): currently aliases the
  ordinary resolve-copy pipelines — REPLACE with the fused generator.
- Dispatch staging: `GetResolveCopyDispatchesToDump` already produces
  per-render-target rectangles + dispatches (`dump_rectangles_`,
  `direct_resolve_dispatches_`).

## The fused shader = the dump generator with a new sink

`GetDumpPipeline` (rtc.cpp:5839-6385) builds the dump shader with
SpirvBuilder. Anatomy:
- Bindings: EDRAM SSBO (set kDumpDescriptorSetEdram, uint or uint2
  runtime array) [REPLACED by dest buffer]; source color image or
  depth+stencil images (set kDumpDescriptorSetSource, bindings 0/1);
  push constants {pitches, offsets}; gl_GlobalInvocationID.
- Addressing (5955-6030): invocation -> 32bpp-tile decomposition ->
  `edram_sample_address` (tile index via pitches/offsets push
  constants, wraparound-safe).
- Source load + packing (6030-6335): per-format blocks — depth
  unorm24/float24 encodings, color 8888, 2_10_10_10, 7e3 float,
  16/16-pair, float32 bitcast; ends with `packed[0]` (+`packed[1]` for
  64bpp).
- Sink (6337-6352): store to edram[address] — THE ONLY PART THAT
  CHANGES.
- Epilogue: LocalSize kDumpSamplesPerGroupX/Y, CreateComputePipeline
  with dump layout [use the direct layouts instead].

New sink: compute the DESTINATION address in the guest texture from
`ResolveCopyShaderConstants` (dest base/pitch/offset/endian — the same
values the prebuilt copy shaders consume; their reference sources are
the xenia-lineage resolve shaders in the vendor tree, see the .h
SPIR-V and upstream's resolve.hlsli family for the linear addressing +
`XeEndianSwap32/64`), then store packed[] to the set-0 storage buffer
at that address. The dump-side EDRAM address math stays ONLY as the
sample-position -> source-image-texel mapping (already computed for the
image load — the EDRAM address itself becomes dead code to omit).

## Wiring the dispatch (replace rtc.cpp:6447's fallback)

Mirror the real dump dispatch loop (rtc.cpp:6460-6530, inside
DumpRenderTargets): per rectangle — bind the direct pipeline for
{dump key, copy_shader, scaled}; descriptors: set 1 = the RT's sampled
image descriptor (same as dump uses), set 0 = the transient storage
buffer descriptor for the resolve DESTINATION range in shared memory
(the copy path's own dest binding flow at the resolve dispatch site
shows the transient-descriptor idiom + required barriers); push the
DirectResolvePushConstants; dispatch the staged group counts. Barriers:
source image already in the dump's expected layout (same preflight);
dest buffer needs the same pre/post barriers the copy dispatch uses —
lift them from the copy path verbatim. Then `return true` WITHOUT
touching edram_buffer_ (no UseEdramBuffer transition needed — that is
half the point).

## Correctness protocol

- Bench (M-074 nav script) with `direct_host_resolve` on vs off:
  captures at matched frames must be pixel-identical (the packing math
  is byte-for-byte the dump's; the dest math byte-for-byte the
  copy's). stat: dispatch/frame 14 -> ~8, rtdump:6 -> ~0 in gameplay.
- Menus exercise 2+2; Dam exercises 6+6 including depth resolves.
- Any mismatch: flip the cvar off (hot-reload) — instant stock path.
- Device A/B (on hardware): minutes-to-throttle + hot-floor fps, one
  session each way. The 2026-08-05 evening .45 session watcher log
  (scratchpad/watch-45.log) is the baseline timeline.

## Order of work

1. Fused generator for 32bpp color, 1x MSAA (Dam's common case) —
   direct path fires only for keys it supports, everything else falls
   back (add a supported() check; the preflight loop already walks the
   keys).
2. Bench A/B + captures. 3. 64bpp color + depth. 4. MSAA variants.
5. Device A/B on hardware. 6. Only then consider the remaining texload
   and clear dispatches.

## Sharpened plan (post-disassembly, 2026-08-05 late)

The prebuilt copy shaders are DEST-space dispatches: invocation = dest
pixel; they compute dest address AND the EDRAM source sample address
per pixel, load edram[], swap endian, store dest. Disassembly of
resolve_fast_32bpp_1x2xmsaa_cs (469 lines, no debug names) is at
scratchpad/resolve_fast_32bpp.dis — regenerate anytime from the vendor
.h with the python+spirv-dis two-liner (see session log).

Therefore the fused generator is COPY-SHAPED, not dump-shaped:
keep the copy shader's dest dispatch, dest addressing, and endian swap
(port from the disassembly, verbatim semantics); replace ONLY its
`edram[sample_address]` load with: EDRAM sample position ->
owning-RT texel coordinate (the inverse of the dump's
invocation->EDRAM map — both affine, compose cleanly) -> image load ->
the dump's per-format packing (rtc.cpp:6030-6335) to reconstruct the
exact uint the copy shader would have read. Bit-identical by
construction at every stage.

Stage-1 gate (extend the preflight): fire only when
dump_rectangles_.size() == 1 covering the whole span, 32bpp color,
1x MSAA, unscaled — Dam's common case; everything else falls back.
Dispatch wiring: identical shape to the copy dispatch being replaced
(same group counts, same dest transient-buffer descriptor + barriers),
plus set 1 = the RT's sampled image. The dump rectangles/dispatch
staging machinery is then unused in the direct path (it was the wrong
shape — dump-space); keep it for the preflight ownership check only.

## Confirmed decode of resolve_fast_32bpp_1x2xmsaa_cs (from the .dis)

Interface: set0/b0 = EDRAM as NonWritable runtime array of v4uint
(128-bit loads); set1/b0 = dest, NonReadable v4uint array; push = 5
uints; LocalSize 8x8; each invocation handles 8 horizontal samples
(x <<= 3, loads TWO adjacent uint4s).

Push word 0 (edram_info): bits 0-9 pitch_tiles; 10-11 msaa_samples;
bit 12 is_depth; 13-23 base_tiles; 24-27 format.
Push word 1 (coordinate_info): bits 0-4,5-9 packed offset x,y (<<3,
x2 for scale — the %23019 = ((w1>>{0,4})&15)<<3 * {1,1} pair); bits
5-15 extent width (>>5 & 2047 = %16204, the x guard).
Push word 2 (dest_info): bits 0-2 dest_endian; bit 3 tiled (%20496);
4-6 dest_msaa-ish (%23037); bit 24 = swap-red-blue-ish flag (%19573)
feeding the 8in32/10in32 channel-swap switch on format (%9130).
Push word 3 (dest_coordinate_info): 0-9 dest_pitch (<<5 = %15783);
10-19 dest_height (<<5); 20-23,24-27 dest offset x,y (<<3); 28-30
copy_dest_swap-class (%16205: <=3 -> class as-is; ==5 -> 2; else 0 —
the sample-swap select).
Push word 4: dest_base (dwords? added at the end — verify at store).

EDRAM source address (per 8-sample invocation):
  pos = (inv.xy << (3,0)) + offset_from_w1
  pos <<= (msaa>=2 ? 1 : 0) per axis; += swap-class bits (%16110)
  tile = pos / (80,16); in = pos % (80,16)
  (is_depth: in.x = in.x >= 40 ? in.x-40 : in.x+40  — the depth
   column swap!)
  tile_index = base_tiles + tile.y*pitch_tiles + tile.x
  addr_samples = (tile_index*1280 + in.y*80 + in.x) % 2621440
  uint4_index = addr_samples >> 2 ; load [i] and [i+1]
  (x==0 edge: shuffle — guard detail at %9760)

Endian classes (on the pair of uint4s): 16-in-32 rotate (10_10_10
formats: switch cases 2,3,10,12) or 8-in-16+16-swap composite (cases
0,1) — the two v4uint bitfield blocks; identity otherwise.

Dest addressing when tiled (%21373 branch = NOT tiled? verify): the
32x32 macrotile swizzle with >>5 tile coords, *dest_pitch_tiles>>5,
<<9 element base, plus the classic (x&7)+((y&14)<<2) <<2 lane math
(constants -16, -512, <<3, +448 nearby — transcribe VERBATIM from
.dis lines 320-360 when writing the builder code; do not re-derive).

REMAINING TO READ (dis lines ~330-469): the linear-dest branch, the
final dest_base add + store pattern (two v4uint stores), and the
right-edge guard. The .dis file: scratchpad/resolve_fast_32bpp.dis;
regenerate: python3 extract (session log) + spirv-dis.

## Implementation note after this read

The fused shader should HANDLE 8 samples/invocation exactly like the
copy shader (same dispatch shape, same dest math) — the source side
becomes 8 image loads (or 2x4 with textureGather-style batching later)
+ packing each. For stage 1 (32bpp color 1x MSAA, C8 format 8888),
packing is trivial (unorm4x8 pack + the format's channel order), so
the first build can hardcode format==k_8_8_8_8 alongside the gate.

## Final third decoded — the spec is COMPLETE

Dest addressing: two variants by dest_info bit 3 (%20496): OFF ->
2D-tiled 32x32 macrotile swizzle (.dis 320-347); ON -> 3D-tiled with
slice = dest_info bits 4-6 (.dis 349-415; the longer swizzle).
Transcribe either VERBATIM. Then: addr += dest_base (push word 4,
BYTE units); uint4_index = addr >> 4. Dest endian (dest_info bits
0-2, %19164): 1 or 2 -> 8-in-16 swap (mask 0x00FF00FF etc.); 2 or 3
-> 16-in-32 rotate by 16; both applied for 2 (=8in32). Store first
uint4 at index, second at index+2 (32-byte interleave — the tiled
layout's pairing; keep as-is). Right-edge/x==0 guards per .dis.

With this, docs/direct-resolve-design.md + the .dis file constitute
the complete implementation spec: the copy shader's math end-to-end,
the dump generator's source-side blocks by line anchor, the layouts,
the wiring site, the gates, and the A/B protocol. The generator write
is now mechanical transcription — no unknowns remain.

## FINAL wiring plan (supersedes earlier wiring section — much simpler)

Key realization from the copy-dispatch read (rtc.cpp:1580-1665): the
dest-commit + transient-descriptor + shared_memory.Use flow runs AFTER
TryResolveCopyDirectly, and the copy dispatch happens there regardless.
So do NOT dispatch inside Try — restructure:

1. TryResolveCopyDirectly becomes preflight+prepare ONLY: stage-1 gate
   (single dump rectangle covering the whole span, color, 1x MSAA,
   unscaled, format k_8_8_8_8 [gamma later]), source-RT image barrier
   to SHADER_READ_ONLY (verbatim from the dump loop, rtc.cpp:6470-83),
   and returns the fused pipeline + the RT's
   GetDescriptorSetTransferSource() + the three extra push words
   (source_base_tiles = rt_key base, source_pitch_tiles = rt pitch,
   dispatch_first_tile).
2. At the dispatch site (~1655): if direct — skip
   UseEdramBuffer(kComputeRead); bind the FUSED pipeline; sets per the
   DIRECT layout {set0 = descriptor_set_dest (the SAME transient dest
   descriptor the copy flow just wrote), set1 = source image set};
   push DirectResolvePushConstants (8 words: the copy's 5 + the 3
   extras); SAME group counts (dest-space, unchanged). Else the stock
   copy bind/push/dispatch. Everything else (commit, barriers on dest,
   texture-cache invalidation after) is shared and untouched.
3. GetDirectResolvePipeline: return the FUSED pipeline for supported
   keys, VK_NULL_HANDLE otherwise (remove the aliasing — a non-null
   return now means really-direct). Preflight failing any key falls
   back cleanly.

Fused shader body (stage 1, all refs decoded):
push w0-w4 = copy's five (decode per .dis); w5 src_base_tiles,
w6 src_pitch_tiles, w7 dispatch_first_tile.
Guard x>=extent. pos = (gid.xy<<(3,0)) + offsets(w1) [+ the verbatim
swap-class adds]. tile = pos/(80,16), in = pos%(80,16).
edram_tile = base_tiles(w0) + tile.y*pitch_tiles(w0) + tile.x.
rt_tile = edram_tile - w5; ty = rt_tile/w6; tx = rt_tile%w6;
texel = (tx*80 + in.x + i, ty*16 + in.y), i=0..7: OpImageFetch each
(sampled image, lod 0) -> 8888 pack VERBATIM from the dump
(rtc.cpp:~6223: f*255+0.5 -> u8, bitfield-insert x4) -> two v4uints.
Then the copy shader's tail VERBATIM from the .dis: channel-swap
switch (dest_info bit24 + format), dest tiling (both variants), +=
dest_base, >>4, dest-endian swaps, store [i] and [i+2].

## Stage-2 census (2026-08-05, Dam bench, fallback logging in patch 0061+)

Single-owner fallback distribution: 86x {color, 8888, 4xMSAA,
kFull32bpp}, 9x {color, 8888, 4xMSAA, kFast32bpp4xMSAA}, zero depth
(depth resolves never reach the pipeline check -- they fail the
single-rect gate earlier, or Dam resolves depth rarely). The remaster
renders 4x MSAA; stage 1's 1x gate was near-empty in gameplay.

STAGE 2 = 4x MSAA color, both classes:
- Source side: multisampled RT image; EDRAM sample position ->
  (pixel, sample) via the Xenos 2x2 interleave (the DUMP generator's
  multisampled source math, rtc.cpp ~6030-6100, is the verbatim
  reference -- it reads an MSAA image per EDRAM sample already). The
  copy shaders' sample-swap adds (%16110) stay verbatim.
- Dest side: TWO more disassemblies needed --
  vendor .../vulkan_spirv/resolve_full_32bpp_cs.h (the 86x class;
  per-pixel dest addressing, arbitrary alignment) and
  resolve_fast_32bpp_4xmsaa_cs.h (the 9x class; near-identical to the
  decoded 1x2x variant). Same python+spirv-dis extraction.
- Gate widens to msaa_samples==k4X + those shader indices; layouts and
  wiring unchanged (the dispatch-site swap is class-agnostic).
Payoff estimate: 86/95 of single-owner fallbacks -> most of Dam's
per-frame rtdump+copy pairs fuse; THIS is the build where the thermal
A/B should become unmistakable.
