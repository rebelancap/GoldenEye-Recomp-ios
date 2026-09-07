/**
 * @file        rex/sampling_profiler.h
 * @brief       In-process sampling profiler, readable over the console.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * Instruments is the right tool and this is not trying to be it. But Instruments
 * needs the device on the end of a cable, and the questions that matter here
 * ("is the frame time in recompiled guest code, in the command processor, or in
 * Metal?") are answerable with far less: sample the program counter of every
 * thread a few hundred times a second and see where it sits.
 *
 * Sampled addresses are resolved two ways. Anything outside the main image goes
 * through dladdr, which names the library -- librexruntime, MoltenVK, Metal,
 * libsystem. Anything inside it is matched against PPCFuncMappings, the
 * generated guest->host function table, so a hot address in the recompiled code
 * comes back as the guest function it belongs to (sub_82xxxxxx) rather than as
 * an anonymous offset. That distinction is the whole point: it separates "the
 * game's own code is expensive" from "our emulation of it is".
 */

#pragma once

#include <cstdint>
#include <string>

struct PPCFuncMapping;  // global namespace, from rex/ppc/context.h

namespace rex {
namespace profiler {

/// Hand the profiler the generated guest->host function table. It lives in the
/// recompiled code, which is part of the consumer executable rather than the
/// runtime, so it has to be pushed in rather than referenced. Without it the
/// profiler still works and still names libraries; it just cannot attribute a
/// sample to a specific guest function.
void SetGuestFunctionTable(const ::PPCFuncMapping* mappings);

/// Begin sampling at `hz` (clamped to something the scheduler can serve).
/// Restarts and clears counts if already running.
/// 200 Hz by default. Each tick reads the state of every thread in the process,
/// so the cost scales with thread count -- at 500 Hz across ~30 threads that is
/// 15,000 mach traps a second, enough to change the timing of what is being
/// measured. Raise it only for short bursts.
void Start(uint32_t hz = 200);

/// Stop sampling. Collected counts survive for a later Report().
void Stop();

bool IsRunning();

/// Human-readable breakdown, hottest first: a per-image summary, then the
/// hottest individual sites. Safe to call while sampling.
std::string Report(size_t max_rows = 25);

/// Discard collected samples.
void Reset();

}  // namespace profiler
}  // namespace rex
