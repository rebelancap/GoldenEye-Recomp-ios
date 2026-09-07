/**
 * @file        rex/host_suspend.h
 * @brief       Host GPU suspend gate for backgrounded Apple apps.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * iOS and visionOS forbid GPU work from a process that is not foreground. Press
 * the Digital Crown (or the home gesture) and Metal starts failing command
 * buffers; MoltenVK surfaces that as VK_ERROR_DEVICE_LOST on the next fence
 * wait or queue submit, and the runtime -- which has no notion of a GPU that
 * comes back -- calls GraphicsSystem::OnHostGpuLossFromAnyThread, i.e.
 * rex::FatalError, i.e. abort. Three separate Vision Pro sessions crashed with
 * exactly that stack on the "GPU Commands" thread (M-111).
 *
 * The guest is innocent and needs no rescuing: it only needs the HOST GPU path
 * to stop while the app is away, and to start again when it comes back. This is
 * that gate.
 *
 *   UI thread, willResignActive/didEnterBackground:
 *     Request()                      -- no new submissions from now on
 *     WaitForAck(500)                -- bounded wait for the GPU worker to
 *                                       finish its open submission, wait out
 *                                       its fences, and park
 *   UI thread, didBecomeActive:
 *     Release()                      -- the worker wakes and carries on
 *
 * Everything on the GPU side reads the gate rather than being driven by it, so
 * a missed notification degrades to "we kept rendering", never to a deadlock.
 *
 * Lives in rexcore because all three of rexgraphics (the command processor),
 * rexui (the presenter and the UIKit app layer) and the app itself need it, and
 * rexcore is the one library every one of them links.
 */

#pragma once

#include <cstdint>

namespace rex {
namespace host_suspend {

/// Ask the host GPU path to stop. Idempotent; callable from any thread.
void Request();

/// Let it run again. Starts the resume grace window (see IsSuspendedOrResuming).
void Release();

/// True from Request() until Release(). The submission and present paths check
/// this before doing anything that reaches the GPU.
bool IsRequested();

/// True while suspended AND for a short grace window after the release. A fence
/// or present error inside this window is the OS taking the GPU away and giving
/// it back -- a swapchain event, not a device loss -- so it must not become a
/// FatalError. Outside the window a device loss is the real thing and stays
/// fatal.
bool IsSuspendedOrResuming();

/// Called by the GPU worker at its loop top. If a suspend is pending, runs
/// `quiesce` (end the open submission, await every outstanding fence), marks
/// itself parked, and blocks on a condition variable until Release(). Returns
/// true if it parked.
bool GateWait(void (*quiesce)(void* ctx), void* ctx);

/// Bounded wait, from the UI thread, for the worker to reach the gate. Returns
/// true if it parked in time. False is not fatal -- it means the worker was
/// somewhere it could not park quickly, and the classification below is what
/// keeps that from being a crash.
bool WaitForAck(uint32_t timeout_ms);

/// Suspend/resume cycles completed, for the console `stat` line and the logs.
uint64_t CycleCount();

}  // namespace host_suspend
}  // namespace rex

extern "C" {
/// C surface for the console bridge (dlsym, like every other cross-library
/// reach in that file) and for ge_hooks' freeze watchdog, which must not treat
/// a backgrounded app as a wedged GPU.
void RexHostGpuSuspendRequest(void);
void RexHostGpuSuspendRelease(void);
int RexHostGpuWaitForSuspendAck(unsigned timeout_ms);  ///< 1 if the worker parked
int RexHostGpuIsSuspended(void);          ///< 1 while the gate is set
int RexHostGpuIsSuspendedOrResuming(void);  ///< 1 inside the grace window too
}
