/**
 * @file        ui/window_apple.mm
 * @brief       Cocoa/AppKit window backing rex::ui::Window on Apple platforms.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * Scope note: this is the Phase 0.5 bring-up window. It creates a layer-hosting
 * NSView backed by a CAMetalLayer, tracks size/focus/close, and drives painting
 * from a CVDisplayLink-free timer on the main run loop. Keyboard and mouse
 * event plumbing is deliberately NOT here yet -- this port is controller-first
 * (charter Phase 1) and the immediate goal is pixels on screen. See
 * docs/frame-map.md.
 */

#include <rex/ui/window_apple.h>

#include <algorithm>

#include <rex/cvar.h>
#include <rex/graphics/video_mode_util.h>
#include <rex/logging.h>
#include <rex/ui/menu_item.h>
#include <rex/ui/surface_apple.h>
#include <rex/ui/windowed_app_context.h>

#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>

namespace {

// Identical to the GTK and Win32 backends' resolvers -- the startup size comes
// from the window_* cvars, falling back to the video-mode / resolution preset.
uint32_t ResolveWindowWidth(uint32_t requested_width) {
  if (REXCVAR_GET(window_width) > 0) {
    return uint32_t(REXCVAR_GET(window_width));
  }
  if (!rex::cvar::HasNonDefaultValue("window_width")) {
    if (rex::cvar::HasNonDefaultValue("video_mode_width") && REXCVAR_GET(video_mode_width) > 0) {
      return uint32_t(std::clamp(REXCVAR_GET(video_mode_width), 1, 8192));
    }
    int32_t preset_width = 0;
    int32_t preset_height = 0;
    if (rex::graphics::video_mode_util::TryGetResolutionPresetFromCVar(preset_width,
                                                                       preset_height)) {
      return uint32_t(std::clamp(preset_width, 1, 8192));
    }
  }
  return requested_width;
}

uint32_t ResolveWindowHeight(uint32_t requested_height) {
  if (REXCVAR_GET(window_height) > 0) {
    return uint32_t(REXCVAR_GET(window_height));
  }
  if (!rex::cvar::HasNonDefaultValue("window_height")) {
    if (rex::cvar::HasNonDefaultValue("video_mode_height") && REXCVAR_GET(video_mode_height) > 0) {
      return uint32_t(std::clamp(REXCVAR_GET(video_mode_height), 1, 8192));
    }
    int32_t preset_width = 0;
    int32_t preset_height = 0;
    if (rex::graphics::video_mode_util::TryGetResolutionPresetFromCVar(preset_width,
                                                                       preset_height)) {
      return uint32_t(std::clamp(preset_height, 1, 8192));
    }
  }
  return requested_height;
}

}  // namespace

// ---------------------------------------------------------------------------
// Delegate + view
// ---------------------------------------------------------------------------

@interface RexWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, assign) rex::ui::AppleWindow* owner;
@end

@implementation RexWindowDelegate

- (BOOL)windowShouldClose:(NSWindow*)sender {
  (void)sender;
  if (self.owner) {
    self.owner->HandleCloseRequest();
  }
  // Never close directly -- the Window life cycle decides, and closing behind
  // its back would destroy the surface the presenter is still painting to.
  return NO;
}

- (void)windowDidResize:(NSNotification*)notification {
  (void)notification;
  if (self.owner) {
    self.owner->HandleResize();
  }
}

- (void)windowDidChangeBackingProperties:(NSNotification*)notification {
  (void)notification;
  if (self.owner) {
    self.owner->HandleResize();
  }
}

- (void)windowDidBecomeKey:(NSNotification*)notification {
  (void)notification;
  if (self.owner) {
    self.owner->HandleFocus(true);
  }
}

- (void)windowDidResignKey:(NSNotification*)notification {
  (void)notification;
  if (self.owner) {
    self.owner->HandleFocus(false);
  }
}

@end

// A layer-hosting view: we supply the CAMetalLayer rather than letting AppKit
// make one, so the same layer pointer can be handed to VK_EXT_metal_surface.
@interface RexMetalView : NSView
@end

