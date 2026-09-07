/**
 * @file        ui/touch_overlay_uikit.mm
 * @brief       On-screen controls: the UIKit view (iOS).
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * Layout is a conventional mobile-FPS one because GoldenEye is a conventional
 * twin-stick shooter: a floating movement stick under the left thumb, drag-look
 * under the right, and the action buttons where the right thumb can reach
 * without leaving the look area (multi-touch, so holding fire and looking at
 * the same time is two fingers, not a compromise).
 *
 * Everything here writes to rex::ui::SetTouchPadState and nothing else. See
 * rex/ui/touch_controls.h for why the mapping is a synthesized gamepad.
 */

#include <rex/ui/touch_controls.h>

#include <rex/cvar.h>
#include <rex/filesystem.h>
#include <rex/logging.h>
#include <rex/ui/presenter.h>       // RawImage
#include <rex/ui/settings_uikit.h>
#include <rex/ui/screen_capture.h>  // WriteRawImagePng

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <cmath>
#include <string>

#include <dlfcn.h>

REXCVAR_DEFINE_STRING(touch_controls, "auto", "Input",
                      "On-screen controls: auto (hide while a controller is connected), "
                      "on (always show), off (never show)")
    .allowed({"auto", "on", "off"});
REXCVAR_DEFINE_DOUBLE(touch_look_sensitivity, 1.0, "Input",
                      "Drag-look sensitivity multiplier for the on-screen controls");
REXCVAR_DEFINE_DOUBLE(touch_look_scale, 4.0, "Input",
                      "Mouse counts per point of drag when the game exposes the mouse-look "
                      "injector (GoldenEye applies (counts/10)*ge_mouse_sens degrees, so at "
                      "the defaults a point of drag turns the view 0.4 deg). Multiplied by "
                      "touch_look_sensitivity.")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
REXCVAR_DEFINE_DOUBLE(touch_button_opacity, 0.28, "Input",
                      "Opacity of the on-screen control overlay (0..1)")
    .range(0.0, 1.0)
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
REXCVAR_DEFINE_DOUBLE(touch_button_scale, 1.0, "Input",
                      "Size of the on-screen buttons and the movement stick, as a multiple of "
                      "the default. Thumb size varies more than screen size does.")
    .range(0.5, 2.0)
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
REXCVAR_DEFINE_BOOL(touch_haptics, true, "Input",
                    "Tap the Taptic Engine when an on-screen button is pressed. A glass button "
                    "gives no other confirmation that a press registered.")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
REXCVAR_DEFINE_BOOL(show_fps, false, "GPU",
                    "Draw a frame-rate readout over the game. Reads the guest's own present "
                    "counter, so it reports what the player actually sees rather than what the "
                    "renderer attempted.")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
REXCVAR_DEFINE_BOOL(show_perf_hud, false, "GPU",
                    "Extend the frame-rate readout with thermal state, queued frame depth and "
                    "how far the GPU is behind the guest. Thermal state is the one that "
                    "invalidates comparisons, so it is worth having on screen while measuring.")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
REXCVAR_DEFINE_BOOL(touch_overlay_selftest, false, "Input",
                    "Write Documents/touch-overlay.png on the overlay's first frame. The "
                    "on-screen controls are UIKit, not guest output, so nothing else can "
                    "photograph them -- and on the simulator the GPU worker aborts before "
                    "any external screenshot lands.");

extern "C" const char* RexThermalStateName() {
  // Fable M-049: the paused benchmark drifted 30.7 -> 17 fps over minutes with
  // no changes, which makes every sequential A/B suspect. Thermal state is the
  // obvious candidate and was not visible over the bridge.
  switch (NSProcessInfo.processInfo.thermalState) {
    case NSProcessInfoThermalStateNominal:  return "nominal";
    case NSProcessInfoThermalStateFair:     return "fair";
    case NSProcessInfoThermalStateSerious:  return "serious";
    case NSProcessInfoThermalStateCritical: return "critical";
  }
  return "unknown";
}

