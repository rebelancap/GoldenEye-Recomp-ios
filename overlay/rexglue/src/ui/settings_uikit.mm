/**
 * @file        ui/settings_uikit.mm
 * @brief       The native settings page (iOS / visionOS).
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * See rex/ui/settings_uikit.h for why a native page rather than the SDK's ImGui
 * settings overlay.
 *
 * Every row is a view onto a cvar, addressed by name through the string API
 * (GetFlagByName / SetFlagByName) rather than through REXCVAR_GET. That is
 * deliberate: several of the interesting cvars are defined in the game binary
 * or in the GPU backend, neither of which this translation unit links against,
 * and a row that names a cvar which no longer exists must degrade to "hidden"
 * rather than to "fails to link". Rows whose cvar is missing are dropped at
 * table-build time and logged, so a renamed cvar upstream is visible in the log
 * instead of silently doing nothing when tapped.
 */

#include <rex/ui/settings_uikit.h>

#include <rex/cvar.h>
#include <rex/filesystem.h>
#include <rex/logging.h>
#include <rex/ui/touch_controls.h>

#import <UIKit/UIKit.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <string>

REXCVAR_DEFINE_BOOL(settings_selftest, false, "Input",
                    "Open the settings page a few seconds after launch. The page is UIKit, and "
                    "no synthetic touch reaches UIKit on this runtime (idb ui tap is dead on "
                    "iOS 27), so this is the only way the simulator gate can photograph it.");
REXCVAR_DEFINE_DOUBLE(settings_selftest_delay_s, 6.0, "Input",
                      "Seconds to wait before the settings selftest opens the page. Long enough "
                      "for either the first-run screen or the game window to exist.");

namespace {

// ---------------------------------------------------------------------------
// cvar access
// ---------------------------------------------------------------------------

bool CvarExists(NSString* name) {
  return rex::cvar::GetFlagInfo(name.UTF8String) != nullptr;
}

NSString* CvarString(NSString* name) {
  return @(rex::cvar::GetFlagByName(name.UTF8String).c_str());
}

bool CvarBool(NSString* name) { return CvarString(name).boolValue; }

double CvarDouble(NSString* name) { return CvarString(name).doubleValue; }

// Every write goes through here so that "changed" and "persisted" cannot drift
// apart. SaveConfig writes only cvars that differ from their default, so this
// stays a small file no matter how many rows exist.
void CvarSet(NSString* name, NSString* value) {
  if (!rex::cvar::SetFlagByName(name.UTF8String, value.UTF8String)) {
    REXLOG_ERROR("settings: {} rejected value '{}'", name.UTF8String, value.UTF8String);
    return;
  }
  REXLOG_INFO("settings: {} = {}", name.UTF8String, CvarString(name).UTF8String);
}

void CvarSetBool(NSString* name, bool on) { CvarSet(name, on ? @"true" : @"false"); }

void CvarSetDouble(NSString* name, double v) {
  // Integer-typed cvars reject "2.000000", so format by the registry's type
  // rather than by the control's.
  const auto* info = rex::cvar::GetFlagInfo(name.UTF8String);
  const bool integral = info && (info->type == rex::cvar::FlagType::Int32 ||
                                 info->type == rex::cvar::FlagType::Int64 ||
                                 info->type == rex::cvar::FlagType::Uint32 ||
                                 info->type == rex::cvar::FlagType::Uint64);
  CvarSet(name, integral ? [NSString stringWithFormat:@"%lld", (long long)std::llround(v)]
                         : [NSString stringWithFormat:@"%.3f", v]);
}

// View tags. The value label of a slider row and the control itself live in the
// same little container, so they must not collide -- and "section*1000 + row"
// reaches 1 for the second row of the first section, which is why the controls
// are offset well clear of the fixed tags rather than starting at zero.
constexpr NSInteger kValueLabelTag = 7;
constexpr NSInteger kControlTagBase = 100000;

}  // namespace

// ---------------------------------------------------------------------------
// Row / section model
// ---------------------------------------------------------------------------

typedef NS_ENUM(NSInteger, RexRowKind) {
  RexRowSwitch,
  RexRowSlider,
  RexRowSegmented,
  RexRowInfo,    // live read-only readout
  RexRowAction,  // tappable
};

