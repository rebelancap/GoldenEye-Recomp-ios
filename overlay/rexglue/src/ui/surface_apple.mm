/**
 * @file        ui/surface_apple.mm
 * @brief       CAMetalLayer-backed surface.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 */

#include <rex/ui/surface_apple.h>

#import <QuartzCore/CAMetalLayer.h>

namespace rex {
namespace ui {

bool MetalWindowSurface::GetSizeImpl(uint32_t& width_out, uint32_t& height_out) const {
  CAMetalLayer* layer = (__bridge CAMetalLayer*)metal_layer_;
  if (!layer) {
    return false;
  }
  // drawableSize is in physical pixels (bounds * contentsScale), which is what
  // Surface asks for -- not points.
  const CGSize size = layer.drawableSize;
  if (size.width <= 0.0 || size.height <= 0.0) {
    return false;
  }
  width_out = uint32_t(size.width);
  height_out = uint32_t(size.height);
  return true;
}

}  // namespace ui
}  // namespace rex