namespace {

// XInput button bits, named here so the layout table below reads as controls
// rather than as magic numbers.
constexpr uint16_t kBtnA = 0x1000;
constexpr uint16_t kBtnB = 0x2000;
constexpr uint16_t kBtnX = 0x4000;
constexpr uint16_t kBtnY = 0x8000;
constexpr uint16_t kBtnStart = 0x0010;
constexpr uint16_t kBtnBack = 0x0020;

// Triggers are analogue on the 360 pad and GoldenEye fires on the right one.
// A touch button is binary, so it reports full deflection.
constexpr uint16_t kTriggerRight = 0xF001;  // sentinel, handled specially
constexpr uint16_t kTriggerLeft = 0xF002;

struct ButtonSpec {
  const char* label;
  uint16_t bits;
  // Position as a fraction of the safe-area size, measured from the RIGHT and
  // BOTTOM edges, so the cluster stays anchored to the thumb on any screen.
  CGFloat right_frac;
  CGFloat bottom_frac;
  CGFloat radius;
};

// Fire and Aim are largest and outermost, stacked on the right edge: they are
// held rather than tapped, and are what the thumb must find without looking.
// The four face buttons sit in a compact diamond just inboard of them, in the
// same arrangement as the pad they map to (A bottom, B right, X left, Y top),
// so muscle memory from the console layout carries over.
//
// Everything stays low and right. The first version of this table spread the
// buttons up and across the screen, which put SWAP out of thumb reach and left
// RELOAD sitting in the middle of the look area -- obvious the moment it was
// drawn, invisible in the numbers (M-045).
const ButtonSpec kButtons[] = {
    {"FIRE", kTriggerRight, 0.09f, 0.18f, 46.0f},
    {"AIM", kTriggerLeft, 0.09f, 0.42f, 38.0f},
    {"USE", kBtnA, 0.25f, 0.18f, 28.0f},
    {"CROUCH", kBtnB, 0.19f, 0.30f, 28.0f},
    {"RELOAD", kBtnX, 0.31f, 0.30f, 28.0f},
    {"SWAP", kBtnY, 0.25f, 0.42f, 28.0f},
    // Pause is deliberately far from everything else and small: it is pressed
    // between fights, and a mis-hit during one is a disaster.
    {"II", kBtnStart, 0.04f, 0.90f, 20.0f},
};

constexpr CGFloat kStickRadius = 62.0f;    // travel to full deflection
constexpr CGFloat kStickRegionFrac = 0.45f;  // left share of the screen
// The family's look feel is expressed per-120-Hz-frame, so a delta measured
// over a longer frame is scaled to what it would have been at 120 Hz. Without
// this the same drag turns further on a 60 Hz display than on a ProMotion one.
constexpr double kLookAnchorHz = 120.0;
constexpr double kLookGain = 0.055;  // stick deflection per point of drag

}  // namespace

@interface RexTouchOverlayView : UIView
@end

@implementation RexTouchOverlayView {
  // Touches are tracked by identity: a finger keeps its role for its whole
  // life, so sliding off a button does not silently become a look drag.
  UITouch* _stickTouch;
  CGPoint _stickOrigin;
  CGPoint _stickCurrent;

  UITouch* _lookTouch;
  CGPoint _lookLast;
  CGFloat _lookAccumX;
  CGFloat _lookAccumY;
  // Fractional mouse counts not yet emitted, so slow drags are not quantized
  // away by the integer injector interface.
  double _lookCarryX;
  double _lookCarryY;

  NSMutableDictionary<NSValue*, NSString*>* _buttonTouches;  // touch -> label
  NSMutableSet<NSString*>* _heldButtons;

  UIImpactFeedbackGenerator* _haptics;
  // The readout is a small label, NOT part of drawRect. Drawing it in the
  // full-screen view meant marking the whole view dirty every display-link
  // tick, which re-rasterises a 1260x2736 backing store on the CPU sixty times
  // a second. Measured on device: show_fps cost 2.5 fps of a 37 fps frame rate
  // (M-059), and it made the settings page feel like a freeze.
  UILabel* _hud;

  CADisplayLink* _link;
  CFTimeInterval _lastTick;
  CFTimeInterval _fpsLast;
  uint64_t _fpsLastPresented;
  double _fps;
  BOOL _loggedLayout;
  BOOL _wroteSelftest;
}

