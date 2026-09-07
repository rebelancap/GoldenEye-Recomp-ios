/**
 * @file        ui/onboarding_uikit.mm
 * @brief       First-run game data classifier and instructions screen (iOS).
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * See rex/ui/onboarding_uikit.h for why this exists.
 */

#include <rex/ui/onboarding_uikit.h>

#include <rex/filesystem/devices/stfs_container_device.h>
#include <rex/logging.h>

#import <UIKit/UIKit.h>

namespace rex {
namespace ui {

GameDataStatus ClassifyGameData(const std::filesystem::path& dir) {
  GameDataStatus status;
  std::error_code ec;

  if (!std::filesystem::is_directory(dir, ec)) {
    status.kind = GameDataStatus::Kind::kMissing;
    status.detail = "No 'assets' folder yet.";
    return status;
  }

  if (std::filesystem::directory_iterator(dir, ec) == std::filesystem::directory_iterator{}) {
    status.kind = GameDataStatus::Kind::kEmpty;
    status.detail = "The 'assets' folder is empty.";
    return status;
  }

  // Extracted form. default.xex is the entrypoint and files/ is the asset tree;
  // either one alone is a half-copy, which is worth naming precisely because a
  // 744 MB transfer over Wi-Fi is exactly the kind of thing that stops early.
  const bool has_xex = std::filesystem::is_regular_file(dir / "default.xex", ec);
  const bool has_files = std::filesystem::is_directory(dir / "files", ec);
  if (has_xex && has_files) {
    status.kind = GameDataStatus::Kind::kExtracted;
    // original/ and new/ are the N64 and remastered model sets -- the instant
    // visual toggle is literally these two directories. A set missing one boots
    // but the toggle half-works, so say so rather than letting it look fine.
    const bool has_original = std::filesystem::is_directory(dir / "files" / "original", ec);
    const bool has_new = std::filesystem::is_directory(dir / "files" / "new", ec);
    if (has_original && has_new) {
      status.detail = "Extracted game files found.";
    } else {
      status.detail =
          "Found the game files, but files/original or files/new is missing -- "
          "the N64/remaster toggle will not work properly.";
    }
    return status;
  }

  // Unextracted container. The whole scene release folder can be dropped in
  // as-is; the package is found by header, wherever it sits.
  if (!rex::filesystem::StfsContainerDevice::FindPackageIn(dir).empty()) {
    status.kind = GameDataStatus::Kind::kContainer;
    status.detail = "Unextracted game container found.";
    return status;
  }

  status.kind = GameDataStatus::Kind::kUnrecognised;
  if (has_xex) {
    status.detail = "Found default.xex but no 'files' folder next to it.";
  } else if (has_files) {
    status.detail = "Found the 'files' folder but no default.xex next to it.";
  } else {
    status.detail = "That folder does not look like a GoldenEye file set.";
  }
  return status;
}

}  // namespace ui
}  // namespace rex

// --- The screen itself ---

@interface RexOnboardingViewController : UIViewController
@property(nonatomic, assign) std::filesystem::path* dir;
@property(nonatomic, copy) void (^onReady)(void);
@property(nonatomic, strong) UILabel* statusLabel;
@end

@implementation RexOnboardingViewController {
  UIWindow* _window;  // strong: nothing else retains the window we present in
  NSTimer* _poll;
}

