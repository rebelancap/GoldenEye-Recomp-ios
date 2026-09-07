/**
 * @file        rex/ui/onboarding_uikit.h
 * @brief       First-run game data classifier and instructions screen (iOS).
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * The app ships with no game data: the user supplies their own file set through
 * the Files app. On desktop a missing "assets" folder is a one-line error on
 * stderr and the user can go look; on iOS there is no stderr to look at and no
 * way to pass a path, so a missing or wrong drop has to explain itself on the
 * screen. That is what this is.
 */

#pragma once

#include <filesystem>
#include <functional>
#include <string>

namespace rex {
namespace ui {

/// What a candidate game data folder turned out to be.
struct GameDataStatus {
  enum class Kind {
    kMissing,      ///< the folder is not there at all
    kEmpty,        ///< the folder is there but has nothing in it
    kUnrecognised, ///< it has contents, but not a GoldenEye file set
    kExtracted,    ///< an extracted file set (default.xex + files/)
    kContainer,    ///< an unextracted STFS ("LIVE") package
  };

  Kind kind = Kind::kMissing;
  /// One sentence a person can act on, e.g. which file is missing.
  std::string detail;
  /// True for the two kinds the runtime can actually mount.
  bool usable() const { return kind == Kind::kExtracted || kind == Kind::kContainer; }
};

/// Classify `dir` as game data. Cheap: stats a handful of paths and, for the
/// container case, reads one header. Safe to call repeatedly.
GameDataStatus ClassifyGameData(const std::filesystem::path& dir);

/// Show the first-run instructions over the game window, and keep showing them
/// until `dir` classifies as usable.
///
/// `on_ready` is invoked on the main thread once the user has supplied a usable
/// file set. It is never invoked more than once. No-op on non-UIKit builds.
void PresentGameDataOnboarding(const std::filesystem::path& dir,
                               std::function<void()> on_ready);

}  // namespace ui
}  // namespace rex