@implementation RexMetalView

- (BOOL)wantsUpdateLayer {
  return YES;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)isOpaque {
  return YES;
}

@end

namespace rex {
namespace ui {

std::unique_ptr<Window> Window::Create(WindowedAppContext& app_context, const std::string_view title,
                                       uint32_t desired_logical_width,
                                       uint32_t desired_logical_height) {
  desired_logical_width = ResolveWindowWidth(desired_logical_width);
  desired_logical_height = ResolveWindowHeight(desired_logical_height);
  return std::make_unique<AppleWindow>(app_context, title, desired_logical_width,
                                       desired_logical_height);
}

AppleWindow::AppleWindow(WindowedAppContext& app_context, const std::string_view title,
                         uint32_t desired_logical_width, uint32_t desired_logical_height)
    : Window(app_context, title, desired_logical_width, desired_logical_height) {}

AppleWindow::~AppleWindow() {
  EnterDestructor();
  @autoreleasepool {
    if (ns_window_) {
      NSWindow* window = (__bridge_transfer NSWindow*)ns_window_;
      window.delegate = nil;
      [window close];
      ns_window_ = nullptr;
    }
    if (delegate_) {
      CFRelease(delegate_);
      delegate_ = nullptr;
    }
    // content_view_ and metal_layer_ are owned by the window's view hierarchy.
    content_view_ = nullptr;
    metal_layer_ = nullptr;
  }
}

bool AppleWindow::OpenImpl() {
  @autoreleasepool {
    const uint32_t logical_width = std::max(GetDesiredLogicalWidth(), uint32_t(1));
    const uint32_t logical_height = std::max(GetDesiredLogicalHeight(), uint32_t(1));

    const NSRect content_rect = NSMakeRect(0, 0, logical_width, logical_height);
    const NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                    NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;

    NSWindow* window = [[NSWindow alloc] initWithContentRect:content_rect
                                                  styleMask:style
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    if (!window) {
      REXLOG_ERROR("AppleWindow: NSWindow creation failed");
      return false;
    }
    window.releasedWhenClosed = NO;
    window.acceptsMouseMovedEvents = YES;

    const std::string title(GetTitle());
    window.title = [NSString stringWithUTF8String:title.c_str()];

    RexMetalView* view = [[RexMetalView alloc] initWithFrame:content_rect];
    CAMetalLayer* layer = [CAMetalLayer layer];
    layer.opaque = YES;
    layer.needsDisplayOnBoundsChange = YES;
    layer.presentsWithTransaction = NO;
    view.layer = layer;
    view.wantsLayer = YES;
    window.contentView = view;
    [window makeFirstResponder:view];

    RexWindowDelegate* delegate = [[RexWindowDelegate alloc] init];
    delegate.owner = this;
    window.delegate = delegate;

    ns_window_ = (__bridge_retained void*)window;
    delegate_ = (__bridge_retained void*)delegate;
    content_view_ = (__bridge void*)view;
    metal_layer_ = (__bridge void*)layer;

    // Match the layer's pixel size to the display before anyone asks for it.
    HandleResize();

    [window center];
    [window makeKeyAndOrderFront:nil];

    if (IsFullscreen()) {
      ApplyNewFullscreen();
    }

    WindowDestructionReceiver destruction_receiver(this);
    OnFocusUpdate(true, destruction_receiver);
    return true;
  }
}

void AppleWindow::RequestCloseImpl() {
  // The Window life cycle drives destruction; just report the request.
  HandleCloseRequest();
}

void AppleWindow::HandleCloseRequest() {
  WindowDestructionReceiver destruction_receiver(this);
  OnBeforeClose(destruction_receiver);
  if (destruction_receiver.IsWindowDestroyed()) {
    return;
  }
  app_context().QuitFromUIThread();
}

void AppleWindow::HandleResize() {
  @autoreleasepool {
    NSWindow* window = (__bridge NSWindow*)ns_window_;
    NSView* view = (__bridge NSView*)content_view_;
    CAMetalLayer* layer = (__bridge CAMetalLayer*)metal_layer_;
    if (!window || !view || !layer) {
      return;
    }
    const CGFloat scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 1.0;
    const NSRect bounds = view.bounds;
    layer.contentsScale = scale;
    layer.drawableSize = CGSizeMake(bounds.size.width * scale, bounds.size.height * scale);

    // Report physical pixels -- Window's contract, and what the presenter needs.
    WindowDestructionReceiver destruction_receiver(this);
    OnActualSizeUpdate(uint32_t(bounds.size.width * scale), uint32_t(bounds.size.height * scale),
                       destruction_receiver);
    // DPI is pulled by the base through GetLatestDpiImpl(); there is nothing to
    // push here.
  }
}

void AppleWindow::HandleFocus(bool focused) {
  WindowDestructionReceiver destruction_receiver(this);
  OnFocusUpdate(focused, destruction_receiver);
}

void AppleWindow::HandlePaint() {
  paint_pending_ = false;
  OnPaint();
}

uint32_t AppleWindow::GetLatestDpiImpl() const {
  @autoreleasepool {
    NSWindow* window = (__bridge NSWindow*)ns_window_;
    const CGFloat scale = (window && window.backingScaleFactor > 0) ? window.backingScaleFactor
                                                                    : 1.0;
    // GetMediumDpi() is 96; a Retina window reports 2.0 -> 192.
    return uint32_t(GetMediumDpi() * scale);
  }
}

void AppleWindow::ApplyNewTitle() {
  @autoreleasepool {
    NSWindow* window = (__bridge NSWindow*)ns_window_;
    if (!window) {
      return;
    }
    const std::string title(GetTitle());
    window.title = [NSString stringWithUTF8String:title.c_str()];
  }
}

void AppleWindow::ApplyNewFullscreen() {
  @autoreleasepool {
    NSWindow* window = (__bridge NSWindow*)ns_window_;
    if (!window) {
      return;
    }
    const bool is_fullscreen = (window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    if (is_fullscreen != IsFullscreen()) {
      [window toggleFullScreen:nil];
    }
  }
}

void AppleWindow::FocusImpl() {
  @autoreleasepool {
    NSWindow* window = (__bridge NSWindow*)ns_window_;
    if (window) {
      [window makeKeyAndOrderFront:nil];
    }
  }
}

std::unique_ptr<Surface> AppleWindow::CreateSurfaceImpl(Surface::TypeFlags allowed_types) {
  if (!(allowed_types & Surface::kTypeFlag_AppleMetalLayer) || !metal_layer_) {
    return nullptr;
  }
  return std::make_unique<MetalWindowSurface>(metal_layer_);
}

void AppleWindow::RequestPaintImpl() {
  if (paint_pending_) {
    return;
  }
  paint_pending_ = true;
  // Coalesce to one paint per main-loop turn. Deliberately NOT a CVDisplayLink
  // or CADisplayLink yet -- pacing gets designed on purpose in docs/pacing.md
  // (charter Phase 1: "exactly one present per rendered frame").
  dispatch_async(dispatch_get_main_queue(), ^{
    if (paint_pending_) {
      HandlePaint();
    }
  });
}

}  // namespace ui
}  // namespace rex

namespace rex {
namespace ui {

// The Window framework requires a MenuItem factory per platform. GoldenEye does
// not build an in-window menu bar (the pause menu is ImGui, and macOS owns the
// real menu bar), so this is a plain data-holding item with no native peer.
// If a native NSMenu is ever wanted, subclass here -- nothing else changes.
namespace {
class AppleMenuItem final : public MenuItem {
 public:
  AppleMenuItem(Type type, const std::string& text, const std::string& hotkey,
                std::function<void()> callback)
      : MenuItem(type, text, hotkey, std::move(callback)) {}
};
}  // namespace

std::unique_ptr<ui::MenuItem> MenuItem::Create(Type type, const std::string& text,
                                               const std::string& hotkey,
                                               std::function<void()> callback) {
  return std::make_unique<AppleMenuItem>(type, text, hotkey, std::move(callback));
}

}  // namespace ui
}  // namespace rex
