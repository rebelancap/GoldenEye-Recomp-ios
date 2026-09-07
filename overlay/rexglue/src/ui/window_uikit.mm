/**
 * @file        ui/window_uikit.mm
 * @brief       UIKit window backing rex::ui::Window on iOS / visionOS.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * Differences from the macOS backend that matter:
 *  - There is exactly one window, always full-screen. No chrome, no title, no
 *    fullscreen toggle, no close button -- so most Apply* hooks stay defaulted.
 *  - UIKit owns the run loop (UIApplicationMain), so the app context does not
 *    start one; see windowed_app_context_uikit.mm.
 *  - The layer is supplied by overriding +layerClass rather than by assigning
 *    view.layer, which UIKit does not allow.
 */

#include <rex/ui/window_uikit.h>

#include <algorithm>

#include <rex/cvar.h>
#include <rex/graphics/video_mode_util.h>
#include <rex/logging.h>
#include <rex/ui/menu_item.h>
#include <rex/ui/surface_apple.h>
#include <rex/ui/windowed_app_context.h>

#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>

namespace {

// The startup-size cvars are meaningless on a device -- the screen decides. The
// resolvers exist because rex::ui::Window::Create is shared code that calls
// them; here they just pass the request through.
uint32_t ResolveWindowWidth(uint32_t requested_width) { return requested_width; }
uint32_t ResolveWindowHeight(uint32_t requested_height) { return requested_height; }

}  // namespace

// ---------------------------------------------------------------------------
// View + controller
// ---------------------------------------------------------------------------

@interface RexMetalView : UIView
@end

@implementation RexMetalView
+ (Class)layerClass {
  return [CAMetalLayer class];
}
@end

@interface RexViewController : UIViewController
@property(nonatomic, assign) rex::ui::UIKitWindow* owner;
@end

@implementation RexViewController

- (void)loadView {
  self.view = [[RexMetalView alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.view.contentScaleFactor = UIScreen.mainScreen.nativeScale;
  self.view.multipleTouchEnabled = YES;
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  if (self.owner) {
    self.owner->HandleResize();
  }
}

// The game is landscape; the guest renders 16:9 and has no portrait layout.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return UIInterfaceOrientationMaskLandscape;
}

- (BOOL)prefersStatusBarHidden {
  return YES;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
  return YES;
}

@end

namespace rex {
namespace ui {

std::unique_ptr<Window> Window::Create(WindowedAppContext& app_context, const std::string_view title,
                                       uint32_t desired_logical_width,
                                       uint32_t desired_logical_height) {
  return std::make_unique<UIKitWindow>(app_context, title,
                                       ResolveWindowWidth(desired_logical_width),
                                       ResolveWindowHeight(desired_logical_height));
}

UIKitWindow::UIKitWindow(WindowedAppContext& app_context, const std::string_view title,
                         uint32_t desired_logical_width, uint32_t desired_logical_height)
    : Window(app_context, title, desired_logical_width, desired_logical_height) {}

UIKitWindow::~UIKitWindow() {
  EnterDestructor();
  @autoreleasepool {
    if (ui_window_) {
      UIWindow* window = (__bridge_transfer UIWindow*)ui_window_;
      window.hidden = YES;
      ui_window_ = nullptr;
    }
    if (view_controller_) {
      CFRelease(view_controller_);
      view_controller_ = nullptr;
    }
    metal_layer_ = nullptr;
  }
}

bool UIKitWindow::OpenImpl() {
  @autoreleasepool {
    UIWindow* window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    if (!window) {
      REXLOG_ERROR("UIKitWindow: UIWindow creation failed");
      return false;
    }
    RexViewController* controller = [[RexViewController alloc] init];
    controller.owner = this;
    window.rootViewController = controller;
    [window makeKeyAndVisible];

    ui_window_ = (__bridge_retained void*)window;
    view_controller_ = (__bridge_retained void*)controller;
    metal_layer_ = (__bridge void*)controller.view.layer;

    HandleResize();

    // iOS windows are always "focused" -- there is no other window to lose it
    // to, and backgrounding is a lifecycle event, not a focus change.
    WindowDestructionReceiver destruction_receiver(this);
    OnFocusUpdate(true, destruction_receiver);
    return true;
  }
}

void UIKitWindow::RequestCloseImpl() {
  // iOS apps do not close themselves; the system terminates them. Report the
  // request so the app can persist state, but do nothing else.
  WindowDestructionReceiver destruction_receiver(this);
  OnBeforeClose(destruction_receiver);
}

void UIKitWindow::HandleResize() {
  @autoreleasepool {
    RexViewController* controller = (__bridge RexViewController*)view_controller_;
    CAMetalLayer* layer = (__bridge CAMetalLayer*)metal_layer_;
    if (!controller || !layer) {
      return;
    }
    const CGFloat scale = UIScreen.mainScreen.nativeScale > 0 ? UIScreen.mainScreen.nativeScale : 1.0;
    const CGRect bounds = controller.view.bounds;
    layer.contentsScale = scale;
    layer.drawableSize = CGSizeMake(bounds.size.width * scale, bounds.size.height * scale);

    WindowDestructionReceiver destruction_receiver(this);
    OnActualSizeUpdate(uint32_t(bounds.size.width * scale), uint32_t(bounds.size.height * scale),
                       destruction_receiver);
  }
}

void UIKitWindow::HandlePaint() {
  paint_pending_ = false;
  OnPaint();
}

uint32_t UIKitWindow::GetLatestDpiImpl() const {
  @autoreleasepool {
    const CGFloat scale = UIScreen.mainScreen.nativeScale > 0 ? UIScreen.mainScreen.nativeScale : 1.0;
    return uint32_t(GetMediumDpi() * scale);
  }
}

std::unique_ptr<Surface> UIKitWindow::CreateSurfaceImpl(Surface::TypeFlags allowed_types) {
  if (!(allowed_types & Surface::kTypeFlag_AppleMetalLayer) || !metal_layer_) {
    return nullptr;
  }
  return std::make_unique<MetalWindowSurface>(metal_layer_);
}

void UIKitWindow::RequestPaintImpl() {
  if (paint_pending_) {
    return;
  }
  paint_pending_ = true;
  // Coalesce to one paint per main-loop turn. A CADisplayLink belongs here
  // eventually (docs/pacing.md), but pacing is a deliberate design step, not
  // something to fall into by accident.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (paint_pending_) {
      HandlePaint();
    }
  });
}

// The Window framework needs a MenuItem factory per platform. iOS has no menu
// bar and GoldenEye's pause menu is ImGui, so this is a plain data holder.
namespace {
class UIKitMenuItem final : public MenuItem {
 public:
  UIKitMenuItem(Type type, const std::string& text, const std::string& hotkey,
                std::function<void()> callback)
      : MenuItem(type, text, hotkey, std::move(callback)) {}
};
}  // namespace

std::unique_ptr<ui::MenuItem> MenuItem::Create(Type type, const std::string& text,
                                               const std::string& hotkey,
                                               std::function<void()> callback) {
  return std::make_unique<UIKitMenuItem>(type, text, hotkey, std::move(callback));
}

}  // namespace ui
}  // namespace rex
