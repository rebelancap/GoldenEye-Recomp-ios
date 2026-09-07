/**
 * @file        rex/ui/window_apple.h
 * @brief       Cocoa/AppKit window.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 * The Apple counterpart of window_gtk.h / window_win.h.
 *
 * All AppKit types are held as void* so this header stays plain C++ -- only
 * window_apple.mm is compiled as Objective-C++.
 */

#pragma once

#include <cstdint>
#include <memory>
#include <string_view>

#include <rex/ui/window.h>

namespace rex {
namespace ui {

class AppleWindow final : public Window {
  using super = Window;

 public:
  AppleWindow(WindowedAppContext& app_context, const std::string_view title,
              uint32_t desired_logical_width, uint32_t desired_logical_height);
  ~AppleWindow() override;

  // NSWindow*, or null before OpenImpl / after close.
  void* ns_window() const { return ns_window_; }
  // CAMetalLayer* backing the content view.
  void* metal_layer() const { return metal_layer_; }

  // Called from the AppKit delegate/view callbacks in window_apple.mm.
  void HandleResize();
  void HandleFocus(bool focused);
  void HandleCloseRequest();
  void HandlePaint();

 protected:
  bool OpenImpl() override;
  void RequestCloseImpl() override;

  void ApplyNewFullscreen() override;
  void ApplyNewTitle() override;
  void FocusImpl() override;

  uint32_t GetLatestDpiImpl() const override;

  std::unique_ptr<Surface> CreateSurfaceImpl(Surface::TypeFlags allowed_types) override;
  void RequestPaintImpl() override;

 private:
  void* ns_window_ = nullptr;    // NSWindow*
  void* content_view_ = nullptr; // NSView* (layer-hosting)
  void* metal_layer_ = nullptr;  // CAMetalLayer*
  void* delegate_ = nullptr;     // RexWindowDelegate*
  bool paint_pending_ = false;
};

}  // namespace ui
}  // namespace rex