- (void)setPresentingWindow:(UIWindow*)window {
  _window = window;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];

  UIScrollView* scroll = [[UIScrollView alloc] init];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:scroll];

  UIStackView* stack = [[UIStackView alloc] init];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 18.0;
  stack.alignment = UIStackViewAlignmentFill;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:stack];

  UILabel* title = [[UILabel alloc] init];
  title.text = @"GoldenEye 007";
  title.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
  title.textColor = UIColor.whiteColor;
  [stack addArrangedSubview:title];

  UILabel* body = [[UILabel alloc] init];
  body.numberOfLines = 0;
  body.font = [UIFont systemFontOfSize:16];
  body.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
  body.text =
      @"This app ships with no game data. You supply your own copy.\n\n"
      @"1.  Open the Files app.\n"
      @"2.  Go to On My iPhone → GoldenEye.\n"
      @"3.  Put your game files in a folder named exactly “assets”.\n\n"
      @"Either form works:\n\n"
      @"•  The extracted file set — assets/default.xex, assets/files/, "
      @"and the .xwb / .xsb sound banks.\n"
      @"•  The unextracted container — drop the whole release folder in "
      @"as “assets” and it will be found and mounted for you.\n\n"
      @"It is around 750 MB either way, so give the copy time to finish before "
      @"tapping Check Again.";
  [stack addArrangedSubview:body];

  UILabel* status = [[UILabel alloc] init];
  status.numberOfLines = 0;
  status.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
  status.textColor = [UIColor colorWithRed:1.0 green:0.72 blue:0.3 alpha:1.0];
  [stack addArrangedSubview:status];
  self.statusLabel = status;

  // The button lives OUTSIDE the scroll view, pinned to the bottom. A phone
  // held in landscape shows about 400pt of height and the instructions are
  // longer than that, so a button inside the scroll view sits below the fold --
  // the one control the screen exists to offer would be the one thing you
  // cannot see.
  UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
  [button setTitle:@"Check Again" forState:UIControlStateNormal];
  button.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
  button.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
  button.layer.cornerRadius = 10.0;
  button.translatesAutoresizingMaskIntoConstraints = NO;
  [button addTarget:self
                action:@selector(recheck)
      forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:button];

  UILayoutGuide* guide = self.view.layoutMarginsGuide;
  [NSLayoutConstraint activateConstraints:@[
    [scroll.topAnchor constraintEqualToAnchor:guide.topAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:button.topAnchor constant:-12],

    [button.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
    [button.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
    [button.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],
    [button.heightAnchor constraintEqualToConstant:52.0],

    [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
    [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
    [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor],
  ]];

  [self refreshStatus];

  // Copying ~750 MB through the Files app takes minutes and gives no signal
  // when it finishes. Rather than make the user guess and tap, watch for it:
  // the screen advances by itself the moment the file set becomes complete.
  // The button stays for anyone who would rather not wait for the next tick.
  _poll = [NSTimer scheduledTimerWithTimeInterval:2.0
                                          repeats:YES
                                            block:^(NSTimer* timer) {
                                              (void)timer;
                                              [self recheckQuietly];
                                            }];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  // Charter rule: UIKit placements are only believed when the view logs its own
  // frame. This is that log line.
  REXLOG_INFO("onboarding: view frame {:.0f}x{:.0f}", self.view.bounds.size.width,
              self.view.bounds.size.height);
}

- (void)refreshStatus {
  auto st = rex::ui::ClassifyGameData(*self.dir);
  NSString* text = [NSString stringWithUTF8String:st.detail.c_str()];
  if (![text isEqualToString:self.statusLabel.text]) {
    self.statusLabel.text = text;
    REXLOG_INFO("onboarding: game data at {} -> {}", self.dir->string(), st.detail);
  }
}

// The poll's path: update the label, and proceed once there is something to
// proceed with. Silent by design -- it runs every two seconds and must not fill
// the log with the same "not there yet" line.
- (void)recheckQuietly {
  [self refreshStatus];
  auto st = rex::ui::ClassifyGameData(*self.dir);
  if (st.usable()) {
    [self proceed];
  }
}

// The button's path: same check, but says so in the log, because a tap is a
// deliberate act and "I pressed it and nothing happened" needs an explanation.
- (void)recheck {
  [self refreshStatus];
  auto st = rex::ui::ClassifyGameData(*self.dir);
  REXLOG_INFO("onboarding: Check Again -> {}", st.detail);
  if (st.usable()) {
    [self proceed];
  }
}

- (void)proceed {
  void (^ready)(void) = self.onReady;
  if (!ready) {
    return;  // already proceeding; a tap and a poll tick can race
  }
  self.onReady = nil;
  [_poll invalidate];
  _poll = nil;
  REXLOG_INFO("onboarding: game data accepted, resuming boot");
  [self dismissViewControllerAnimated:YES
                           completion:^{
                             self->_window = nil;
                             ready();
                           }];
}

- (BOOL)prefersStatusBarHidden {
  return YES;
}

@end

namespace rex {
namespace ui {

void PresentGameDataOnboarding(const std::filesystem::path& dir, std::function<void()> on_ready) {
  // The path outlives the controller: it is owned here and freed when the
  // controller is dismissed.
  auto* owned_dir = new std::filesystem::path(dir);
  auto shared_ready = std::make_shared<std::function<void()>>(std::move(on_ready));

  dispatch_async(dispatch_get_main_queue(), ^{
    UIWindow* window = nil;
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
      if ([scene isKindOfClass:UIWindowScene.class]) {
        window = ((UIWindowScene*)scene).keyWindow;
        if (window) break;
      }
    }
    if (!window) {
      window = UIApplication.sharedApplication.windows.firstObject;
    }
    if (!window || !window.rootViewController) {
      REXLOG_ERROR("onboarding: no window to present in; game data must be supplied manually");
      delete owned_dir;
      return;
    }

    auto* vc = [[RexOnboardingViewController alloc] init];
    vc.dir = owned_dir;
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    vc.onReady = ^{
      auto ready = *shared_ready;
      delete owned_dir;
      if (ready) ready();
    };
    [window.rootViewController presentViewController:vc animated:NO completion:nil];
  });
}

}  // namespace ui
}  // namespace rex