@interface RexSettingsRow : NSObject
@property(nonatomic) RexRowKind kind;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* cvar;
/// Switch rows only: the cvar reads inverted, so "on" in the UI means false in
/// the registry. Used where the honest cvar name is a workaround's name and the
/// player-facing name is the feature it disables.
@property(nonatomic) BOOL inverted;
@property(nonatomic) double min;
@property(nonatomic) double max;
/// Segmented rows: what the player sees, and what goes into the cvar.
@property(nonatomic, copy) NSArray<NSString*>* labels;
@property(nonatomic, copy) NSArray<NSString*>* values;
/// Slider rows: how the current value is rendered on the right.
@property(nonatomic, copy) NSString* (^format)(double value);
/// Info rows: recomputed every refresh tick while the page is visible.
@property(nonatomic, copy) NSString* (^info)(void);
/// Action rows.
@property(nonatomic, copy) void (^action)(void);
@property(nonatomic) BOOL destructive;
@end

@implementation RexSettingsRow
@end

@interface RexSettingsSection : NSObject
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* footer;
@property(nonatomic, strong) NSMutableArray<RexSettingsRow*>* rows;
@end

@implementation RexSettingsSection
@end

// ---------------------------------------------------------------------------
// View controller
// ---------------------------------------------------------------------------

@interface RexSettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation RexSettingsViewController {
  UITableView* _table;
  NSMutableArray<RexSettingsSection*>* _sections;
  NSTimer* _refresh;
  // Frame rate, derived here from the guest's own present counter rather than
  // read from the touch overlay: the readout must work with the on-screen
  // controls hidden, which is exactly when a controller is attached and someone
  // is measuring.
  uint64_t _fpsLastPresented;
  CFTimeInterval _fpsLastTime;
  double _fps;
  // Which cvars this page owns. "Reset" restores exactly these and nothing
  // else: ResetAllToDefaults would also clear game_data_root, the window size
  // and the boot flags, which would leave the app unable to find the game.
  NSMutableArray<NSString*>* _owned;
}

// --- table construction --------------------------------------------------

- (RexSettingsRow*)switchRow:(NSString*)title cvar:(NSString*)cvar {
  RexSettingsRow* r = [RexSettingsRow new];
  r.kind = RexRowSwitch;
  r.title = title;
  r.cvar = cvar;
  return r;
}

- (RexSettingsRow*)sliderRow:(NSString*)title
                        cvar:(NSString*)cvar
                         min:(double)min
                         max:(double)max
                      format:(NSString* (^)(double))format {
  RexSettingsRow* r = [RexSettingsRow new];
  r.kind = RexRowSlider;
  r.title = title;
  r.cvar = cvar;
  r.min = min;
  r.max = max;
  r.format = format;
  return r;
}

- (RexSettingsRow*)segmentedRow:(NSString*)title
                           cvar:(NSString*)cvar
                         labels:(NSArray<NSString*>*)labels
                         values:(NSArray<NSString*>*)values {
  RexSettingsRow* r = [RexSettingsRow new];
  r.kind = RexRowSegmented;
  r.title = title;
  r.cvar = cvar;
  r.labels = labels;
  r.values = values;
  return r;
}

- (RexSettingsRow*)infoRow:(NSString*)title text:(NSString* (^)(void))text {
  RexSettingsRow* r = [RexSettingsRow new];
  r.kind = RexRowInfo;
  r.title = title;
  r.info = text;
  return r;
}

- (void)addSection:(NSString*)title
            footer:(NSString*)footer
              rows:(NSArray<RexSettingsRow*>*)rows {
  RexSettingsSection* s = [RexSettingsSection new];
  s.title = title;
  s.footer = footer;
  s.rows = [NSMutableArray array];
  for (RexSettingsRow* r in rows) {
    // A row addressing a cvar that no longer exists is dropped rather than
    // shown dead. Upstream renames are the expected cause, so say so loudly.
    if (r.cvar && !CvarExists(r.cvar)) {
      REXLOG_ERROR("settings: dropping row '{}' -- no cvar named {}", r.title.UTF8String,
                   r.cvar.UTF8String);
      continue;
    }
    if (r.cvar) [_owned addObject:r.cvar];
    [s.rows addObject:r];
  }
  if (s.rows.count) [_sections addObject:s];
}

