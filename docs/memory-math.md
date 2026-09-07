# Memory math — the 360's model inside Apple's

Numbers, measured on this machine (M-series, macOS 27, 48 GB) on 2026-07-28.
Anything not measured is labelled as an estimate.

## What the runtime reserves

`Memory::Initialize` (`rexglue/src/system/xmemory.cpp:130`) creates one POSIX
shared-memory object and maps eight overlapping views of it:

```
shm object:  0x11FFFFFFF  = 4,831,838,207 B  = 4.50 GB
             (the 360's whole 4 GB virtual space + 512 MB "physical")
```

| guest range | size | shm offset | note |
|---|---|---|---|
| `0x00000000–0x3FFFFFFF` | 1024 MB | 0x00000000 | 4 KB pages |
| `0x40000000–0x7EFFFFFF` | 1008 MB | 0x40000000 | 64 KB pages |
| `0x7F000000–0x7FFFFFFF` | 16 MB | 0x80000000 | |
| `0x80000000–0x8FFFFFFF` | 256 MB | 0x80000000 | XEX image, 64 KB pages |
| `0x90000000–0x9FFFFFFF` | 256 MB | 0x80000000 | XEX, 4 KB pages |
| `0xA0000000–0xBFFFFFFF` | 512 MB | 0x100000000 | physical, 64 KB pages |
| `0xC0000000–0xDFFFFFFF` | 512 MB | 0x100000000 | physical, 16 MB pages |
| `0xE0000000–0xFFFFFFFF` | 512 MB | 0x100001000 | physical, 4 KB pages |

The last three deliberately **alias**: `0xA0000000`, `0xC0000000` and
`0xE0000000` are three views of the same 512 MB of "physical" memory at
different page granularities. That aliasing is not incidental — the CPU↔GPU
shared-memory model depends on it.

**Verified on Darwin** (`memprobe2`): two `MAP_SHARED` mappings of the same shm
offset alias correctly — a write through one is visible through the other.
The model is viable on Apple platforms.

## Address-space reservation: Darwin will not take arbitrary bases

Upstream probes `1<<32 … 1<<63` for a base that accepts all eight views. On
Darwin most of those are already spoken for. Measured, 1 GB `MAP_FIXED` anonymous
reservation at each base:

| base | result |
|---|---|
| `1<<32` (0x1_0000_0000) | `ENOMEM` — arm64 `__PAGEZERO` is 4 GB; the main image lands here |
| `1<<33`, `1<<36`, `1<<37`, `1<<38` | `EACCES` — dyld shared-cache regions |
| `1<<34`, `1<<35`, `1<<39` … `1<<46` | OK |
| `1<<47` | `ENOMEM` — past the 47-bit user VA limit |

**Fix (D-004 / patch 0007):** ask the kernel for one contiguous 4.5 GB
`PROT_NONE` reservation and drop the `MAP_FIXED` shared views into it. Measured
working; the kernel placed it at `0x7000000000`. This is also more robust than
probing — it cannot collide with a future dyld layout change.

**`shm_open` + `ftruncate(4.5 GB)` works on macOS.** That was not obvious;
macOS POSIX shared memory has historically had low limits. Measured OK.

## The 16 KB page — the structural finding

```
getpagesize()         = 16384
sysconf(_SC_PAGESIZE) = 16384
vm_page_size          = 16384
vm_kernel_page_size   = 16384
```

Apple Silicon uses a **16 KB** page on macOS, iOS and visionOS alike. Four of
the guest heaps above are **4 KB**-paged. Measured consequences:

| operation | result |
|---|---|
| `mprotect(16K-aligned, 16K)` | OK |
| `mprotect(16K-aligned, 4K)` | OK (kernel rounds the length) |
| `mprotect(4K-aligned, 4K)` | **`EINVAL`** |
| `mprotect(4K-aligned, 16K)` | **`EINVAL`** |
| `mmap MAP_FIXED` at a 4 KB offset | **`EINVAL`** |
| `PROT_NONE` on one inner 4 KB page | **`EINVAL`** |

Linux uses 4 KB pages on both x86-64 and aarch64, which is why upstream's
linux-aarch64 CI never surfaced this, and why the Android ARM64 checkpoint
would not have either.

**What we do:** `ClampToHostPages()` in `memory_posix.cpp` rounds the address
down and the length up to 16 KB for `AllocFixed` and `Protect`. Guest
bookkeeping stays 4 KB.

**What it costs.** Host protection is 16 KB-granular, so:

1. **GPU write-watch over-invalidates.** `graphics/shared_memory.cpp` uses page
   protection to notice guest writes to GPU-visible memory. At 16 KB, a write to
   any of four adjacent 4 KB guest pages trips the watch for all of them → up to
   4× redundant re-uploads in the worst case. **Perf, not correctness.**
   Quantify in Phase 3 before doing anything about it.
2. **4 KB guard pages cannot be isolated.** `protect_zero` (first 64 KB) and the
   last 64 KB are 64 KB-aligned, so those are unaffected. Any *new* 4 KB guard
   page would be.

Not yet measured: whether the write-watch amplification is visible at all in a
real frame. That is a Phase 3 measurement, on device, not a guess.

## iOS budget — estimates, not measurements

Nothing below has been measured on device; the app does not exist yet.

- **Address space.** The 4.5 GB reservation is `PROT_NONE` — address space, not
  committed memory. iOS is 64-bit with a large user VA, so the *reservation*
  should be granted. Committed footprint is what counts against the app's
  limit, and that is driven by what the guest actually touches.
- **Guest RAM.** The 360 had 512 MB unified. Worst case the guest commits all of
  it, plus the XEX image (256 MB range, ~16 MB actual) and host-side structures.
- **Host GPU resources.** Texture/render-target caches on top, sized by the
  remastered asset set — `files/new/` is the bulk of the 603 MB `files/` tree.
  Not all of it is resident at once; per-level residency is unknown until we can
  instrument a running build.
- **`com.apple.developer.kernel.increased-memory-limit`.** Likely needed. The
  default per-app limit on recent iPhones is roughly 2–3 GB depending on device
  RAM; 512 MB of guest RAM plus GPU caches plus ~20 MB of recompiled code plus
  the runtime could plausibly approach it. **Decide with a measurement, not
  this paragraph** — the entitlement is cheap to add and free to carry.
- **Recompiled code size.** Measured, not estimated: 2,179,709 lines of C++ →
  **19.3 MB of arm64 objects at `-O1`**, 32 translation units. `-O2`/`-Os` and
  the linked binary size are not yet measured. This is a real chunk of the IPA
  and of resident memory once paged in.

## Open questions for Phase 0.7 proper

- Does iOS grant the contiguous 4.5 GB `PROT_NONE` reservation? (Simulator
  first, then device.)
- Does `shm_open` + a 4.5 GB `ftruncate` work under the iOS sandbox? POSIX
  shared memory is restricted there — this may need a different backing store
  (an anonymous mapping, or a file in the app container).
- Measured resident footprint at the title screen and in a heavy level.
