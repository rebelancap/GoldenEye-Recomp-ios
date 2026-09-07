/**
 * @file        ui/touch_controls.cpp
 * @brief       On-screen controls: synthesized gamepad state (iOS).
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * Platform-independent half: the published state and the stick response curve.
 * The UIKit view that drives it lives in touch_overlay_uikit.mm.
 */

#include <rex/ui/touch_controls.h>

#include <algorithm>
#include <cmath>

namespace rex {
namespace ui {

namespace {

// Individually atomic rather than a lock: this is written from the UI thread on
// every touch move and read from the guest's input poll, and neither may block
// the other. See the note on GetTouchPadState about tearing.
std::atomic<uint16_t> g_buttons{0};
std::atomic<int16_t> g_thumb_lx{0};
std::atomic<int16_t> g_thumb_ly{0};
std::atomic<int16_t> g_thumb_rx{0};
std::atomic<int16_t> g_thumb_ry{0};
std::atomic<uint8_t> g_left_trigger{0};
std::atomic<uint8_t> g_right_trigger{0};
std::atomic<bool> g_active{false};

}  // namespace

void SetTouchPadState(const TouchPadState& state) {
  g_buttons.store(state.buttons, std::memory_order_relaxed);
  g_thumb_lx.store(state.thumb_lx, std::memory_order_relaxed);
  g_thumb_ly.store(state.thumb_ly, std::memory_order_relaxed);
  g_thumb_rx.store(state.thumb_rx, std::memory_order_relaxed);
  g_thumb_ry.store(state.thumb_ry, std::memory_order_relaxed);
  g_left_trigger.store(state.left_trigger, std::memory_order_relaxed);
  g_right_trigger.store(state.right_trigger, std::memory_order_relaxed);
}

TouchPadState GetTouchPadState() {
  TouchPadState state;
  state.buttons = g_buttons.load(std::memory_order_relaxed);
  state.thumb_lx = g_thumb_lx.load(std::memory_order_relaxed);
  state.thumb_ly = g_thumb_ly.load(std::memory_order_relaxed);
  state.thumb_rx = g_thumb_rx.load(std::memory_order_relaxed);
  state.thumb_ry = g_thumb_ry.load(std::memory_order_relaxed);
  state.left_trigger = g_left_trigger.load(std::memory_order_relaxed);
  state.right_trigger = g_right_trigger.load(std::memory_order_relaxed);
  return state;
}

bool TouchControlsActive() {
  return g_active.load(std::memory_order_relaxed);
}

void SetTouchControlsActive(bool active) {
  g_active.store(active, std::memory_order_relaxed);
}

namespace {
GuestFrameCounters g_frame_counters;
}  // namespace

void SetGuestFrameCounters(GuestFrameCounters provider) {
  g_frame_counters = std::move(provider);
}

void GetGuestFrameCounters(uint64_t* submitted, uint64_t* presented) {
  if (submitted) *submitted = 0;
  if (presented) *presented = 0;
  if (g_frame_counters) {
    g_frame_counters(submitted, presented);
  }
}

void ApplyStickResponse(float x, float y, float radius, int16_t* out_x, int16_t* out_y) {
  *out_x = 0;
  *out_y = 0;
  if (radius <= 0.0f) {
    return;
  }

  float magnitude = std::sqrt(x * x + y * y) / radius;
  if (magnitude <= kStickDeadzone) {
    return;
  }
  // Direction is taken before clamping so that pushing past the ring keeps the
  // angle the user is actually holding rather than the angle at the edge.
  const float inv_len = 1.0f / std::sqrt(x * x + y * y);
  const float dir_x = x * inv_len;
  const float dir_y = y * inv_len;

  magnitude = std::min(magnitude, 1.0f);
  // Rescale so the first perceptible movement past the deadzone is a small
  // deflection, not a jump to 0.15 of full travel.
  magnitude = (magnitude - kStickDeadzone) / (1.0f - kStickDeadzone);

  const float curved =
      kStickLinearWeight * magnitude + kStickCubicWeight * magnitude * magnitude * magnitude;

  // 32767, not 32768: XInput's positive range stops one short, and saturating
  // to 32768 wraps to the extreme negative deflection.
  *out_x = static_cast<int16_t>(std::lround(std::clamp(dir_x * curved, -1.0f, 1.0f) * 32767.0f));
  *out_y = static_cast<int16_t>(std::lround(std::clamp(dir_y * curved, -1.0f, 1.0f) * 32767.0f));
}

}  // namespace ui
}  // namespace rex