- (void)buildSections {
  _sections = [NSMutableArray array];
  _owned = [NSMutableArray array];

  // --- Display ---
  [self addSection:@"Display"
            footer:@"Queue depth 1 gives the lowest input lag and resists the frame-rate "
                   @"collapses; 2 gives more CPU/GPU overlap."
              rows:@[
                [self switchRow:@"Show frame rate" cvar:@"show_fps"],
                [self switchRow:@"Detailed readout" cvar:@"show_perf_hud"],
                [self segmentedRow:@"Frame rate cap"
                              cvar:@"max_fps"
                            labels:@[ @"30", @"60", @"120", @"Off" ]
                            values:@[ @"30", @"60", @"120", @"0" ]],
                [self segmentedRow:@"Frame queue depth"
                              cvar:@"vulkan_max_queued_frames"
                            labels:@[ @"1 (low latency)", @"2 (smooth)" ]
                            values:@[ @"1", @"2" ]],
              ]];

  // --- Graphics ---
  RexSettingsRow* mip = [self switchRow:@"Distance texture filtering" cvar:@"texture_flat_lod"];
  mip.inverted = YES;  // the cvar names the workaround; the row names the feature
  [self addSection:@"Graphics"
            footer:@"Off by default. Turning it on sharpens distant surfaces but draws dark "
                   @"seams along the polygon edges of character faces (a known bug, M-056)."
              rows:@[ mip ]];

  // --- Controls ---
  [self addSection:@"Controls"
            footer:@"A long swipe turns exactly as far as several short ones."
              rows:@[
                [self sliderRow:@"Look sensitivity"
                           cvar:@"touch_look_scale"
                            min:1.0
                            max:20.0
                         format:^NSString*(double v) {
                           return [NSString stringWithFormat:@"%.1f", v];
                         }],
                [self switchRow:@"Invert look (vertical)" cvar:@"ge_invert_y"],
                [self switchRow:@"Invert look (horizontal)" cvar:@"ge_invert_x"],
                [self segmentedRow:@"On-screen controls"
                              cvar:@"touch_controls"
                            labels:@[ @"Auto", @"On", @"Off" ]
                            values:@[ @"auto", @"on", @"off" ]],
                [self sliderRow:@"Button size"
                           cvar:@"touch_button_scale"
                            min:0.6
                            max:1.8
                         format:^NSString*(double v) {
                           return [NSString stringWithFormat:@"%.0f%%", v * 100.0];
                         }],
                [self sliderRow:@"Button opacity"
                           cvar:@"touch_button_opacity"
                            min:0.05
                            max:0.9
                         format:^NSString*(double v) {
                           return [NSString stringWithFormat:@"%.0f%%", v * 100.0];
                         }],
                [self switchRow:@"Haptics" cvar:@"touch_haptics"],
              ]];

  // --- Audio ---
  [self addSection:@"Audio"
            footer:nil
              rows:@[
                [self sliderRow:@"Volume"
                           cvar:@"master_volume"
                            min:0.0
                            max:1.0
                         format:^NSString*(double v) {
                           return [NSString stringWithFormat:@"%.0f%%", v * 100.0];
                         }],
                [self switchRow:@"Mute" cvar:@"audio_mute"],
              ]];

  // --- Diagnostics ---
  // Read-only and live. Thermal state is here rather than only over the console
  // because it invalidates every performance comparison, and the person holding
  // the phone is the one who can see it (M-049).
  [self addSection:@"Diagnostics"
            footer:@"Thermal state throttles the GPU hard: a frame rate measured at "
                   @"\u201cserious\u201d is not comparable with one at \u201cnominal\u201d."
              rows:@[
                [self infoRow:@"Frame rate"
                         text:^NSString* {
                           if (self->_fps <= 0.0) return @"measuring…";
                           return [NSString stringWithFormat:@"%.0f fps · %.1f ms", self->_fps,
                                                             1000.0 / self->_fps];
                         }],
                [self infoRow:@"Thermal state"
                         text:^NSString* {
                           switch (NSProcessInfo.processInfo.thermalState) {
                             case NSProcessInfoThermalStateNominal: return @"nominal";
                             case NSProcessInfoThermalStateFair: return @"fair";
                             case NSProcessInfoThermalStateSerious: return @"serious";
                             case NSProcessInfoThermalStateCritical: return @"critical";
                           }
                           return @"unknown";
                         }],
                [self infoRow:@"Frames"
                         text:^NSString* {
                           uint64_t submitted = 0, presented = 0;
                           rex::ui::GetGuestFrameCounters(&submitted, &presented);
                           if (submitted > presented) {
                             return [NSString stringWithFormat:@"%llu presented, %llu behind",
                                                               presented, submitted - presented];
                           }
                           return [NSString stringWithFormat:@"%llu presented", presented];
                         }],
                [self infoRow:@"Version"
                         text:^NSString* {
                           NSDictionary* info = NSBundle.mainBundle.infoDictionary;
                           return [NSString
                               stringWithFormat:@"%@ (%@)", info[@"CFBundleShortVersionString"],
                                                info[@"CFBundleVersion"]];
                         }],
              ]];

  // --- Reset ---
  RexSettingsRow* reset = [RexSettingsRow new];
  reset.kind = RexRowAction;
  reset.title = @"Reset settings to defaults";
  reset.destructive = YES;
  __weak __typeof(self) weakSelf = self;
  reset.action = ^{ [weakSelf confirmReset]; };
  RexSettingsSection* last = [RexSettingsSection new];
  last.rows = [NSMutableArray arrayWithObject:reset];
  last.footer = @"Restores only the settings on this page. Saves and game data are untouched.";
  [_sections addObject:last];
}

