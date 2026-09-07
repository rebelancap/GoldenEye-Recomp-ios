/**
 * @file        rex/ui/display_pacer.h
 * @brief       The display's own refresh clock, for consumers that pace on it.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream. Design:
 * docs/pacing.md.
 *
 * The emulated guest vblank is the game's heartbeat, and upstream generates it
 * from a wall-clock timer polled at 1 ms granularity -- phase noise on every
 * frame start, plus a beat frequency against the real panel. This class lets
 * the platform's display link (CADisplayLink on iOS / macOS 14+) publish the
 * panel's actual refresh ticks, and lets the vsync worker block on them
 * instead: the guest vblank becomes a divided-down copy of the glass.
 *
 * Threading: the platform link thread calls OnDisplayLinkTick; any number of
 * consumers may block in WaitForSlots. If no link ever activates (headless,
 * older macOS, GTK), active() stays false and consumers keep their fallback.
 */

#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>

namespace rex::ui {

class DisplayPacer {
 public:
  static DisplayPacer& Instance();

  // Called by the platform display link once per panel refresh.
  void OnDisplayLinkTick(uint64_t period_ns);
  // Window lifecycle: a pacer whose link stopped must not strand waiters.
  void SetLinkActive(bool active);

  bool active() const { return active_.load(std::memory_order_relaxed); }
  // Panel refresh rate derived from the last tick's period; 0 when inactive.
  double refresh_hz() const;
  uint64_t slots() const { return slot_count_.load(std::memory_order_relaxed); }

  // Blocks until the slot counter crosses the next multiple of `divisor`
  // (aligning cadence to a stable grid even if the caller wakes late), or the
  // timeout expires, or the link deactivates. Returns true only when woken by
  // a real slot crossing.
  bool WaitForSlots(uint32_t divisor, std::chrono::milliseconds timeout);

 private:
  DisplayPacer() = default;

  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::atomic<bool> active_{false};
  std::atomic<uint64_t> slot_count_{0};
  std::atomic<uint64_t> period_ns_{0};
};

}  // namespace rex::ui
