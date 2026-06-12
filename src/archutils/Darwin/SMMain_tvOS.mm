#include "GameLoop.h"
#include "InputFilter.h"
#include "ProductInfo.h"
#include "RageLog.h"
#include "RageThreads.h"
#include "RageTimer.h"
#include "RageUtil.h"
#include "StepMania.h"
#include "arch/ArchHooks/ArchHooks.h"
#include "global.h"

#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

#include <TargetConditionals.h>

/* This file is tvOS-only (selected via the TVOS branch in CMakeData-os.cmake)
 * and is compiled WITHOUT -fobjc-arc, i.e. under manual retain/release (MRC).
 * Objects that must outlive the local scope are retained explicitly and never
 * released, since they live for the entire application lifetime. */

@interface SMViewController : UIViewController
@end

@implementation SMViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor blackColor];
}

- (DeviceButton)buttonForPress:(UIPress*)press {
  switch (press.type) {
    case UIPressTypeUpArrow:
      return JOY_UP;
    case UIPressTypeDownArrow:
      return JOY_DOWN;
    case UIPressTypeLeftArrow:
      return JOY_LEFT;
    case UIPressTypeRightArrow:
      return JOY_RIGHT;
    case UIPressTypeSelect:
      return JOY_BUTTON_1;
    case UIPressTypeMenu:
      return JOY_BUTTON_9;
    case UIPressTypePlayPause:
      return JOY_BUTTON_3;
    default:
      break;
  }

  if (@available(tvOS 13.4, *)) {
    if (press.key) {
      switch (press.key.keyCode) {
        case UIKeyboardHIDUsageKeyboardUpArrow:
          return JOY_UP;
        case UIKeyboardHIDUsageKeyboardDownArrow:
          return JOY_DOWN;
        case UIKeyboardHIDUsageKeyboardLeftArrow:
          return JOY_LEFT;
        case UIKeyboardHIDUsageKeyboardRightArrow:
          return JOY_RIGHT;
        case UIKeyboardHIDUsageKeyboardReturnOrEnter:
          return JOY_BUTTON_1;
        case UIKeyboardHIDUsageKeyboardEscape:
          return JOY_BUTTON_9;
        case UIKeyboardHIDUsageKeyboardSpacebar:
          return JOY_BUTTON_3;
        default:
          break;
      }
    }
  }

  return DeviceButton_Invalid;
}

- (void)pressesBegan:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event {
  bool handled = false;
  for (UIPress* press in presses) {
    DeviceButton btn = [self buttonForPress:press];
    if (btn != DeviceButton_Invalid && INPUTFILTER) {
      DeviceInput di(DEVICE_JOY1, btn, 1.0f, RageTimer());
      INPUTFILTER->ButtonPressed(di);
      handled = true;
    }
  }
  if (!handled) {
    [super pressesBegan:presses withEvent:event];
  }
}

- (void)pressesEnded:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event {
  bool handled = false;
  for (UIPress* press in presses) {
    DeviceButton btn = [self buttonForPress:press];
    if (btn != DeviceButton_Invalid && INPUTFILTER) {
      DeviceInput di(DEVICE_JOY1, btn, 0.0f, RageTimer());
      INPUTFILTER->ButtonPressed(di);
      handled = true;
    }
  }
  if (!handled) {
    [super pressesEnded:presses withEvent:event];
  }
}

- (void)pressesCancelled:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event {
  [self pressesEnded:presses withEvent:event];
}

@end

@interface SMAppDelegate : UIResponder <UIApplicationDelegate>
@property(strong, nonatomic) UIWindow* window;
@end

/* g_argc and g_argv are declared extern in RageUtil.h */

/* Retained for the lifetime of the app (MRC: never released). The
 * memory-pressure source fires on the main queue; its handler MUST NOT touch
 * engine singletons directly (RageTextureManager / ImageCache / SOUND are not
 * thread-safe and are owned by the game thread). It only posts a thread-safe
 * request that the game loop drains at a frame boundary. */
static dispatch_source_t g_pMemoryPressureSource = nil;

static void InstallMemoryPressureSource() {
  if (g_pMemoryPressureSource != nil) {
    return;
  }

  dispatch_source_t source = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
      DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
      dispatch_get_main_queue());
  if (source == nil) {
    return;
  }

  dispatch_source_set_event_handler(source, ^{
    // Runs on the main queue. Do NOT call engine singletons here; just post a
    // request that the game thread drains at a frame boundary.
    GameLoop::RequestCachePurge();
  });

  dispatch_resume(source);

  // MRC: dispatch_source_create returns a +1-owned object (dispatch objects are
  // not autoreleased). We keep that ownership by storing it in a file-static for
  // the app's lifetime; it is intentionally never released.
  g_pMemoryPressureSource = source;
}

@implementation SMAppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];

  SMViewController* rootVC = [[SMViewController alloc] init];
  self.window.rootViewController = rootVC;
  [self.window makeKeyAndVisible];

  // Install graceful memory-pressure handling so tvOS sheds caches instead of
  // jetsam-killing the app. Both the dispatch source and the UIKit memory
  // warning notification simply request a purge on the game thread.
  InstallMemoryPressureSource();
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(handleMemoryWarning:)
             name:UIApplicationDidReceiveMemoryWarningNotification
           object:nil];

  [NSThread detachNewThreadSelector:@selector(startGame) toTarget:self withObject:nil];

  return YES;
}

- (void)handleMemoryWarning:(NSNotification*)notification {
  // Fires on the main thread. Only post a thread-safe request; the game loop
  // performs the actual purge at a frame boundary.
  GameLoop::RequestCachePurge();
}

- (void)startGame {
  RageThreadRegister gameThread("Game thread");
  exit(sm_main(g_argc, g_argv));
}

- (void)applicationWillResignActive:(UIApplication*)application {
}

- (void)applicationDidEnterBackground:(UIApplication*)application {
  // While backgrounded the app is a prime jetsam target, so proactively shed
  // non-essential caches. The game loop drains this at its next frame boundary.
  GameLoop::RequestCachePurge();
}

- (void)applicationWillEnterForeground:(UIApplication*)application {
}

- (void)applicationDidBecomeActive:(UIApplication*)application {
}

- (void)applicationWillTerminate:(UIApplication*)application {
  ArchHooks::SetUserQuit();
}

@end

#undef main

int main(int argc, char** argv) {
  g_argc = argc;
  g_argv = argv;

  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([SMAppDelegate class]));
  }
}
