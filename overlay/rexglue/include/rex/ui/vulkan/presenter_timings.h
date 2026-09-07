/**
 * @file        rex/ui/vulkan/presenter_timings.h
 * @brief       Frame-stall diagnostics, for callers that must not pull in Vulkan.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * Its own header rather than a few lines in presenter.h because presenter.h
 * reaches vulkan/instance.h and from there renderdoc_app.h, whose include
 * directory belongs to the rexui target alone. The console bridge lives in
 * rexruntime and only wants two numbers, so declaring them here keeps that
 * dependency out of a translation unit that has no business with Vulkan.
 */

#pragma once

#include <cstdint>

namespace rex {
namespace ui {
namespace vulkan {

/// Last frame's acquire and present durations in microseconds, plus the peak
/// since the previous call (which clears the peaks). Acquire blocking for most
/// of a frame would mean the display pipeline sets the pace rather than our own
/// work -- it does not (M-054: one drawable wait in 41.7 s), and these stay so
/// that a presenter which starts blocking again is visible immediately rather
/// than re-argued from scratch.
void GetPresenterTimings(uint64_t* acquire_us, uint64_t* present_us, uint64_t* acquire_max_us,
                         uint64_t* present_max_us);

}  // namespace vulkan
}  // namespace ui
}  // namespace rex

/// Unmangled alias for the above. The presenter lives in the rexui library and
/// the console bridge in rexruntime, which does not link it on macOS (it does on
/// iOS, where the targets merge). Rather than reshape the link graph for a
/// diagnostic, the bridge resolves this by name at runtime -- the same way it
/// reaches RexThermalStateName, and for the same reason.
extern "C" void RexGetPresenterTimings(uint64_t* acquire_us, uint64_t* present_us,
                                       uint64_t* acquire_max_us, uint64_t* present_max_us);

/// Unmangled aliases for the WAIT_REG_MEM accessors in rex/graphics. Same story
/// as the presenter: they are defined in rexgraphics, and rexruntime does not
/// link it on macOS. See rex/graphics/command_processor.h for what each reports.
extern "C" void RexGetWaitRegMemStats(uint64_t* waits, uint64_t* total_us, uint64_t* max_us);
extern "C" void RexGetWaitRegMemWorst(uint32_t* addr, uint32_t* ref, uint32_t* op,
                                      uint32_t* is_memory);
extern "C" void RexGetWaitRegMemVblankPhase(uint64_t* mean_us, uint64_t* max_us, uint64_t* n);

/// Render passes, command-buffer submissions and swaps since the last call. On
/// a tile-based GPU each render pass costs a full tile load and store of its
/// attachment, so the per-frame pass count is a first-order cost -- M-054
/// needed a 432 MB Instruments trace to establish it was around 18.
extern "C" void RexGetGpuPassStats(uint64_t* passes, uint64_t* submissions, uint64_t* swaps);