// Render the overlay to a PNG in Documents. Its own pixels, not the screen's:
// the controls are the thing being checked, and this runs whether or not the
// game underneath ever produced a frame.
- (void)writeSelftest {
  const CGSize size = self.bounds.size;
  if (size.width < 1 || size.height < 1) return;

  UIGraphicsImageRendererFormat* fmt = [UIGraphicsImageRendererFormat defaultFormat];
  fmt.scale = 1.0;   // one pixel per point keeps the PNG small and the maths obvious
  fmt.opaque = YES;  // over an opaque dark backdrop, since the game is not drawing here
  UIGraphicsImageRenderer* renderer =
      [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
  UIImage* image = [renderer imageWithActions:^(UIGraphicsImageRendererContext* c) {
    CGContextSetFillColorWithColor(c.CGContext, [UIColor colorWithWhite:0.1 alpha:1.0].CGColor);
    CGContextFillRect(c.CGContext, CGRectMake(0, 0, size.width, size.height));
    [self.layer renderInContext:c.CGContext];
  }];

  const uint32_t w = uint32_t(size.width), h = uint32_t(size.height);
  rex::ui::RawImage raw;
  raw.width = w;
  raw.height = h;
  raw.stride = size_t(w) * 4;
  raw.data.assign(raw.stride * h, 0);

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(raw.data.data(), w, h, 8, raw.stride, cs,
                                           kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    REXLOG_ERROR("touch overlay selftest: could not create bitmap context");
    return;
  }
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image.CGImage);
  CGContextRelease(ctx);

  auto path = rex::filesystem::GetDocumentsFolder() / "touch-overlay.png";
  if (rex::ui::WriteRawImagePng(path, raw)) {
    REXLOG_INFO("touch overlay selftest: wrote {} ({}x{})", path.string(), w, h);
  }
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.multipleTouchEnabled = YES;
  self.backgroundColor = UIColor.clearColor;
  self.opaque = NO;
  // The game view underneath must never receive these touches, but the overlay
  // must also not swallow anything outside its controls -- hitTest below draws
  // that line.
  self.userInteractionEnabled = YES;
  _buttonTouches = [NSMutableDictionary dictionary];
  _heldButtons = [NSMutableSet set];
  _haptics = [[UIImpactFeedbackGenerator alloc]
      initWithStyle:UIImpactFeedbackStyleLight];

  _hud = [[UILabel alloc] initWithFrame:CGRectZero];
  _hud.numberOfLines = 0;
  _hud.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
  _hud.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
  _hud.hidden = YES;
  _hud.userInteractionEnabled = NO;
  [self addSubview:_hud];

  _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
  [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  return self;
}

- (void)dealloc {
  [_link invalidate];
}

// --- geometry ------------------------------------------------------------

// Mark only the regions the controls occupy, rather than the whole screen. The
// view has to BE full-screen to receive touches, but it draws in two corners --
// and a full-screen invalidation re-rasterises the entire backing store on the
// CPU, which during a drag happened every single frame.
- (void)invalidateControls {
  UIEdgeInsets safe = self.safeAreaInsets;
  const CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
  const CGFloat r = [self stickRadius] + 40.0;
  if (_stickTouch) {
    [self setNeedsDisplayInRect:CGRectMake(_stickOrigin.x - r, _stickOrigin.y - r, r * 2, r * 2)];
  } else {
    // The resting ring, drawn at a fixed fraction of the safe area.
    CGPoint home = CGPointMake(safe.left + (w - safe.left - safe.right) * 0.16,
                               h - safe.bottom - (h - safe.top - safe.bottom) * 0.26);
    [self setNeedsDisplayInRect:CGRectMake(home.x - r, home.y - r, r * 2, r * 2)];
  }
  // The button cluster's bounding box, from the same table the buttons draw
  // from, so the two cannot drift apart.
  CGRect cluster = CGRectNull;
  for (const auto& spec : kButtons) {
    const CGPoint c = [self centreForButton:spec];
    const CGFloat br = [self radiusFor:spec] + 4.0;
    cluster = CGRectUnion(cluster, CGRectMake(c.x - br, c.y - br, br * 2, br * 2));
  }
  if (!CGRectIsNull(cluster)) [self setNeedsDisplayInRect:cluster];
}

- (CGPoint)centreForButton:(const ButtonSpec&)spec {
  UIEdgeInsets safe = self.safeAreaInsets;
  CGFloat w = self.bounds.size.width - safe.left - safe.right;
  CGFloat h = self.bounds.size.height - safe.top - safe.bottom;
  return CGPointMake(safe.left + w * (1.0f - spec.right_frac),
                     safe.top + h * (1.0f - spec.bottom_frac));
}

// Both radii are scaled by touch_button_scale rather than baked, because thumb
// size varies far more between players than screen size does. Read through
// these two helpers everywhere so hit-testing and drawing can never disagree
// about how big a button is.
- (CGFloat)buttonScale {
  return CGFloat(std::clamp(REXCVAR_GET(touch_button_scale), 0.5, 2.0));
}

- (CGFloat)radiusFor:(const ButtonSpec&)spec {
  return spec.radius * [self buttonScale];
}

- (CGFloat)stickRadius {
  return kStickRadius * [self buttonScale];
}

- (NSString*)buttonLabelAtPoint:(CGPoint)p {
  for (const auto& spec : kButtons) {
    CGPoint c = [self centreForButton:spec];
    CGFloat dx = p.x - c.x, dy = p.y - c.y;
    // A little larger than the drawn circle: the drawn size is what the eye
    // aims at, and fingers land short of what they aim at.
    CGFloat hit = [self radiusFor:spec] * 1.25f;
    if (dx * dx + dy * dy <= hit * hit) {
      return @(spec.label);
    }
  }
  return nil;
}

// --- touch handling ------------------------------------------------------

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  (void)event;
  for (UITouch* t in touches) {
    CGPoint p = [t locationInView:self];
    NSString* label = [self buttonLabelAtPoint:p];
    if (label) {
      const BOOL wasHeld = [_heldButtons containsObject:label];
      _buttonTouches[[NSValue valueWithNonretainedObject:t]] = label;
      [_heldButtons addObject:label];
      // Only on the transition to held: a second finger landing on an
      // already-held button is not a new press, and buzzing for it would make
      // held-fire feel like a fault.
      if (!wasHeld && REXCVAR_GET(touch_haptics)) {
        [_haptics impactOccurred];
        [_haptics prepare];
      }
    } else if (p.x < self.bounds.size.width * kStickRegionFrac) {
      // Floating stick: it appears wherever the thumb lands rather than at a
      // fixed spot, so the thumb never has to find it.
      if (!_stickTouch) {
        _stickTouch = t;
        _stickOrigin = p;
        _stickCurrent = p;
      }
    } else if (!_lookTouch) {
      _lookTouch = t;
      _lookLast = p;
    }
  }
  rex::ui::SetTouchControlsActive(true);
  [self invalidateControls];
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  (void)event;
  for (UITouch* t in touches) {
    CGPoint p = [t locationInView:self];
    if (t == _stickTouch) {
      _stickCurrent = p;
    } else if (t == _lookTouch) {
      _lookAccumX += p.x - _lookLast.x;
      _lookAccumY += p.y - _lookLast.y;
      _lookLast = p;
    }
    // Button touches deliberately ignore movement: sliding a held finger off
    // FIRE should not release it mid-firefight.
  }
  [self invalidateControls];
}

