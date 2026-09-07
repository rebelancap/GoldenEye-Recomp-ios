/**
 * @file        ui/audio_session_uikit.mm
 * @brief       Other-app audio policy (iOS / visionOS).
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * The family's standard audio handling (quake ports): the player chooses what
 * happens to Music/podcast audio when the game is running, from five modes.
 * Two halves implement it:
 *   - AVAudioSession category options (who mixes with whom, who ducks whom);
 *   - a game-side duck gain for the two modes that attenuate the GAME instead,
 *     which the SDL mixer multiplies into every buffer via RexAudioDuckGain
 *     (resolved by dlsym so the non-Apple builds never know it exists).
 *
 * The mode lives in the audio_session_mode cvar so it persists through the
 * same ge.toml path as every other setting.
 */

#include <rex/ui/settings_uikit.h>

#include <rex/cvar.h>
#include <rex/logging.h>

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <atomic>

REXCVAR_DEFINE_INT32(audio_session_mode, 2, "Audio",
                     "What happens to another app's audio (Music, podcasts) while the game "
                     "runs: 0=stop it, 1=both play, 2=lower it (default), 3=lower the game "
                     "instead, 4=mute the game while it plays.")
    .range(0, 4)
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

namespace {

// How far the game drops in "Lower Game Audio" while the other app plays.
constexpr float kDuckGain = 0.22f;

// Read by the SDL audio callback through RexAudioDuckGain below.
std::atomic<float> g_duck_gain{1.0f};

int CurrentMode() {
  return std::clamp(rex::cvar::Query<int32_t>("audio_session_mode"), 0, 5 - 1);
}

// The category options each mode wants. Playback throughout: the game must
// keep sounding with the hardware silent switch on, which Playback buys over
// Ambient; only the mixability bits differ between modes.
NSUInteger OptionsForMode(int mode) {
  switch (mode) {
    case 0:  // Stop Other Audio: non-mixable, activation interrupts the other app
      return 0;
    case 2:  // Lower Other Audio
      return AVAudioSessionCategoryOptionMixWithOthers |
             AVAudioSessionCategoryOptionDuckOthers;
    default:  // Play Both / Lower Game / Mute Game: we do our own attenuating
      return AVAudioSessionCategoryOptionMixWithOthers;
  }
}

BOOL OtherAudioPlaying(AVAudioSession* s) {
  // isOtherAudioPlaying is the broad "someone else has sound out";
  // secondaryAudioShouldBeSilencedHint is the narrower "another app is playing
  // PRIMARY audio". Either means the player is listening to something that is
  // not us.
  return s.isOtherAudioPlaying || s.secondaryAudioShouldBeSilencedHint;
}

void RecomputeDuckGain(AVAudioSession* s) {
  const int mode = CurrentMode();
  float gain = 1.0f;
  if (OtherAudioPlaying(s)) {
    if (mode == 3) gain = kDuckGain;   // Lower Game Audio
    else if (mode == 4) gain = 0.0f;   // Mute Game Audio
  }
  if (gain != g_duck_gain.load(std::memory_order_relaxed)) {
    REXLOG_INFO("audio session: game duck gain -> {:.2f} (mode {}, other {})", gain, mode,
                OtherAudioPlaying(s) ? "playing" : "silent");
  }
  g_duck_gain.store(gain, std::memory_order_relaxed);
}

}  // namespace

// The SDL mixer's hook: multiplied into master_volume every callback. dlsym'd
// from sdl_audio_driver.cpp so desktop builds resolve it to null harmlessly.
extern "C" float RexAudioDuckGain(void) {
  return g_duck_gain.load(std::memory_order_relaxed);
}

namespace rex {
namespace ui {

void* AudioModeTitles() {
  // Index == audio_session_mode value. Names chosen for a player: what the
  // ROW does, not what AVAudioSession calls it.
  return (__bridge void*)@[
    @"Stop Other Audio", @"Play Both", @"Lower Other Audio", @"Lower Game Audio",
    @"Mute Game Audio"
  ];
}

void* AudioModeDetails() {
  // One sentence each, because "duck" and "mix" mean nothing to a player and
  // a four-word label would not help. Shown under each choice in the picker.
  return (__bridge void*)@[
    @"Music and podcasts stop when GoldenEye starts.",
    @"Both play together, neither one quieter.",
    @"Music and podcasts drop to the background; game audio stays full.",
    @"Game audio drops to the background while another app is playing.",
    @"Game audio goes silent while another app is playing.",
  ];
}

void ApplyAudioSessionMode() {
  AVAudioSession* s = AVAudioSession.sharedInstance;
  const int mode = CurrentMode();
  const NSUInteger want = OptionsForMode(mode);
  NSError* err = nil;

  if (![s.category isEqualToString:AVAudioSessionCategoryPlayback] ||
      s.categoryOptions != want) {
    if (![s setCategory:AVAudioSessionCategoryPlayback
                   mode:AVAudioSessionModeDefault
                options:want
                  error:&err]) {
      REXLOG_ERROR("audio session: setCategory (mode {}, opts {:#x}) failed: {}", mode,
                   (unsigned long)want, err.description.UTF8String ?: "?");
    } else {
      REXLOG_INFO("audio session: Playback opts {:#x} (mode {})", (unsigned long)want, mode);
    }
  }

  // Switching TO the non-mixable mode mid-session only interrupts the other
  // app when the session (re)activates, and setActive:YES on an already-active
  // session is a no-op -- so if the other app is still going, bounce it once.
  if (mode == 0) {
    [s setActive:YES error:nil];
    if (OtherAudioPlaying(s)) {
      [s setActive:NO
          withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                error:nil];
      if (![s setActive:YES error:&err]) {
        REXLOG_ERROR("audio session: reactivate to interrupt failed: {}",
                     err.description.UTF8String ?: "?");
      }
    }
  }

  RecomputeDuckGain(s);

  // Observers, once: the duck-game modes must react when the other app starts
  // or stops MID-game, and the category is worth re-asserting on foreground
  // (SDL or the system may have touched the session while backgrounded).
  static BOOL observing = NO;
  if (observing) return;
  observing = YES;
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  [nc addObserverForName:AVAudioSessionSilenceSecondaryAudioHintNotification
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification* n) {
                (void)n;
                RecomputeDuckGain(AVAudioSession.sharedInstance);
              }];
  [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification* n) {
                (void)n;
                ApplyAudioSessionMode();
              }];
}

}  // namespace ui
}  // namespace rex
