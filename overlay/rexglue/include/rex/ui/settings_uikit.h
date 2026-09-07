/**
 * @file        rex/ui/settings_uikit.h
 * @brief       The native settings page (iOS / visionOS).
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * The SDK already has a settings surface (ui/overlay/settings_overlay.cpp) and
 * the game has its own pause menu, but both are ImGui driven by a mouse: on a
 * phone they are unreachable in practice. This is the family's standard native
 * page instead -- a grouped table of the handful of settings a player actually
 * wants, backed entirely by the cvar registry so that persistence, ranges and
 * defaults come from one place.
 *
 * Everything it writes goes to ge.toml in Documents/ the moment a control is
 * released, so a setting survives the app being killed rather than only a
 * clean quit.
 */

#pragma once

namespace rex {
namespace ui {

/// Show the settings page over the game. Safe from any thread (the console
/// bridge calls it from a socket thread); hops to the main thread itself.
/// A second call while it is already up is a no-op.
void PresentSettings();

/// Close it, if it is open. Safe from any thread.
void DismissSettings();

/// True while the page is on screen. The touch overlay stops publishing pad
/// state while it is, so the player is not walking into a wall behind the
/// sheet.
bool SettingsVisible();

/// If the settings_selftest cvar is set, schedule PresentSettings() for a few
/// seconds' time. Called once from the app delegate; a no-op otherwise.
void ScheduleSettingsSelftest();

/// Write the cvar registry to the config file (Documents/ge.toml on iOS),
/// off the main thread and coalesced over ~0.4 s. Called on every committed
/// change: none of them is urgent, and the main thread is also running the
/// table.
void PersistSettings();

/// The same write, synchronously on the calling thread. For resign-active,
/// where a deferred write would be lost to the process being suspended.
void PersistSettingsNow();

}  // namespace ui
}  // namespace rex
