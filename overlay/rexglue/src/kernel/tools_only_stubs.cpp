/**
 * @file        kernel/tools_only_stubs.cpp
 * @brief       Link-time stubs for REXGLUE_TOOLS_ONLY builds.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * REXGLUE_TOOLS_ONLY builds the recompiler CLI without the host backends
 * (window, renderer, audio, input). The XAM layer inside rexruntime still
 * *references* those backends, and rexruntime is a shared library, so those
 * externals have to resolve at link time. `-undefined dynamic_lookup` is not
 * enough: dyld binds RTTI and other data symbols eagerly, so the CLI fails to
 * launch rather than at first use.
 *
 * These definitions exist purely so the link closes. Every one of them aborts.
 * A tools-only rexruntime is NOT a runnable game runtime and must never ship as
 * one -- the real backends are built whenever REXGLUE_TOOLS_ONLY is OFF.
 */

#include <cstdio>
#include <cstdlib>
#include <functional>

#include <rex/cvar.h>
#include <rex/thread.h>
#include <rex/ui/imgui_dialog.h>
#include <rex/ui/windowed_app_context.h>
#include <rex/audio/audio_system.h>
#include <rex/audio/xma/decoder.h>
#include <rex/input/input_system.h>

namespace {
[[noreturn]] void ToolsOnlyAbort(const char* what) {
  std::fprintf(stderr,
               "FATAL: %s was called in a REXGLUE_TOOLS_ONLY build.\n"
               "       This binary is the recompiler CLI, not a game runtime.\n",
               what);
  std::abort();
}
}  // namespace

// -- cvars owned by src/ui/window.cpp -----------------------------------------
// Redefined here with the same names/defaults so the XAM video paths that read
// them still link. Values are never consumed in tools-only mode.
REXCVAR_DEFINE_INT32(window_width, 0, "UI/Window", "Window width in pixels");
REXCVAR_DEFINE_INT32(window_height, 0, "UI/Window", "Window height in pixels");
REXCVAR_DEFINE_INT32(video_mode_width, 1280, "GPU", "Guest video mode width in pixels");
REXCVAR_DEFINE_INT32(video_mode_height, 720, "GPU", "Guest video mode height in pixels");
REXCVAR_DEFINE_STRING(resolution, "", "GPU", "Display resolution");
REXCVAR_DEFINE_DOUBLE(video_mode_refresh_rate, 60.0, "GPU",
                      "Guest video mode refresh rate in Hz");

// -- rex::ui -------------------------------------------------------------------
namespace rex::ui {

// Defining the destructor here emits ImGuiDialog's vtable and typeinfo, which
// is what XamDialog's RTTI needs.
ImGuiDialog::~ImGuiDialog() = default;
ImGuiDialog::ImGuiDialog(ImGuiDrawer* imgui_drawer) : imgui_drawer_(imgui_drawer) {}
void ImGuiDialog::Then(rex::thread::Fence*) { ToolsOnlyAbort("ImGuiDialog::Then"); }
void ImGuiDialog::Close() { ToolsOnlyAbort("ImGuiDialog::Close"); }

bool WindowedAppContext::CallInUIThreadSynchronous(std::function<void()>) {
  ToolsOnlyAbort("WindowedAppContext::CallInUIThreadSynchronous");
}

}  // namespace rex::ui

// -- rex::audio ----------------------------------------------------------------
namespace rex::audio {

X_STATUS AudioSystem::RegisterClient(uint32_t, uint32_t, size_t*) {
  ToolsOnlyAbort("AudioSystem::RegisterClient");
}
void AudioSystem::UnregisterClient(size_t) { ToolsOnlyAbort("AudioSystem::UnregisterClient"); }
void AudioSystem::SubmitFrame(size_t, uint32_t) { ToolsOnlyAbort("AudioSystem::SubmitFrame"); }

uint32_t XmaDecoder::AllocateContext() { ToolsOnlyAbort("XmaDecoder::AllocateContext"); }
void XmaDecoder::ReleaseContext(uint32_t) { ToolsOnlyAbort("XmaDecoder::ReleaseContext"); }
bool XmaDecoder::BlockOnContext(uint32_t, bool) { ToolsOnlyAbort("XmaDecoder::BlockOnContext"); }
void XmaDecoder::WriteRegister(uint32_t, uint32_t) { ToolsOnlyAbort("XmaDecoder::WriteRegister"); }

}  // namespace rex::audio

// -- rex::input ----------------------------------------------------------------
namespace rex::input {

X_RESULT InputSystem::GetCapabilities(uint32_t, uint32_t, X_INPUT_CAPABILITIES*) {
  ToolsOnlyAbort("InputSystem::GetCapabilities");
}
X_RESULT InputSystem::GetState(uint32_t, X_INPUT_STATE*) { ToolsOnlyAbort("InputSystem::GetState"); }
X_RESULT InputSystem::SetState(uint32_t, X_INPUT_VIBRATION*) {
  ToolsOnlyAbort("InputSystem::SetState");
}
X_RESULT InputSystem::GetKeystroke(uint32_t, uint32_t, X_INPUT_KEYSTROKE*) {
  ToolsOnlyAbort("InputSystem::GetKeystroke");
}

}  // namespace rex::input