- (void)confirmReset {
  UIAlertController* alert =
      [UIAlertController alertControllerWithTitle:@"Reset settings?"
                                          message:@"Everything on this page returns to its "
                                                  @"default. Saves and game data are not affected."
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
                                          handler:nil]];
  __weak __typeof(self) weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Reset"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction* a) {
                                            (void)a;
                                            [weakSelf doReset];
                                          }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)doReset {
  for (NSString* name in _owned) {
    rex::cvar::ResetToDefault(name.UTF8String);
  }
  REXLOG_INFO("settings: reset {} settings to defaults", (unsigned long)_owned.count);
  rex::ui::PersistSettings();
  [_table reloadData];
}

// --- lifecycle -----------------------------------------------------------

- (void)viewDidLoad {
  [super viewDidLoad];
  // Opaque, deliberately. The first version put a system blur over the game,
  // which is a backdrop filter over a CAMetalLayer that keeps redrawing at 60
  // Hz -- so the compositor re-blurred the whole screen every frame, on a GPU
  // already thermally clamped. the user hit 30-second freezes opening the page
  // and again scrolling it. An opaque background also lets UIKit stop
  // compositing the game layer entirely while the page is up.
  self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
  self.view.opaque = YES;

  [self buildSections];

  _table = [[UITableView alloc] initWithFrame:self.view.bounds
                                        style:UITableViewStyleInsetGrouped];
  _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _table.backgroundColor = UIColor.clearColor;
  _table.dataSource = self;
  _table.delegate = self;
  _table.allowsSelection = YES;
  [self.view addSubview:_table];

  // Own header bar rather than a hosted navigation controller: this is
  // presented directly over the game window, and the family's spec warns that
  // relying on a hosted nav bar's Done is fragile.
  UIView* bar = [[UIView alloc] initWithFrame:CGRectZero];
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  // Opaque: the table scrolls underneath it, and a translucent bar let the
  // first section's rows read through the title.
  bar.backgroundColor = [UIColor colorWithWhite:0.0 alpha:1.0];
  [self.view addSubview:bar];

  UILabel* title = [UILabel new];
  title.text = @"Settings";
  title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
  title.textColor = UIColor.whiteColor;
  title.translatesAutoresizingMaskIntoConstraints = NO;
  [bar addSubview:title];

  UIButton* done = [UIButton buttonWithType:UIButtonTypeSystem];
  [done setTitle:@"Done" forState:UIControlStateNormal];
  done.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
  done.configuration = [UIButtonConfiguration filledButtonConfiguration];
  done.translatesAutoresizingMaskIntoConstraints = NO;
  [done addTarget:self action:@selector(dismissTapped) forControlEvents:UIControlEventTouchUpInside];
  [bar addSubview:done];

  UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [bar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
    [bar.bottomAnchor constraintEqualToAnchor:safe.topAnchor constant:52],
    [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
    [title.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor constant:-12],
    [done.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
    [done.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
  ]];

  // The table must start below the bar, which is laid out relative to the safe
  // area rather than to a fixed height.
  _table.contentInset = UIEdgeInsetsMake(52, 0, 0, 0);
  _table.scrollIndicatorInsets = _table.contentInset;
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  // Only the read-only rows move on their own, and only while someone is
  // looking at them. Half a second is faster than anyone reads and slow enough
  // to be free.
  // Under the simulator gate, walk to the bottom of the table a few seconds
  // in. Nothing outside the process can scroll it (injected events bypass
  // UIKit's touch path), and a page whose lower half is never photographed is a
  // page whose lower half is never checked.
  if (REXCVAR_GET(settings_selftest)) {
    // Every section gets photographed, in order, three seconds apart. Two
    // screenshots at the ends would leave the sliders -- which are the whole
    // middle of the page -- checked by nobody.
    for (NSUInteger i = 1; i < self->_sections.count; ++i) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * i * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
                       if (i >= self->_sections.count) return;
                       [self->_table
                           scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0
                                                                     inSection:(NSInteger)i]
                                 atScrollPosition:UITableViewScrollPositionTop
                                         animated:NO];
                       REXLOG_INFO("settings: selftest showing section {} of {}", i + 1,
                                   self->_sections.count);
                     });
    }
  }

  __weak __typeof(self) weakSelf = self;
  _refresh = [NSTimer scheduledTimerWithTimeInterval:0.5
                                             repeats:YES
                                               block:^(NSTimer* t) {
                                                 (void)t;
                                                 [weakSelf refreshInfoRows];
                                               }];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  [_refresh invalidate];
  _refresh = nil;
}

