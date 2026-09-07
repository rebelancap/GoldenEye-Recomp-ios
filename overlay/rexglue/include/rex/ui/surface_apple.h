/**
 * @file        rex/ui/surface_apple.h
 * @brief       CAMetalLayer-backed presentation surface for Apple platforms.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * The Apple counterpart of surface_gnulinux.h (XCB) and surface_win.h (HWND).
 * Vulkan reaches it through VK_EXT_metal_surface, which takes a CAMetalLayer*
 * directly -- the same layer works for a native Metal backend later, so this
 * type is not MoltenVK-specific.
 *
 * The layer is held as void* so this header stays plain C++ and can be included
 * from the non-Objective-C++ translation units of the presenter.
 */

#pragma once

#include <cstdint>

#include <rex/ui/surface.h>

namespace rex {
namespace ui {

class MetalWindowSurface final : public Surface {
 public:
  // metal_layer is a CAMetalLayer* owned by the window, not by this surface.
  explicit MetalWindowSurface(void* metal_layer) : metal_layer_(metal_layer) {}

  TypeIndex GetType() const override { return kTypeIndex_AppleMetalLayer; }

  void* metal_layer() const { return metal_layer_; }

 protected:
  // Reports drawableSize -- physical pixels, already scaled by the backing
  // scale factor, which is what Surface's contract asks for.
  bool GetSizeImpl(uint32_t& width_out, uint32_t& height_out) const override;

 private:
  void* metal_layer_ = nullptr;
};

}  // namespace ui
}  // namespace rex