- (void)endTouches:(NSSet<UITouch*>*)touches {
  for (UITouch* t in touches) {
    NSValue* key = [NSValue valueWithNonretainedObject:t];
    NSString* label = _buttonTouches[key];
    if (label) {
      [_buttonTouches removeObjectForKey:key];
      // Only release the button if no OTHER finger is still on it.
      BOOL stillHeld = NO;
      for (NSString* other in _buttonTouches.allValues) {
        if ([other isEqualToString:label]) { stillHeld = YES; break; }
      }
      if (!stillHeld) [_heldButtons removeObject:label];
    }
    if (t == _stickTouch) {
      _stickTouch = nil;
      _stickOrigin = _stickCurrent = CGPointZero;
    }
    if (t == _lookTouch) {
      _lookTouch = nil;
      _lookAccumX = _lookAccumY = 0.0f;
    }
  }
  [self invalidateControls];
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  (void)event;
  [self endTouches:touches];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  (void)event;
  [self endTouches:touches];
}

// Let anything that is not one of our controls fall through to the view below,
// so the game still sees taps the overlay has no use for.
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
  if (self.hidden || self.alpha < 0.01) {
    return nil;
  }
  return [super hitTest:point withEvent:event];
}

// --- publishing ----------------------------------------------------------

- (void)tick:(CADisplayLink*)link {
  // A real controller wins: hide rather than paint thumbsticks over the game.
  // Sampled before the visibility check below: the readout must keep working
  // when the on-screen controls are hidden for a connected controller, which is
  // exactly when someone is measuring.
  // Nothing here has to run while the settings page is up, and the page is
  // heavy enough on a thermally clamped phone without the overlay repainting
  // underneath it.
  if (rex::ui::SettingsVisible()) {
    _hud.hidden = YES;
    return;
  }

  const BOOL detail = REXCVAR_GET(show_perf_hud);
  const BOOL readout = REXCVAR_GET(show_fps) || detail;
  _hud.hidden = !readout;
  if (readout) {
    uint64_t submitted = 0, presented = 0;
    rex::ui::GetGuestFrameCounters(&submitted, &presented);
    const CFTimeInterval now = link.timestamp;
    if (_fpsLast <= 0) {
      _fpsLast = now;
      _fpsLastPresented = presented;
    } else if (now - _fpsLast >= 0.5) {
      // Twice a second, and only then does the label change -- so the readout
      // costs two small text layouts a second instead of sixty full-screen
      // rasterisations.
      _fps = double(presented - _fpsLastPresented) / (now - _fpsLast);
      _fpsLast = now;
      _fpsLastPresented = presented;

      NSMutableString* text =
          [NSMutableString stringWithFormat:@" %.0f fps  %.1f ms ", _fps,
                                            _fps > 0 ? 1000.0 / _fps : 0.0];
      if (detail) {
        [text appendFormat:@"\n %s", RexThermalStateName()];
        [text appendFormat:@"  q%u ", rex::cvar::Query<uint32_t>("vulkan_max_queued_frames")];
        if (submitted > presented) [text appendFormat:@" -%llu ", submitted - presented];
      }
      _hud.text = text;
      // Colour carries the verdict at a glance, so a number seen from across
      // the room still means something.
      _hud.textColor = _fps >= 55.0   ? UIColor.systemGreenColor
                       : _fps >= 30.0 ? UIColor.systemYellowColor
                                      : UIColor.systemRedColor;
      [_hud sizeToFit];
      UIEdgeInsets safe = self.safeAreaInsets;
      CGRect f = _hud.frame;
      f.origin = CGPointMake(safe.left + 8, safe.top + 6);
      _hud.frame = f;
    }
  }

  const std::string mode = REXCVAR_GET(touch_controls);
  const BOOL pad = GCController.controllers.count > 0;
  // "auto" is what a phone wants: controls when there is nothing else driving,
  // out of the way the moment a pad appears. The explicit settings exist
  // because that rule is wrong for two real cases -- a player who wants both
  // (pad in hand, thumb on the glass for a button the pad lacks), and a
  // simulator, which reports a controller whether or not one exists.
  const BOOL wanted = (mode == "on") || (mode == "auto" && !pad);
  if (self.hidden == wanted) {
    self.hidden = !wanted;
    if (!wanted) {
      rex::ui::SetTouchPadState(rex::ui::TouchPadState{});
      rex::ui::SetTouchControlsActive(false);
    }
    REXLOG_INFO("touch controls: {} (mode={}, controller={})", wanted ? "shown" : "hidden",
                mode, pad ? "yes" : "no");
  }
  if (!wanted) {
    // Still visible as a view when only the readout is on, so the FPS text has
    // somewhere to land.
    self.hidden = !(REXCVAR_GET(show_fps) || REXCVAR_GET(show_perf_hud));
    return;
  }

  rex::ui::TouchPadState state;

  if (_stickTouch) {
    // UIKit's y grows downward; the thumbstick's grows up.
    rex::ui::ApplyStickResponse(_stickCurrent.x - _stickOrigin.x,
                                -(_stickCurrent.y - _stickOrigin.y), [self stickRadius],
                                &state.thumb_lx, &state.thumb_ly);
  }

  // Drag-look. Preferred path: the game's mouse-look pipeline (GeInjectLookDelta,
  // resolved once at runtime -- it lives in the game binary, above this dylib).
  // Absolute angle deltas are rate-independent: a fast swipe turns exactly as
  // far as a slow one of the same length, where the old right-stick mapping
  // saturated at +/-1.0 and capped every swipe at the game's fixed stick turn
  // rate -- the "several big swipes to look left" complaint. The stick path
  // remains as the fallback when the injector is absent.
  static void (*inject_look)(int, int) = reinterpret_cast<void (*)(int, int)>(
      dlsym(RTLD_DEFAULT, "GeInjectLookDelta"));
  const CFTimeInterval now = link.timestamp;
  const double dt = (_lastTick > 0) ? (now - _lastTick) : (1.0 / kLookAnchorHz);
  _lastTick = now;
  if (_lookAccumX != 0.0f || _lookAccumY != 0.0f) {
    if (inject_look) {
      const double scale =
          REXCVAR_GET(touch_look_scale) * REXCVAR_GET(touch_look_sensitivity);
      _lookCarryX += _lookAccumX * scale;
      _lookCarryY += _lookAccumY * scale;
      const int dx = static_cast<int>(_lookCarryX);
      const int dy = static_cast<int>(_lookCarryY);
      if (dx != 0 || dy != 0) {
        inject_look(dx, dy);
        _lookCarryX -= dx;
        _lookCarryY -= dy;
      }
    } else if (dt > 0.0) {
      // Normalise this frame's delta to the 120 Hz anchor the family's feel
      // constants are expressed against.
      const double frames = dt * kLookAnchorHz;
      const double gain =
          kLookGain * REXCVAR_GET(touch_look_sensitivity) / std::max(frames, 0.0001);
      const double rx = std::clamp(_lookAccumX * gain, -1.0, 1.0);
      const double ry = std::clamp(-_lookAccumY * gain, -1.0, 1.0);
      state.thumb_rx = static_cast<int16_t>(std::lround(rx * 32767.0));
      state.thumb_ry = static_cast<int16_t>(std::lround(ry * 32767.0));
    }
  }
  // A finger that stops moving must stop the view: both accumulators empty
  // every tick regardless of which path consumed them.
  _lookAccumX = _lookAccumY = 0.0f;

  for (NSString* label in _heldButtons) {
    for (const auto& spec : kButtons) {
      if (![label isEqualToString:@(spec.label)]) continue;
      if (spec.bits == kTriggerRight) {
        state.right_trigger = 255;
      } else if (spec.bits == kTriggerLeft) {
        state.left_trigger = 255;
      } else {
        state.buttons |= spec.bits;
      }
    }
  }

  rex::ui::SetTouchPadState(state);
  if (_stickTouch || _heldButtons.count) {
    // A look drag alone changes nothing that is drawn, so it no longer forces a
    // repaint -- that alone was a full-screen rasterisation per frame for the
    // whole time a thumb was moving.
    [self invalidateControls];
  }
}

