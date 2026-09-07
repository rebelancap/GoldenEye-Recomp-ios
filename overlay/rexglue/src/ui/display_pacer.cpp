/**
 * @file        ui/display_pacer.cpp
 * @brief       See rex/ui/display_pacer.h; design in docs/pacing.md.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 */

#include <rex/ui/display_pacer.h>

#include <atomic>

namespace rex::ui {

DisplayPacer& DisplayPacer::Instance() {
  static DisplayPacer instance;
  return instance;
}

void DisplayPacer::OnDisplayLinkTick(uint64_t period_ns) {
  period_ns_.store(period_ns, std::memory_order_relaxed);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    slot_count_.fetch_add(1, std::memory_order_relaxed);
  }
  cv_.notify_all();
}

void DisplayPacer::SetLinkActive(bool active) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    active_.store(active, std::memory_order_relaxed);
  }
  // Wake waiters on deactivation so nobody blocks on a dead link.
  cv_.notify_all();
}

double DisplayPacer::refresh_hz() const {
  uint64_t period = period_ns_.load(std::memory_order_relaxed);
  return period ? 1e9 / double(period) : 0.0;
}

bool DisplayPacer::WaitForSlots(uint32_t divisor, std::chrono::milliseconds timeout) {
  if (!divisor) {
    divisor = 1;
  }
  std::unique_lock<std::mutex> lock(mutex_);
  if (!active_.load(std::memory_order_relaxed)) {
    return false;
  }
  // Wait for the next multiple of `divisor` STRICTLY AFTER the current slot:
  // a caller that wakes late re-anchors to the grid instead of accumulating
  // phase drift (the even-cadence property the whole design exists for).
  uint64_t entry = slot_count_.load(std::memory_order_relaxed);
  uint64_t target = ((entry / divisor) + 1) * uint64_t(divisor);
  bool crossed = cv_.wait_for(lock, timeout, [&] {
    return slot_count_.load(std::memory_order_relaxed) >= target ||
           !active_.load(std::memory_order_relaxed);
  });
  return crossed && active_.load(std::memory_order_relaxed) &&
         slot_count_.load(std::memory_order_relaxed) >= target;
}

}  // namespace rex::ui
