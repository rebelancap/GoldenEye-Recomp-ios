/**
 * @file        rex/graphics/gpu_dispatch_stats.h
 * @brief       Per-site accounting for the emulator's compute dispatches.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * M-061 counted ~47 compute launches per frame standing still in Dam, against
 * the command processor's 12 render passes and 2 command buffers. That traffic
 * is Xenos-emulation overhead -- EDRAM resolves, clears, texture loads -- and
 * on the thermally clamped phone it co-saturates the GPU with the actual draw
 * work. M-062 then showed the healthy regime is only ~20% GPU-occupied, so the
 * frame rate is a thermal trajectory rather than a throughput problem: these
 * dispatches are pure heat even when there is time for them.
 *
 * A trace can count them but cannot name them. This does: one counter per
 * launch site, read live over the console, so the top class can be attacked
 * rather than guessed at.
 */

#pragma once

#include <cstddef>
#include <cstdint>

namespace rex {
namespace graphics {

/// Every `CmdVkDispatch` the Vulkan backend issues, by what it is for.
enum class DispatchKind : uint32_t {
  kTextureLoad = 0,          ///< texture_cache: untile a guest texture
  kTextureLoadFloatConvert,  ///< texture_cache: the float-conversion variant
  kResolveCopy,              ///< render_target_cache: EDRAM -> resolve destination
  kResolveClearDepth,        ///< render_target_cache: depth clear during a resolve
  kResolveClearColor,        ///< render_target_cache: colour clear during a resolve
  kHostDepthStore,           ///< render_target_cache: keep host depth for reuse
  kRenderTargetDump,         ///< render_target_cache: dump for an ownership transfer
  kCount,
};

/// Relaxed increment on the GPU worker. Cheap enough to leave in: ~47 per frame
/// is under 3000 atomics a second.
void CountGpuDispatch(DispatchKind kind);

/// Counts since the previous call, which clears them -- so the console reads a
/// rate that divides cleanly into a per-frame number. `out` receives
/// `DispatchKind::kCount` entries.
void GetGpuDispatchStats(uint64_t* out, size_t count);

/// Short label for each kind, for the console line. Inline because it is static
/// data, and the console bridge lives in rexruntime, which does not link
/// rexgraphics -- see rex/ui/vulkan/presenter_timings.h.
inline const char* DispatchKindName(DispatchKind kind) {
  switch (kind) {
    case DispatchKind::kTextureLoad:             return "texload";
    case DispatchKind::kTextureLoadFloatConvert: return "texloadf";
    case DispatchKind::kResolveCopy:             return "resolve";
    case DispatchKind::kResolveClearDepth:       return "clrdepth";
    case DispatchKind::kResolveClearColor:       return "clrcolor";
    case DispatchKind::kHostDepthStore:          return "depthstore";
    case DispatchKind::kRenderTargetDump:        return "rtdump";
    case DispatchKind::kCount:                   break;
  }
  return "?";
}

}  // namespace graphics
}  // namespace rex

/// Unmangled alias; see rex/ui/vulkan/presenter_timings.h for why the console
/// bridge reaches these by name rather than by linking rexgraphics.
extern "C" void RexGetGpuDispatchStats(uint64_t* out, uint32_t count);