- (void)refreshInfoRows {
  // Sampled over the refresh interval rather than instantaneously: the guest's
  // present counter is the only honest source (it counts what reached the
  // glass), and it needs two readings to become a rate.
  uint64_t submitted = 0, presented = 0;
  rex::ui::GetGuestFrameCounters(&submitted, &presented);
  const CFTimeInterval now = CACurrentMediaTime();
  if (_fpsLastTime > 0 && now > _fpsLastTime && presented >= _fpsLastPresented) {
    _fps = double(presented - _fpsLastPresented) / (now - _fpsLastTime);
  }
  _fpsLastTime = now;
  _fpsLastPresented = presented;

  for (NSUInteger s = 0; s < _sections.count; ++s) {
    RexSettingsSection* section = _sections[s];
    for (NSUInteger r = 0; r < section.rows.count; ++r) {
      if (section.rows[r].kind != RexRowInfo) continue;
      NSIndexPath* ip = [NSIndexPath indexPathForRow:(NSInteger)r inSection:(NSInteger)s];
      UITableViewCell* cell = [_table cellForRowAtIndexPath:ip];
      if (cell) cell.detailTextLabel.text = section.rows[r].info();
    }
  }
}

- (void)dismissTapped {
  rex::ui::DismissSettings();
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return UIInterfaceOrientationMaskLandscape;
}

- (BOOL)prefersStatusBarHidden {
  return YES;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
  return YES;
}

// --- data source ---------------------------------------------------------

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  (void)tableView;
  return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  (void)tableView;
  return (NSInteger)_sections[(NSUInteger)section].rows.count;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
  (void)tableView;
  return _sections[(NSUInteger)section].title;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  (void)tableView;
  return _sections[(NSUInteger)section].footer;
}

