#include "ArchHooks_tvOS.h"
#include "ProductInfo.h"
#include "RageFileManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "arch/UploadServer/UploadServer_tvOS.h"
#include "global.h"

#include <cstddef>
#include <cstdint>

#include <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/types.h>
extern "C" {
#include <mach/mach_time.h>
}

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

void ArchHooks_tvOS::Init() {
  CFStringRef key = CFSTR("ApplicationBundlePath");

  CFBundleRef bundle = CFBundleGetMainBundle();
  CFStringRef appID = CFBundleGetIdentifier(bundle);
  if (appID == nil) {
    return;
  }

  CFStringRef version =
      CFStringRef(CFBundleGetValueForInfoDictionaryKey(bundle, kCFBundleVersionKey));
  CFPropertyListRef old = CFPreferencesCopyAppValue(key, appID);
  CFURLRef path = CFBundleCopyBundleURL(bundle);
  CFPropertyListRef value = CFURLCopyFileSystemPath(path, kCFURLPOSIXPathStyle);
  CFMutableDictionaryRef newDict = nil;

  if (old && CFGetTypeID(old) != CFDictionaryGetTypeID()) {
    CFRelease(old);
    old = nil;
  }

  if (!old) {
    newDict = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionaryAddValue(newDict, version, value);
  } else {
    CFTypeRef oldValue;
    CFDictionaryRef dict = CFDictionaryRef(old);

    if (!CFDictionaryGetValueIfPresent(dict, version, &oldValue) || !CFEqual(oldValue, value)) {
      newDict = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dict);
      CFDictionarySetValue(newDict, version, value);
    }
    CFRelease(old);
  }

  if (newDict) {
    CFPreferencesSetAppValue(key, newDict, appID);
    CFPreferencesAppSynchronize(appID);
    CFRelease(newDict);
  }
  CFRelease(value);
  CFRelease(path);
}

std::string ArchHooks_tvOS::GetArchName() const { return "tvOS (arm64)"; }

void ArchHooks_tvOS::DumpDebugInfo() {
  std::string SystemVersion;
  {
    NSString* version = [[UIDevice currentDevice] systemVersion];
    NSString* model = [[UIDevice currentDevice] model];
    SystemVersion = ssprintf(
        "tvOS %s (%s)", [version cStringUsingEncoding:NSUTF8StringEncoding],
        [model cStringUsingEncoding:NSUTF8StringEncoding]);
  }

  size_t size;
#define GET_PARAM(name, var) (size = sizeof(var), sysctlbyname(name, &var, &size, nil, 0))
  float fRam;
  {
    uint64_t iRam = 0;
    GET_PARAM("hw.memsize", iRam);
    fRam = float(double(iRam) / 1073741824.0);
  }

  int iCPUs = 0;
  int iMaxCPUs = 0;
  GET_PARAM("hw.logicalcpu_max", iMaxCPUs);
  GET_PARAM("hw.logicalcpu", iCPUs);
#undef GET_PARAM

  LOG->Info("CPUs: %d/%d", iCPUs, iMaxCPUs);
  LOG->Info("%s", SystemVersion.c_str());
  LOG->Info("Memory: %.2f GB", fRam);
}

std::string ArchHooks::GetPreferredLanguage() {
  CFStringRef app = kCFPreferencesCurrentApplication;
  CFTypeRef t = CFPreferencesCopyAppValue(CFSTR("AppleLanguages"), app);
  std::string ret = "en";

  if (t == nil) {
    return ret;
  }
  if (CFGetTypeID(t) != CFArrayGetTypeID()) {
    CFRelease(t);
    return ret;
  }

  CFArrayRef languages = CFArrayRef(t);
  CFStringRef lang;

  if (CFArrayGetCount(languages) > 0 &&
      (lang = (CFStringRef)CFArrayGetValueAtIndex(languages, 0)) != nil) {
    const char* str = CFStringGetCStringPtr(lang, kCFStringEncodingMacRoman);
    if (str) {
      ret = std::string(str, 2);
      if (ret == "zh") {
        ret = std::string(str, 7);
        ret[2] = '-';
      }
    } else {
      LOG->Warn("Unable to determine system language. Using English.");
    }
  }

  CFRelease(languages);
  return ret;
}

int64_t ArchHooks::GetSystemTimeInMicroseconds() {
  static double factor = 0.0;

  if (unlikely(factor == 0.0)) {
    mach_timebase_info_data_t timeBase;
    mach_timebase_info(&timeBase);
    factor = timeBase.numer / (1000.0 * timeBase.denom);
  }
  return int64_t(mach_absolute_time() * factor);
}

