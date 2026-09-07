/**
 * @file        ui/sdl_ios_device_idiom.mm
 * @brief       SDL_IsIPad / SDL_IsAppleTV for iOS builds with SDL_VIDEO=OFF.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * The SDK builds SDL with `SDL_VIDEO OFF` (thirdparty/CMakeLists.txt:247) —
 * this port does its own windowing and only wants SDL for audio and gamepad
 * input. But SDL3's `SDL.c` references `SDL_IsIPad()` and `SDL_IsAppleTV()`
 * unconditionally on Apple mobile platforms, and both live in the UIKit *video*
 * driver, which is not compiled. Result: two undefined symbols at link.
 *
 * These are real implementations, not stubs: UIDevice answers the same question
 * SDL's versions do, without dragging in the video subsystem.
 */

#import <UIKit/UIKit.h>

extern "C" {

bool SDL_IsIPad(void) {
  return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
}

bool SDL_IsAppleTV(void) {
  return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomTV;
}

}  // extern "C"