- (RexSettingsRow*)rowAt:(NSIndexPath*)ip {
  return _sections[(NSUInteger)ip.section].rows[(NSUInteger)ip.row];
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  RexSettingsRow* row = [self rowAt:indexPath];

  // Rebuilt rather than dequeued: the page is a few dozen rows shown once, and
  // a recycled cell carrying the previous row's accessory view is a class of
  // bug this does not need.
  UITableViewCell* cell =
      [[UITableViewCell alloc] initWithStyle:(row.kind == RexRowInfo ? UITableViewCellStyleValue1
                                                                    : UITableViewCellStyleSubtitle)
                             reuseIdentifier:nil];
  cell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
  cell.textLabel.text = row.title;
  cell.textLabel.textColor = UIColor.whiteColor;
  cell.selectionStyle = UITableViewCellSelectionStyleNone;

  switch (row.kind) {
    case RexRowSwitch: {
      UISwitch* sw = [UISwitch new];
      sw.on = row.inverted ? !CvarBool(row.cvar) : CvarBool(row.cvar);
      sw.tag = kControlTagBase + indexPath.section * 1000 + indexPath.row;
      [sw addTarget:self
                    action:@selector(switchChanged:)
          forControlEvents:UIControlEventValueChanged];
      cell.accessoryView = sw;
      break;
    }
    case RexRowSlider: {
      // The slider sits to the right of the title with the value between them,
      // which keeps the row one line tall in landscape where vertical space is
      // the scarce axis.
      UIView* box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 260, 34)];
      UILabel* value = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 58, 34)];
      value.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
      value.textColor = UIColor.secondaryLabelColor;
      value.textAlignment = NSTextAlignmentRight;
      value.text = row.format(CvarDouble(row.cvar));
      value.tag = kValueLabelTag;
      [box addSubview:value];

      UISlider* slider = [[UISlider alloc] initWithFrame:CGRectMake(66, 0, 194, 34)];
      slider.minimumValue = (float)row.min;
      slider.maximumValue = (float)row.max;
      slider.value = (float)CvarDouble(row.cvar);
      slider.tag = kControlTagBase + indexPath.section * 1000 + indexPath.row;
      // Live while dragging so the effect is visible immediately (the whole
      // point for sensitivity and opacity), persisted on release so the config
      // file is not rewritten sixty times a second.
      [slider addTarget:self
                    action:@selector(sliderChanged:)
          forControlEvents:UIControlEventValueChanged];
      [slider addTarget:self
                    action:@selector(sliderReleased:)
          forControlEvents:(UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                            UIControlEventTouchCancel)];
      [box addSubview:slider];
      cell.accessoryView = box;
      break;
    }
    case RexRowSegmented: {
      UISegmentedControl* seg = [[UISegmentedControl alloc] initWithItems:row.labels];
      NSString* current = CvarString(row.cvar);
      seg.selectedSegmentIndex = (NSInteger)[row.values indexOfObject:current];
      if (seg.selectedSegmentIndex == (NSInteger)NSNotFound) {
        // A value set from the console that no segment covers. Showing nothing
        // selected is the honest rendering; forcing a segment would silently
        // change the setting just by opening the page.
        seg.selectedSegmentIndex = UISegmentedControlNoSegment;
      }
      [seg sizeToFit];
      seg.tag = kControlTagBase + indexPath.section * 1000 + indexPath.row;
      [seg addTarget:self
                    action:@selector(segmentChanged:)
          forControlEvents:UIControlEventValueChanged];
      cell.accessoryView = seg;
      break;
    }
    case RexRowInfo: {
      cell.detailTextLabel.text = row.info();
      cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:15
                                                                  weight:UIFontWeightRegular];
      cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
      break;
    }
    case RexRowAction: {
      cell.textLabel.textColor = row.destructive ? UIColor.systemRedColor : UIColor.systemBlueColor;
      cell.textLabel.textAlignment = NSTextAlignmentCenter;
      cell.selectionStyle = UITableViewCellSelectionStyleDefault;
      break;
    }
  }
  return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  RexSettingsRow* row = [self rowAt:indexPath];
  if (row.kind == RexRowAction && row.action) row.action();
}

// --- control targets -----------------------------------------------------

- (RexSettingsRow*)rowForTag:(NSInteger)tag {
  const NSInteger index = tag - kControlTagBase;
  return _sections[(NSUInteger)(index / 1000)].rows[(NSUInteger)(index % 1000)];
}

- (void)switchChanged:(UISwitch*)sender {
  RexSettingsRow* row = [self rowForTag:sender.tag];
  CvarSetBool(row.cvar, row.inverted ? !sender.isOn : sender.isOn);
  rex::ui::PersistSettings();
}

