/**
 * @file        core/host_suspend.cpp
 * @brief       Host GPU suspend gate. See rex/host_suspend.h for the why.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 */

#include <rex/host_suspend.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>

#include <rex/logging.h>

namespace rex {
namespace host_suspend {

namespace {

// How long after a Release() a fence/present failure is still read as "the OS
// was holding the GPU", not as a lost device. The first frame after a resume
// has to re-acquire a swapchain whose images the compositor may have recycled
// underneath us, and on visionOS the compositor can take a beat to hand the
// layer back; two seconds is generous for that and still far short of any real
// device loss going unnoticed (a genuinely lost device fails every frame, so it
// simply reports one window later).
constexpr int64_t kResumeGraceMs = 2000;

std::mutex g_mutex;
std::condition_variable g_cv_worker;   // worker waits here while suspended
std::condition_variable g_cv_acked;    // the UI thread waits here for the park
bool g_requested = false;
bool g_worker_parked = false;
uint64_t g_cycles = 0;
// steady_clock ms at the last Release(). Read without the lock by the hot
// classification paths -- it is a hint, and an atomic int64 is lock-free on
// every platform this builds for.
std::atomic<int64_t> g_released_at_ms{0};
// Read lock-free by BeginSubmission and the presenter, which run on the GPU
// worker and the paint thread respectively and must not contend on a mutex per
// draw. The mutex still orders the actual parking.
std::atomic<bool> g_requested_fast{false};

int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

}  // namespace

void Request() {
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_requested) {
      return;
    }
    g_requested = true;
    g_worker_parked = false;
  }
  g_requested_fast.store(true, std::memory_order_release);
  REXLOG_INFO("HOSTSUSPEND: requested -- host GPU submission and present gated off");
}

void Release() {
  uint64_t cycles = 0;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_requested) {
      return;
    }
    g_requested = false;
    g_worker_parked = false;
    cycles = ++g_cycles;
  }
  // Order matters: open the grace window BEFORE letting the worker run, so the
  // very first post-resume fence wait is already inside it.
  g_released_at_ms.store(NowMs(), std::memory_order_release);
  g_requested_fast.store(false, std::memory_order_release);
  g_cv_worker.notify_all();
  REXLOG_INFO("HOSTSUSPEND: released -- cycle {} complete, {} ms grace window open", cycles,
              kResumeGraceMs);
}

bool IsRequested() { return g_requested_fast.load(std::memory_order_acquire); }

bool IsSuspendedOrResuming() {
  if (g_requested_fast.load(std::memory_order_acquire)) {
    return true;
  }
  const int64_t released = g_released_at_ms.load(std::memory_order_acquire);
  return released != 0 && (NowMs() - released) < kResumeGraceMs;
}

bool GateWait(void (*quiesce)(void* ctx), void* ctx) {
  if (!g_requested_fast.load(std::memory_order_acquire)) {
    return false;
  }
  // Drain the host GPU BEFORE announcing the park: the whole point of the ack
  // is that the UI thread can rely on "nothing of ours is in flight" once it
  // sees it. Done outside the lock -- it waits on fences and can take a frame.
  if (quiesce) {
    quiesce(ctx);
  }
  std::unique_lock<std::mutex> lock(g_mutex);
  if (!g_requested) {
    // Released while we were draining. Nothing to park for.
    return false;
  }
  g_worker_parked = true;
  lock.unlock();
  g_cv_acked.notify_all();
  REXLOG_INFO("HOSTSUSPEND: GPU worker parked (drained)");
  lock.lock();
  g_cv_worker.wait(lock, [] { return !g_requested; });
  g_worker_parked = false;
  lock.unlock();
  REXLOG_INFO("HOSTSUSPEND: GPU worker resumed");
  return true;
}

bool WaitForAck(uint32_t timeout_ms) {
  std::unique_lock<std::mutex> lock(g_mutex);
  const bool woke = g_cv_acked.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                                        [] { return g_worker_parked || !g_requested; });
  return woke && g_worker_parked;
}

uint64_t CycleCount() {
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_cycles;
}

}  // namespace host_suspend
}  // namespace rex

extern "C" void RexHostGpuSuspendRequest(void) { rex::host_suspend::Request(); }
extern "C" void RexHostGpuSuspendRelease(void) { rex::host_suspend::Release(); }
extern "C" int RexHostGpuWaitForSuspendAck(unsigned timeout_ms) {
  return rex::host_suspend::WaitForAck(static_cast<uint32_t>(timeout_ms)) ? 1 : 0;
}
extern "C" int RexHostGpuIsSuspended(void) { return rex::host_suspend::IsRequested() ? 1 : 0; }
extern "C" int RexHostGpuIsSuspendedOrResuming(void) {
  return rex::host_suspend::IsSuspendedOrResuming() ? 1 : 0;
}
