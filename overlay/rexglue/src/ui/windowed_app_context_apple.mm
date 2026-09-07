/**
 * @file        ui/windowed_app_context_apple.mm
 * @brief       Cocoa/AppKit windowed app context.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 * The Apple counterpart of windowed_app_context_gtk.cpp.
 */

#include <rex/ui/windowed_app_context_apple.h>

#include <rex/logging.h>

#import <AppKit/AppKit.h>

namespace rex {
namespace ui {

AppleWindowedAppContext::~AppleWindowedAppContext() {
  NotifyUILoopOfPendingFunctions();
}

bool AppleWindowedAppContext::Initialize() {
  @autoreleasepool {
    // NSApplication must exist before any window, and the process needs to be
    // a "regular" app to get a menu bar, a Dock tile and keyboard focus --
    // without this a CLI-launched binary opens a window that cannot take focus.
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];
    [NSApp activateIgnoringOtherApps:YES];
    return true;
  }
}

void AppleWindowedAppContext::NotifyUILoopOfPendingFunctions() {
  // The base class has queued the work; just make the main loop turn.
  // dispatch_async to the main queue is delivered by the run loop that
  // [NSApp run] pumps, so this works whether or not we are on the UI thread.
  dispatch_async(dispatch_get_main_queue(), ^{
    ExecutePendingFunctionsFromUIThread();
  });
}

void AppleWindowedAppContext::PlatformQuitFromUIThread() {
  quit_requested_ = true;
  @autoreleasepool {
    [NSApp stop:nil];
    // [NSApp stop:] only takes effect after the next event is processed, so
    // post a dummy one rather than waiting on user input.
    NSEvent* wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                       location:NSMakePoint(0, 0)
                                  modifierFlags:0
                                      timestamp:0
                                   windowNumber:0
                                        context:nil
                                        subtype:0
                                          data1:0
                                          data2:0];
    [NSApp postEvent:wake atStart:YES];
  }
}

void AppleWindowedAppContext::RunMainAppleLoop() {
  @autoreleasepool {
    if (quit_requested_) {
      return;
    }
    [NSApp run];
  }
}

}  // namespace ui
}  // namespace rex