- (void)sliderChanged:(UISlider*)sender {
  RexSettingsRow* row = [self rowForTag:sender.tag];
  CvarSetDouble(row.cvar, sender.value);
  UILabel* value = [sender.superview viewWithTag:kValueLabelTag];
  if ([value isKindOfClass:UILabel.class]) value.text = row.format(sender.value);
}

- (void)sliderReleased:(UISlider*)sender {
  (void)sender;
  rex::ui::PersistSettings();
}

- (void)segmentChanged:(UISegmentedControl*)sender {
  RexSettingsRow* row = [self rowForTag:sender.tag];
  if (sender.selectedSegmentIndex < 0 ||
      sender.selectedSegmentIndex >= (NSInteger)row.values.count) {
    return;
  }
  CvarSet(row.cvar, row.values[(NSUInteger)sender.selectedSegmentIndex]);
  rex::ui::PersistSettings();
}

@end

// ---------------------------------------------------------------------------
// C++ entry points
// ---------------------------------------------------------------------------

namespace {

RexSettingsViewController* g_settings = nil;

UIViewController* RootViewController() {
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow* window in ((UIWindowScene*)scene).windows) {
      if (window.rootViewController) return window.rootViewController;
    }
  }
  // The game's window is created directly rather than through a scene
  // delegate, so it may not be attached to a scene's window list yet.
  UIWindow* key = UIApplication.sharedApplication.keyWindow;
  return key.rootViewController;
}

}  // namespace

namespace rex {
namespace ui {

void PersistSettingsNow() {
  // Documents/ge.toml -- the same path ReXApp computed at boot (patch 0027
  // redirects the config out of the read-only bundle). Recomputed here rather
  // than plumbed through so the settings page has no dependency on the app
  // object, which lives in the game binary above this dylib.
  const auto path = rex::filesystem::GetDocumentsFolder() / "ge.toml";
  rex::cvar::SaveConfig(path);
}

void PersistSettings() {
  // Off the main thread and coalesced. Dragging a slider commits on release,
  // but a switch row plus a segment plus a reset in quick succession would
  // otherwise be three serialisations and three file writes on the thread that
  // is also running the table. Nothing here is urgent: resign-active calls
  // PersistSettingsNow(), which is the path that actually has to beat the
  // process being suspended.
  static std::atomic<int> pending{0};
  pending.fetch_add(1, std::memory_order_relaxed);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                   if (pending.fetch_sub(1, std::memory_order_relaxed) != 1) return;
                   PersistSettingsNow();
                 });
}

bool SettingsVisible() { return g_settings != nil; }

void PresentSettings() {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_settings) return;
    UIViewController* root = RootViewController();
    if (!root) {
      REXLOG_ERROR("settings: no root view controller to present from");
      return;
    }
    // Present from whatever is already on top, or UIKit refuses.
    while (root.presentedViewController) root = root.presentedViewController;

    g_settings = [RexSettingsViewController new];
    // Over-full-screen, deliberately, even though the page is opaque: a plain
    // full-screen presentation can take the game's CAMetalLayer out of the
    // render tree, and a layer that is not in the tree is not guaranteed to
    // keep vending drawables -- which would stall the GPU worker the moment
    // settings opened. Occluding it with an opaque view gets the same
    // compositing saving with none of that risk.
    g_settings.modalPresentationStyle = UIModalPresentationOverFullScreen;
    g_settings.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

    // Whatever the player was holding down stays held for as long as the page
    // is up otherwise -- walking into a wall behind the sheet.
    rex::ui::SetTouchPadState(rex::ui::TouchPadState{});
    rex::ui::SetTouchControlsActive(false);

    [root presentViewController:g_settings
                       animated:YES
                     completion:^{
                       REXLOG_INFO("settings: presented");
                     }];
  });
}

void ScheduleSettingsSelftest() {
  if (!REXCVAR_GET(settings_selftest)) return;
  const double delay = std::max(0.5, REXCVAR_GET(settings_selftest_delay_s));
  REXLOG_INFO("settings: selftest will open the page in {:.1f}s", delay);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   PresentSettings();
                 });
}

void DismissSettings() {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!g_settings) return;
    PersistSettings();
    [g_settings dismissViewControllerAnimated:YES
                                   completion:^{
                                     g_settings = nil;
                                   }];
  });
}

}  // namespace ui
}  // namespace rex
