/**
 * @file        ui/windowed_app_context_uikit.mm
 * @brief       UIKit windowed app context (iOS, visionOS).
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * The key difference from the macOS context: on iOS, UIKit already owns the run
 * loop by the time any of our code runs (UIApplicationMain never returns), so
 * RunMainLoop is a no-op rather than a [NSApp run]. Everything else is the same
 * shape -- pending functions are pumped by dispatching to the main queue.
 */

#include <rex/ui/windowed_app_context_uikit.h>

#include <rex/logging.h>

#import <UIKit/UIKit.h>

namespace rex {
namespace ui {

UIKitWindowedAppContext::~UIKitWindowedAppContext() {
  NotifyUILoopOfPendingFunctions();
}

void UIKitWindowedAppContext::NotifyUILoopOfPendingFunctions() {
  dispatch_async(dispatch_get_main_queue(), ^{
    ExecutePendingFunctionsFromUIThread();
  });
}

void UIKitWindowedAppContext::PlatformQuitFromUIThread() {
  // iOS applications do not exit on their own -- Apple's HIG forbids it and the
  // system owns termination. Log and keep running; the guest's "quit" path
  // (pause menu -> Quit) should be surfaced as something else on this platform.
  REXLOG_INFO("UIKitWindowedAppContext: quit requested; iOS apps do not self-terminate");
  quit_requested_ = true;
}

}  // namespace ui
}  // namespace rex
