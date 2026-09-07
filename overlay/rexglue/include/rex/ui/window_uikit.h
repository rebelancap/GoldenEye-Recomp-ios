/**
 * @file        rex/ui/window_uikit.h
 * @brief       UIKit window (iOS, visionOS).
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * The iOS counterpart of window_apple.h. Shares surface_apple.h with macOS:
 * both put a CAMetalLayer in front of Vulkan via VK_EXT_metal_surface, so only
 * the windowing differs.
 *
 * All UIKit types are held as void* so this header stays plain C++.
 */

#pragma once

#include <cstdint>
#include <memory>
#include <string_view>

#include <rex/ui/window.h>

namespace rex {
namespace ui {

class UIKitWindow final : public Window {
  using super = Window;

 public:
  UIKitWindow(WindowedAppContext& app_context, const std::string_view title,
              uint32_t desired_logical_width, uint32_t desired_logical_height);
  ~UIKitWindow() override;

  void* ui_window() const { return ui_window_; }   // UIWindow*
  void* metal_layer() const { return metal_layer_; }  // CAMetalLayer*

  // Called from the UIKit view/controller callbacks in window_uikit.mm.
  void HandleResize();
  void HandlePaint();

 protected:
  bool OpenImpl() override;
  void RequestCloseImpl() override;

  // iOS has no user-facing window chrome: no title bar, and "fullscreen" is the
  // only mode there is. Those Apply* hooks stay defaulted.
  void FocusImpl() override {}

  uint32_t GetLatestDpiImpl() const override;

  std::unique_ptr<Surface> CreateSurfaceImpl(Surface::TypeFlags allowed_types) override;
  void RequestPaintImpl() override;

 private:
  void* ui_window_ = nullptr;      // UIWindow*
  void* view_controller_ = nullptr;  // RexViewController*
  void* metal_layer_ = nullptr;    // CAMetalLayer*
  bool paint_pending_ = false;
};

}  // namespace ui
}  // namespace rex
