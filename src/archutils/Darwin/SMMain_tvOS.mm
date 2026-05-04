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

@implementation SMAppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];

  SMViewController* rootVC = [[SMViewController alloc] init];
  self.window.rootViewController = rootVC;
  [self.window makeKeyAndVisible];

  [NSThread detachNewThreadSelector:@selector(startGame) toTarget:self withObject:nil];

  return YES;
}

- (void)startGame {
  RageThreadRegister gameThread("Game thread");
  exit(sm_main(g_argc, g_argv));
}

- (void)applicationWillResignActive:(UIApplication*)application {
}

- (void)applicationDidEnterBackground:(UIApplication*)application {
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