// --- drawing -------------------------------------------------------------

- (void)drawRect:(CGRect)rect {
  (void)rect;
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  const CGFloat alpha = std::clamp(REXCVAR_GET(touch_button_opacity), 0.0, 1.0);

  auto stroke = [&](CGPoint c, CGFloat r, CGFloat a, BOOL filled) {
    CGContextSetLineWidth(ctx, 2.5);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:a].CGColor);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - r, c.y - r, r * 2, r * 2));
    if (filled) {
      CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:a * 0.4].CGColor);
      CGContextFillEllipseInRect(ctx, CGRectMake(c.x - r, c.y - r, r * 2, r * 2));
    }
  };

  // The frame-rate readout is _hud, a separate label -- see the ivar's comment.
  // Drawing it here marked the whole full-screen view dirty every tick, which
  // cost 2.5 fps of a 37 fps frame rate on device (M-059).

  for (const auto& spec : kButtons) {
    CGPoint c = [self centreForButton:spec];
    NSString* label = @(spec.label);
    const BOOL held = [_heldButtons containsObject:label];
    stroke(c, [self radiusFor:spec], held ? alpha * 2.0 : alpha, held);

    NSDictionary* attrs = @{
      NSFontAttributeName : [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
      NSForegroundColorAttributeName : [UIColor colorWithWhite:1.0 alpha:alpha * 2.2],
    };
    CGSize size = [label sizeWithAttributes:attrs];
    [label drawAtPoint:CGPointMake(c.x - size.width / 2, c.y - size.height / 2)
        withAttributes:attrs];
  }

  // With no thumb down the stick has nowhere to be, but a completely blank left
  // half reads as "nothing here". A faint resting ring in the natural thumb
  // position says otherwise without becoming clutter; it is replaced by the
  // real stick the moment a thumb lands anywhere in the region.
  if (!_stickTouch) {
    UIEdgeInsets safe = self.safeAreaInsets;
    CGPoint home = CGPointMake(safe.left + (self.bounds.size.width - safe.left - safe.right) * 0.16,
                               self.bounds.size.height - safe.bottom -
                                   (self.bounds.size.height - safe.top - safe.bottom) * 0.26);
    stroke(home, [self stickRadius], alpha * 0.55, NO);
    NSDictionary* hint = @{
      NSFontAttributeName : [UIFont systemFontOfSize:10 weight:UIFontWeightMedium],
      NSForegroundColorAttributeName : [UIColor colorWithWhite:1.0 alpha:alpha * 1.2],
    };
    NSString* label = @"MOVE";
    CGSize size = [label sizeWithAttributes:hint];
    [label drawAtPoint:CGPointMake(home.x - size.width / 2, home.y - size.height / 2)
        withAttributes:hint];
  }

  if (_stickTouch) {
    const CGFloat r = [self stickRadius];
    stroke(_stickOrigin, r, alpha * 1.6, NO);
    CGFloat dx = _stickCurrent.x - _stickOrigin.x;
    CGFloat dy = _stickCurrent.y - _stickOrigin.y;
    CGFloat len = std::sqrt(dx * dx + dy * dy);
    if (len > r) {
      dx *= r / len;
      dy *= r / len;
    }
    stroke(CGPointMake(_stickOrigin.x + dx, _stickOrigin.y + dy), 26.0 * [self buttonScale],
           alpha * 2.0, YES);
  }
}

