/**
 * @file        rex/ui/windowed_app_context_apple.h
 * @brief       Cocoa/AppKit windowed app context.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 * The Apple counterpart of windowed_app_context_gtk.h.
 */

#pragma once

#include <rex/ui/windowed_app_context.h>

namespace rex {
namespace ui {

class AppleWindowedAppContext final : public WindowedAppContext {
 public:
  AppleWindowedAppContext() = default;
  ~AppleWindowedAppContext();

  // Sets up NSApplication and the activation policy. Must run on the main
  // thread before any window is created.
  bool Initialize();

  void NotifyUILoopOfPendingFunctions() override;
  void PlatformQuitFromUIThread() override;

  // Runs [NSApp run] until PlatformQuitFromUIThread stops it.
  void RunMainAppleLoop();

 private:
  bool quit_requested_ = false;
};

}  // namespace ui
}  // namespace rex
