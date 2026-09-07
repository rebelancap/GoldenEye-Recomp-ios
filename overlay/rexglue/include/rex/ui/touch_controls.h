/**
 * @file        rex/ui/touch_controls.h
 * @brief       On-screen controls: synthesized gamepad state (iOS).
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * GoldenEye is a twin-stick console shooter, so the honest mapping for a
 * touchscreen is a virtual gamepad rather than a new input channel: the overlay
 * writes an XInput-shaped state here, and the guest's XamInputGetState merges it
 * with whatever a real controller is reporting. Nothing downstream -- not the
 * aim assist, not the menus, not the CE patches -- needs to know touch exists.
 */

#pragma once

#include <atomic>
#include <cstdint>
#include <functional>

namespace rex {
namespace ui {

/// One frame of synthesized pad state, in XInput's own units.
struct TouchPadState {
  uint16_t buttons = 0;        ///< XINPUT_GAMEPAD_* bits
  int16_t thumb_lx = 0;        ///< -32768..32767
  int16_t thumb_ly = 0;
  int16_t thumb_rx = 0;
  int16_t thumb_ry = 0;
  uint8_t left_trigger = 0;    ///< 0..255
  uint8_t right_trigger = 0;
};

/// Publish the current state. Called from the UI thread as touches move.
void SetTouchPadState(const TouchPadState& state);

/// Read the current state. Called from the guest's input poll, on a different
/// thread. Fields are individually atomic: a torn read mixes two frames of a
/// 60 Hz input stream, which is not distinguishable from normal sampling.
TouchPadState GetTouchPadState();

/// True once any touch control has been used, and false while a real controller
/// is driving. The overlay hides itself in that case -- a pad user should not
/// have thumbsticks painted over their game.
bool TouchControlsActive();
void SetTouchControlsActive(bool active);

/// Stick response shared by both sticks.
///
/// `x` and `y` are the raw offset from the stick's origin in points, `radius`
/// the travel at which the stick is fully deflected. Applies a radial deadzone
/// and the family's 0.4 linear + 0.6 cubic response curve, then writes XInput
/// units to `out_x` / `out_y`.
///
/// Radial, not per-axis: a square deadzone lets a diagonal push register on one
/// axis while the other is still dead, which reads as the stick snapping to the
/// cardinals near centre.
void ApplyStickResponse(float x, float y, float radius, int16_t* out_x, int16_t* out_y);

/// Supply the guest's submit/present counters to the overlay's frame-rate
/// readout. The counters live in game-specific code, so the SDK is handed a
/// function rather than reaching for them. Unset means the readout shows zero.
using GuestFrameCounters = std::function<void(uint64_t* submitted, uint64_t* presented)>;
void SetGuestFrameCounters(GuestFrameCounters provider);
void GetGuestFrameCounters(uint64_t* submitted, uint64_t* presented);

/// Create the on-screen control view and add it to `parent_view` (a UIView*).
/// Defined in touch_overlay_uikit.mm; void* so callers need not be ObjC++.
void AttachTouchOverlay(void* parent_view);

/// The deadzone and curve constants, exposed for tests and for the settings UI.
inline constexpr float kStickDeadzone = 0.15f;
inline constexpr float kStickLinearWeight = 0.4f;
inline constexpr float kStickCubicWeight = 0.6f;

}  // namespace ui
}  // namespace rex