- (void)layoutSubviews {
  [super layoutSubviews];
  if (!_loggedLayout) {
    _loggedLayout = YES;
    // Charter rule: a UIKit placement is believed when the view logs its frame.
    CGPoint fire = [self centreForButton:kButtons[0]];
    REXLOG_INFO("touch overlay: frame {:.0f}x{:.0f}, FIRE at ({:.0f},{:.0f})",
                self.bounds.size.width, self.bounds.size.height, fire.x, fire.y);
  }
  // Snapshot from layout rather than from the display link: the run loop does
  // not turn until OnInitialize returns, and on the simulator the GPU worker
  // aborts before that happens -- so a display-link-driven selftest never fires
  // exactly where it is most needed.
  if (!_wroteSelftest && REXCVAR_GET(touch_overlay_selftest) && self.bounds.size.width > 1) {
    _wroteSelftest = YES;
    [self writeSelftest];
  }
}

@end

// The gear is the only route to the settings page, so it is a sibling of the
// overlay rather than one of its buttons: the overlay hides itself whenever a
// controller is connected, and settings must stay reachable then -- that is
// precisely when someone wants to change the on-screen-controls mode back.
@interface RexSettingsButtonTarget : NSObject
@end

@implementation RexSettingsButtonTarget
- (void)tapped {
  rex::ui::PresentSettings();
}
@end