void ArchHooks::MountInitialFilesystems(const std::string& sDirOfExecutable) {
  FILEMAN->Mount("dirro", sDirOfExecutable, "/");

  NSString* resourcePath = [[NSBundle mainBundle] resourcePath];
  if (resourcePath) {
    const char* rp = [resourcePath UTF8String];
    FILEMAN->Mount("dirro", ssprintf("%s/Announcers", rp), "/Announcers");
    FILEMAN->Mount("dirro", ssprintf("%s/BGAnimations", rp), "/BGAnimations");
    FILEMAN->Mount("dirro", ssprintf("%s/BackgroundEffects", rp), "/BackgroundEffects");
    FILEMAN->Mount("dirro", ssprintf("%s/BackgroundTransitions", rp), "/BackgroundTransitions");
    FILEMAN->Mount("dirro", ssprintf("%s/CDTitles", rp), "/CDTitles");
    FILEMAN->Mount("dirro", ssprintf("%s/Characters", rp), "/Characters");
    FILEMAN->Mount("dirro", ssprintf("%s/Courses", rp), "/Courses");
    FILEMAN->Mount("dirro", ssprintf("%s/NoteSkins", rp), "/NoteSkins");
    FILEMAN->Mount("dirro", ssprintf("%s/Packages", rp), "/Packages");
    FILEMAN->Mount("dirro", ssprintf("%s/Songs", rp), "/Songs");
    FILEMAN->Mount("dirro", ssprintf("%s/RandomMovies", rp), "/RandomMovies");
    FILEMAN->Mount("dirro", ssprintf("%s/Themes", rp), "/Themes");
    FILEMAN->Mount("dirro", ssprintf("%s/Data", rp), "/Data");
  }

  CFURLRef dataUrl =
      CFBundleCopyResourceURL(CFBundleGetMainBundle(), CFSTR("StepMania"), CFSTR("smzip"), nil);
  if (dataUrl) {
    char dir[PATH_MAX];
    CFStringRef dataPath = CFURLCopyFileSystemPath(dataUrl, kCFURLPOSIXPathStyle);
    CFStringGetCString(dataPath, dir, PATH_MAX, kCFStringEncodingUTF8);

    if (strncmp(sDirOfExecutable.c_str(), dir, sDirOfExecutable.length()) == 0) {
      FILEMAN->Mount("zip", dir + sDirOfExecutable.length(), "/");
    }
    CFRelease(dataPath);
    CFRelease(dataUrl);
  }
}

static std::string PathForDirectory(NSSearchPathDirectory directory) {
  NSFileManager* fileManager = [NSFileManager defaultManager];
  NSURL* url = [fileManager URLForDirectory:directory
                                   inDomain:NSUserDomainMask
                          appropriateForURL:nil
                                     create:YES
                                      error:nil];
  if (url == nil) {
    FAIL_M("URLForDirectory() failed.");
  }

  return [url fileSystemRepresentation];
}

// Returns the iCloud Drive Documents path for this app, or empty string if
// iCloud is unavailable (no account, container not provisioned, or sync
// disabled). The returned path is the user-visible "Documents" subfolder of
// the app's ubiquity container, which is what NSUbiquitousContainerIsDocumentScopePublic
// exposes via the Files app and icloud.com.
static std::string PathForICloudDocuments() {
  NSFileManager* fm = [NSFileManager defaultManager];
  // Pass nil to use the first container identifier listed in the app's
  // entitlements (com.apple.developer.ubiquity-container-identifiers).
  NSURL* containerURL = [fm URLForUbiquityContainerIdentifier:nil];
  if (containerURL == nil) {
    return std::string();
  }
  NSURL* docsURL = [containerURL URLByAppendingPathComponent:@"Documents"];
  [fm createDirectoryAtURL:docsURL withIntermediateDirectories:YES attributes:nil error:nil];
  return [docsURL fileSystemRepresentation];
}

