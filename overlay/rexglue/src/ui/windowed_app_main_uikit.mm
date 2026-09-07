/**
 * @file        ui/windowed_app_main_uikit.mm
 * @brief       iOS / visionOS process entry point.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * Unlike every other platform, UIKit owns the run loop: UIApplicationMain does
 * not return. So the app cannot be initialised inline and then handed a loop to
 * run -- instead the delegate creates it once UIKit is up, and the app's
 * OnInitialize runs from didFinishLaunching.
 *
 * Guest boot is heavy (XEX load, 82 resources), so it runs off the main thread:
 * blocking didFinishLaunching past the watchdog window gets the process killed.
 */

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <rex/cvar.h>
#include <rex/filesystem.h>
#include <rex/logging.h>
#include <rex/ui/settings_uikit.h>
#include <rex/ui/windowed_app.h>
#include <rex/ui/windowed_app_context_uikit.h>

// We provide main() below, so SDL must not rename it to SDL_main.
#define SDL_MAIN_HANDLED
#include <SDL3/SDL_main.h>

#import <UIKit/UIKit.h>

namespace {
rex::ui::UIKitWindowedAppContext* g_app_context = nullptr;
std::unique_ptr<rex::ui::WindowedApp>* g_app = nullptr;
}  // namespace

@interface RexAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation RexAppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  (void)application;
  (void)launchOptions;

  // The screen must stay awake: this is a game, and there is no user input
  // during cutscenes or long stretches of aiming.
  application.idleTimerDisabled = YES;

  g_app_context = new rex::ui::UIKitWindowedAppContext();
  g_app = new std::unique_ptr<rex::ui::WindowedApp>(
      rex::ui::GetWindowedAppCreator()(*g_app_context));

  if (!(*g_app)->OnInitialize()) {
    REXLOG_ERROR("iOS: app OnInitialize failed");
    rex::ui::ScheduleSettingsSelftest();
    return YES;  // stay alive so the log can be retrieved
  }
  REXLOG_INFO("iOS: app initialised");
  rex::ui::ScheduleSettingsSelftest();
  return YES;
}

- (void)applicationWillResignActive:(UIApplication*)application {
  (void)application;
  // Persist synchronously: iOS may suspend us immediately after this returns,
  // and a deferred write would be lost (family lifecycle rule).
  REXLOG_INFO("iOS: resigning active");
  // Settings the player changed this session, written before the process can be
  // suspended. The settings page already persists on every committed change, so
  // this is the belt to that braces -- and it also catches anything set over the
  // console bridge.
  rex::ui::PersistSettingsNow();
  rex::ShutdownLogging();
  rex::InitLoggingEarly();
}

@end

extern "C" int main(int argc, char** argv) {
  // On the platforms where SDL would normally own main() -- iOS among them --
  // every SDL_InitSubSystem fails until it is told main was entered properly.
  // Without this the events, gamepad and audio subsystems all refuse to start,
  // and the guest's audio init then hands the game a null it dereferences
  // forever: 181 million faulting reads of guest 0x3c and not one GPU submit
  // (M-046). Nothing about that failure names SDL, which is what made it
  // expensive to find; the one line that does is the init error itself.
  SDL_SetMainReady();

  // cvars come from the bundle rather than a command line on iOS. Anything the
  // app needs to configure at boot is set through the config file in the
  // container; argv is empty in practice.
  auto remaining = rex::cvar::Init(argc, argv);
  (void)remaining;
  rex::cvar::ApplyEnvironment();
  rex::InitLoggingEarly();

  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([RexAppDelegate class]));
  }
}
