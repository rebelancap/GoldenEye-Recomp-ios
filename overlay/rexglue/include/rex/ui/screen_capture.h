/**
 * @file        rex/ui/screen_capture.h
 * @brief       In-engine frame capture to PNG.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * Why this exists: the port's acceptance rules require content screenshots as
 * artifacts, and the host's screen-capture API is unavailable to an automated
 * session (macOS TCC denies it silently). Capturing in-engine is better anyway:
 * it records exactly what the guest rendered, at guest resolution, with no
 * window chrome or desktop behind it -- and the identical path works on the iOS
 * simulator and on a device at the far end of an install link, where no host-side
 * screenshot tool exists at all.
 *
 * It captures the GUEST OUTPUT image, not the swapchain: that is the game's own
 * frame before letterboxing and before the ImGui overlay is composited, and
 * Presenter::CaptureGuestOutput is documented as callable from any thread.
 *
 * Driven by cvars so it needs no input plumbing:
 *   capture_dir           directory to write into; empty (default) = disabled
 *   capture_delay_ms      wait this long after start before the first capture
 *   capture_interval_ms   0 (default) = one-shot; else period between captures
 *   capture_count         how many frames to capture (default 1)
 */

#pragma once

#include <filesystem>

namespace rex {
namespace ui {

class Presenter;
struct RawImage;

// Encodes an R8G8B8X8 RawImage as a PNG. Returns false and logs on failure.
bool WriteRawImagePng(const std::filesystem::path& path, const RawImage& image);

// Starts the cvar-driven capture thread if capture_dir is set. No-op otherwise.
// Safe to call once, after the presenter exists. The thread holds no ownership
// of the presenter -- StopCaptureService must run before the presenter dies.
void StartCaptureService(Presenter* presenter);
void StopCaptureService();

}  // namespace ui
}  // namespace rex