void ArchHooks::MountUserFilesystems(const std::string& sDirOfExecutable) {
  // tvOS has a sandboxed filesystem — use Documents and Caches directories.
  // Create subdirs so uploads (which go here) are visible and writable.
  NSFileManager* fm = [NSFileManager defaultManager];

  // Prefer iCloud Drive Documents when the container is provisioned and the
  // user has iCloud enabled (controlled by app setting "ITGmaniaUseICloud",
  // default-on). Falls back to the local sandbox Documents otherwise. iCloud
  // Documents is exposed to the user via the Files app + icloud.com because
  // Info-tvOS.plist sets NSUbiquitousContainerIsDocumentScopePublic.
  std::string docsDir;
  bool usingICloud = false;
  {
    NSUserDefaults* defs = [NSUserDefaults standardUserDefaults];
    id useICloud = [defs objectForKey:@"ITGmaniaUseICloud"];
    bool wantICloud = (useICloud == nil) || [useICloud boolValue];
    if (wantICloud) {
      std::string icloudDocs = PathForICloudDocuments();
      if (!icloudDocs.empty()) {
        docsDir = icloudDocs;
        usingICloud = true;
      }
    }
  }
  if (docsDir.empty()) {
    docsDir = PathForDirectory(NSDocumentDirectory);
  }

  NSString* docsNS = [NSString stringWithUTF8String:docsDir.c_str()];
  NSArray<NSString*>* docSubdirs =
      @[ @"Save", @"Songs", @"Packages", @"NoteSkins", @"Themes", @"Courses", @"Downloads" ];
  for (NSString* sub in docSubdirs) {
    [fm createDirectoryAtPath:[docsNS stringByAppendingPathComponent:sub]
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
  }
  if (LOG) {
    LOG->Info(
        "User Documents root: %s (%s)", docsDir.c_str(),
        usingICloud ? "iCloud Drive" : "local sandbox");
  }
  FILEMAN->Mount("dir", docsDir + "/Save", "/Save");
  FILEMAN->Mount("dir", docsDir + "/Songs", "/Songs");
  FILEMAN->Mount("dir", docsDir + "/Packages", "/Packages");
  FILEMAN->Mount("dir", docsDir + "/NoteSkins", "/NoteSkins");
  FILEMAN->Mount("dir", docsDir + "/Themes", "/Themes");
  FILEMAN->Mount("dir", docsDir + "/Courses", "/Courses");
  FILEMAN->Mount("dir", docsDir + "/Downloads", "/Downloads");

  std::string cachesDir = PathForDirectory(NSCachesDirectory);
  NSString* cachesNS = [NSString stringWithUTF8String:cachesDir.c_str()];
  NSArray<NSString*>* cacheSubdirs = @[ @"Cache", @"Logs", @"Screenshots" ];
  for (NSString* sub in cacheSubdirs) {
    [fm createDirectoryAtPath:[cachesNS stringByAppendingPathComponent:sub]
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
  }
  FILEMAN->Mount("dir", cachesDir + "/Cache", "/Cache");
  FILEMAN->Mount("dir", cachesDir + "/Logs", "/Logs");
  FILEMAN->Mount("dir", cachesDir + "/Screenshots", "/Screenshots");
}

float ArchHooks_tvOS::GetDisplayAspectRatio() {
  UIScreen* screen = [UIScreen mainScreen];
  CGRect bounds = screen.bounds;
  return bounds.size.width / bounds.size.height;
}

void ArchHooks_tvOS::StartUploadServer() {
  // Match MountUserFilesystems: serve iCloud Drive Documents if available so
  // uploads land in the same root the game reads from.
  std::string docsPath;
  NSUserDefaults* defs = [NSUserDefaults standardUserDefaults];
  id useICloud = [defs objectForKey:@"ITGmaniaUseICloud"];
  bool wantICloud = (useICloud == nil) || [useICloud boolValue];
  if (wantICloud) {
    docsPath = PathForICloudDocuments();
  }
  if (docsPath.empty()) {
    docsPath = PathForDirectory(NSDocumentDirectory);
  }
  UploadServer_Start(docsPath);
}

std::string ArchHooks_tvOS::GetAppSetting(const std::string& key) const {
  if (key.empty()) {
    return std::string();
  }
  NSUserDefaults* defs = [NSUserDefaults standardUserDefaults];
  NSString* nsKey = [NSString stringWithUTF8String:key.c_str()];
  id obj = [defs objectForKey:nsKey];
  // Toggle (PSToggleSwitchSpecifier) stores NSNumber boolean
  if ([obj isKindOfClass:[NSNumber class]]) {
    return [obj boolValue] ? "1" : std::string();
  }
  if ([obj isKindOfClass:[NSString class]]) {
    NSString* val = (NSString*)obj;
    if (val.length == 0) {
      return std::string();
    }
    const char* utf8 = [val UTF8String];
    if (utf8 == nullptr) {
      return std::string();
    }
    return std::string(utf8);
  }
  return std::string();
}

void ArchHooks_tvOS::SetAppSetting(const std::string& key, const std::string& value) {
  if (key.empty()) {
    return;
  }
  NSUserDefaults* defs = [NSUserDefaults standardUserDefaults];
  NSString* nsKey = [NSString stringWithUTF8String:key.c_str()];
  if (value.empty()) {
    [defs removeObjectForKey:nsKey];
  } else {
    [defs setObject:[NSString stringWithUTF8String:value.c_str()] forKey:nsKey];
  }
  [defs synchronize];
}