namespace {
// Held for the process lifetime: a UIButton does not retain its target, and the
// overlay is never torn down.
RexSettingsButtonTarget* g_settings_target = nil;
}  // namespace

namespace rex {
namespace ui {

void AttachTouchOverlay(void* parent_view) {
  UIView* parent = (__bridge UIView*)parent_view;
  if (!parent) {
    REXLOG_ERROR("touch overlay: no parent view");
    return;
  }
  auto* overlay = [[RexTouchOverlayView alloc] initWithFrame:parent.bounds];
  overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [parent addSubview:overlay];

  g_settings_target = [RexSettingsButtonTarget new];
  UIButton* gear = [UIButton buttonWithType:UIButtonTypeSystem];
  [gear setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
  gear.tintColor = [UIColor colorWithWhite:1.0 alpha:0.55];
  gear.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.30];
  gear.layer.cornerRadius = 17.0;
  gear.translatesAutoresizingMaskIntoConstraints = NO;
  [gear addTarget:g_settings_target
                action:@selector(tapped)
      forControlEvents:UIControlEventTouchUpInside];
  [parent addSubview:gear];
  // Top-right, inside the safe area: the game's own HUD lives along the bottom
  // and in the lower corners, so this is the one region nothing else claims.
  UILayoutGuide* safe = parent.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [gear.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
    [gear.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
    [gear.widthAnchor constraintEqualToConstant:34],
    [gear.heightAnchor constraintEqualToConstant:34],
  ]];
  // Lay out now rather than waiting for the next run-loop turn. Boot occupies
  // the main thread from here until the guest is up, so the first natural
  // layout pass is a long way off -- and if boot fails there is never one at
  // all, which is exactly when the frame log and the selftest are wanted.
  [overlay layoutIfNeeded];
  REXLOG_INFO("touch overlay: attached");
}

}  // namespace ui
}  // namespace rex
