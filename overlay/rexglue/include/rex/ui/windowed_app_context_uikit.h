/**
 * @file        rex/ui/windowed_app_context_uikit.h
 * @brief       UIKit windowed app context (iOS, visionOS).
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 */

#pragma once

#include <rex/ui/windowed_app_context.h>

namespace rex {
namespace ui {

class UIKitWindowedAppContext final : public WindowedAppContext {
 public:
  UIKitWindowedAppContext() = default;
  ~UIKitWindowedAppContext();

  void NotifyUILoopOfPendingFunctions() override;
  void PlatformQuitFromUIThread() override;

  bool quit_requested() const { return quit_requested_; }

 private:
  bool quit_requested_ = false;
};

}  // namespace ui
}  // namespace rex
