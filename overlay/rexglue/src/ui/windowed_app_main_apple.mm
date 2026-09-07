/**
 * @file        ui/windowed_app_main_apple.mm
 * @brief       Apple process entry point.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 * The Apple counterpart of windowed_app_main_posix.cpp (which is GTK-bound).
 */

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/ui/windowed_app.h>
#include <rex/ui/windowed_app_context_apple.h>

extern "C" int main(int argc, char** argv) {
  auto remaining = rex::cvar::Init(argc, argv);
  rex::cvar::ApplyEnvironment();
  rex::InitLoggingEarly();

  int result;

  {
    rex::ui::AppleWindowedAppContext app_context;
    if (!app_context.Initialize()) {
      std::fputs("Failed to initialize the AppKit application\n", stderr);
      return EXIT_FAILURE;
    }

    std::unique_ptr<rex::ui::WindowedApp> app = rex::ui::GetWindowedAppCreator()(app_context);

    // Match remaining positional args to the app's expected options.
    const auto& option_names = app->GetPositionalOptions();
    std::map<std::string, std::string> parsed;
    const size_t count = std::min(remaining.size(), option_names.size());
    for (size_t i = 0; i < count; ++i) {
      parsed[option_names[i]] = remaining[i];
    }
    app->SetParsedArguments(std::move(parsed));

    if (app->OnInitialize()) {
      app_context.RunMainAppleLoop();
      result = EXIT_SUCCESS;
    } else {
      result = EXIT_FAILURE;
    }

    app->InvokeOnDestroy();
  }

  // Logging may still be needed in the destructors.
  rex::ShutdownLogging();

  return result;
}
