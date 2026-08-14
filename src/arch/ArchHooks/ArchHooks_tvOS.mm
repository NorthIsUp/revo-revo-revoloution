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

// How long boot will block waiting for iCloud content to download before
// giving up and continuing. Downloads kicked off here keep running in the
// background past this deadline, so anything not finished in time simply
// appears on a later launch rather than hanging the game.
static const NSTimeInterval kICloudMaterializeTimeoutSeconds = 90.0;

// Resolves the app's iCloud ubiquity-container "Documents" URL exactly once.
// URLForUbiquityContainerIdentifier: does blocking I/O (Apple: do not call on
// the main thread) — we're on the boot thread here, which is fine — and it is
// needed by both the game mount and the upload server, so cache it. Returns
// nil if iCloud is unavailable (no account, container not provisioned).
static NSURL* ICloudDocumentsURL() {
  static NSURL* sDocsURL = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSFileManager* fm = [NSFileManager defaultManager];
    // nil → first container in com.apple.developer.ubiquity-container-identifiers.
    NSURL* containerURL = [fm URLForUbiquityContainerIdentifier:nil];
    if (containerURL != nil) {
      // MRC (no ARC in this target): the appended URL is autoreleased; retain
      // it so the cached static survives past the autorelease pool drain.
      sDocsURL = [[containerURL URLByAppendingPathComponent:@"Documents"] retain];
    }
  });
  return sDocsURL;
}

// Returns the iCloud Drive Documents path for this app, or empty string if
// iCloud is unavailable or the Documents folder cannot be created (quota,
// transient error, account just signed in). On failure the caller falls back
// to the always-writable local sandbox rather than mounting a dead path.
// The returned path is the user-visible "Documents" subfolder of the app's
// ubiquity container, which is what NSUbiquitousContainerIsDocumentScopePublic
// exposes on icloud.com and in the Files app on other devices.
static std::string PathForICloudDocuments() {
  NSURL* docsURL = ICloudDocumentsURL();
  if (docsURL == nil) {
    return std::string();
  }
  NSFileManager* fm = [NSFileManager defaultManager];
  NSError* err = nil;
  if (![fm createDirectoryAtURL:docsURL
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&err]) {
    NSLog(
        @"[RRRevoloution] iCloud Documents not usable (%@); using local sandbox.",
        err.localizedDescription);
    return std::string();
  }
  return [docsURL fileSystemRepresentation];
}

// Content added on another device — or evicted locally under storage pressure
// — exists on disk only as a zero-byte `.<name>.icloud` placeholder until the
// app explicitly downloads it. The POSIX "dir" mount driver does readdir()/
// open() and never sees those placeholders, so that content silently vanishes
// from the song wheel. Walk the ubiquity Documents tree, request a download of
// every not-yet-current item, and wait (bounded) for them to materialize so
// the engine's song scan — which runs right after we mount — can read them.
//
// NOTE: this is eager (downloads everything, including large audio/video).
// A future refinement could materialize chart/banner files first and defer
// heavy media to play time (see Docs/tvOS-performance.md, "Pin gameplay audio
// locally before play").
static void MaterializeICloudTree(NSURL* rootURL, NSTimeInterval timeoutSeconds) {
  NSFileManager* fm = [NSFileManager defaultManager];
  NSArray<NSURLResourceKey>* keys =
      @[ NSURLIsDirectoryKey, NSURLUbiquitousItemDownloadingStatusKey ];
  // Enumerating with NSURL keys surfaces ubiquitous items by their logical
  // name (e.g. "Foo.sm") with a downloading status, abstracting the on-disk
  // `.Foo.sm.icloud` placeholder.
  NSDirectoryEnumerator<NSURL*>* en = [fm enumeratorAtURL:rootURL
                              includingPropertiesForKeys:keys
                                                 options:0
                                            errorHandler:nil];

  NSMutableArray<NSURL*>* pending = [NSMutableArray array];
  for (NSURL* url in en) {
    // Bound peak memory while walking a potentially large library; `pending`
    // retains the URLs we actually need to keep.
    @autoreleasepool {
      NSNumber* isDir = nil;
      [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
      if (isDir.boolValue) {
        continue;
      }
      NSString* status = nil;
      [url getResourceValue:&status forKey:NSURLUbiquitousItemDownloadingStatusKey error:nil];
      if (status != nil && ![status isEqualToString:NSURLUbiquitousItemDownloadingStatusCurrent]) {
        NSError* err = nil;
        if ([fm startDownloadingUbiquitousItemAtURL:url error:&err]) {
          [pending addObject:url];
        } else {
          NSLog(
              @"[RRRevoloution] iCloud: cannot download %@ (%@)", url.lastPathComponent,
              err.localizedDescription);
        }
      }
    }
  }

  NSUInteger requested = pending.count;
  if (requested == 0) {
    NSLog(@"[RRRevoloution] iCloud: content already materialized.");
    return;
  }
  NSLog(@"[RRRevoloution] iCloud: downloading %lu item(s)...", (unsigned long)requested);

  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
  while (pending.count > 0 && [deadline timeIntervalSinceNow] > 0) {
    [NSThread sleepForTimeInterval:0.25];
    NSMutableArray<NSURL*>* still = [NSMutableArray array];
    for (NSURL* url in pending) {
      [url removeAllCachedResourceValues];
      NSString* status = nil;
      [url getResourceValue:&status forKey:NSURLUbiquitousItemDownloadingStatusKey error:nil];
      if (status == nil || ![status isEqualToString:NSURLUbiquitousItemDownloadingStatusCurrent]) {
        [still addObject:url];
      }
    }
    pending = still;
  }

  if (pending.count == 0) {
    NSLog(@"[RRRevoloution] iCloud: %lu item(s) downloaded.", (unsigned long)requested);
  } else {
    NSLog(
        @"[RRRevoloution] iCloud: %lu of %lu item(s) still downloading after %.0fs; "
        @"they will appear on a later launch.",
        (unsigned long)pending.count, (unsigned long)requested, timeoutSeconds);
  }
}

// Walks the ubiquity Documents tree and resolves any NSFileVersion conflicts in
// place before the engine reads a single byte. Cross-device edits to the same
// file (e.g. a profile/score file written on two Apple TVs while both were
// online) produce conflict versions; left unresolved, the engine can read a
// stale/torn copy and the user silently loses scores. We keep the *current*
// version (what +currentVersionOfItemAtURL: returns — the file the POSIX "dir"
// driver will open) and drop every other conflict version.
//
// Common case is cheap: +unresolvedConflictVersionsOfItemAtURL: returns nil/empty
// for the overwhelming majority of files (no conflict), so per-file cost is a
// single metadata query and we never touch NSFileVersion's heavier machinery.
//
// MRC note: NSFileVersion/NSFileCoordinator objects returned here are
// autoreleased and only used within local scope, so no manual retain/release is
// needed; the per-item @autoreleasepool bounds peak memory across a large tree.
static void ResolveICloudConflicts(NSURL* rootURL) {
  NSFileManager* fm = [NSFileManager defaultManager];
  NSDirectoryEnumerator<NSURL*>* en =
      [fm enumeratorAtURL:rootURL
          includingPropertiesForKeys:@[ NSURLIsDirectoryKey ]
                             options:0
                        errorHandler:nil];

  NSUInteger resolvedFiles = 0;
  for (NSURL* url in en) {
    @autoreleasepool {
      NSNumber* isDir = nil;
      [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
      if (isDir.boolValue) {
        continue;
      }

      // Cheap no-conflict fast path: nil/empty for nearly every file.
      NSArray<NSFileVersion*>* conflicts =
          [NSFileVersion unresolvedConflictVersionsOfItemAtURL:url];
      if (conflicts.count == 0) {
        continue;
      }

      // Decide which version to keep. +currentVersionOfItemAtURL: is the copy
      // the POSIX driver will actually open, so prefer it; only swap the file
      // into place if a conflict version is strictly newer by modificationDate.
      NSFileVersion* current = [NSFileVersion currentVersionOfItemAtURL:url];
      NSFileVersion* newest = current;
      NSDate* newestDate = current.modificationDate;
      for (NSFileVersion* v in conflicts) {
        NSDate* d = v.modificationDate;
        if (d != nil && (newestDate == nil || [d compare:newestDate] == NSOrderedDescending)) {
          newest = v;
          newestDate = d;
        }
      }

      // If a conflict version won, promote its contents into the canonical URL
      // under a coordinated write so we don't race the sync daemon.
      if (newest != nil && newest != current) {
        NSFileCoordinator* coord = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
        NSError* coordErr = nil;
        [coord coordinateWritingItemAtURL:url
                                  options:NSFileCoordinatorWritingForReplacing
                                    error:&coordErr
                               byAccessor:^(NSURL* newURL) {
                                 NSError* replaceErr = nil;
                                 if ([newest replaceItemAtURL:newURL options:0 error:&replaceErr] == nil) {
                                   NSLog(
                                       @"[RRRevoloution] iCloud: could not promote newer conflict "
                                       @"version of %@ (%@)",
                                       url.lastPathComponent, replaceErr.localizedDescription);
                                 }
                               }];
        if (coordErr != nil) {
          NSLog(
              @"[RRRevoloution] iCloud: coordination failed resolving %@ (%@)",
              url.lastPathComponent, coordErr.localizedDescription);
        }
      }

      // Mark every conflict version resolved and remove the non-current
      // versions so the engine never sees a conflicted item. removeOtherVersions
      // collapses to just the current version on disk.
      for (NSFileVersion* v in conflicts) {
        v.resolved = YES;
      }
      NSError* removeErr = nil;
      if (![NSFileVersion removeOtherVersionsOfItemAtURL:url error:&removeErr]) {
        NSLog(
            @"[RRRevoloution] iCloud: could not remove other versions of %@ (%@)",
            url.lastPathComponent, removeErr.localizedDescription);
      }
      resolvedFiles++;
    }
  }

  if (resolvedFiles > 0) {
    NSLog(
        @"[RRRevoloution] iCloud: resolved conflicts on %lu file(s).",
        (unsigned long)resolvedFiles);
  }
}

// Creates a directory under an NSFileCoordinator coordinated write so the
// create doesn't race the iCloud sync daemon. Used only for our own mount-point
// subdirs (Save/Songs/...); the engine's own file writes are intentionally left
// uncoordinated — wrapping them would mean rewriting the RageFile layer.
//
// MRC note: the coordinator is autoreleased and the accessor block is
// non-escaping (NS_NOESCAPE), so it runs synchronously before this returns and
// captures `fm`/`dirURL` safely without a retain cycle.
static void CoordinatedCreateDirectory(NSFileManager* fm, NSURL* dirURL) {
  NSFileCoordinator* coord = [[[NSFileCoordinator alloc] initWithFilePresenter:nil] autorelease];
  NSError* coordErr = nil;
  [coord coordinateWritingItemAtURL:dirURL
                            options:0
                              error:&coordErr
                         byAccessor:^(NSURL* newURL) {
                           NSError* createErr = nil;
                           if (![fm createDirectoryAtURL:newURL
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&createErr]) {
                             NSLog(
                                 @"[RRRevoloution] iCloud: could not create %@ (%@)",
                                 newURL.lastPathComponent, createErr.localizedDescription);
                           }
                         }];
  if (coordErr != nil) {
    NSLog(
        @"[RRRevoloution] iCloud: coordination failed creating %@ (%@)",
        dirURL.lastPathComponent, coordErr.localizedDescription);
  }
}

/* Set once during MountUserFilesystems, read later to tell the player where
 * content goes. The sandbox fallback is a dead end on tvOS -- nothing can reach
 * that directory -- so it has to be said out loud rather than logged. */
static std::string g_sContentStorage;

// Resolves the user-content Documents root shared by the game mount and the
// upload server, so the two never diverge. Honors the ITGmaniaUseICloud toggle
// (default-on) and falls back to the local sandbox when iCloud is unavailable.
static std::string UserDocumentsRoot(bool* outUsingICloud) {
  bool usingICloud = false;
  std::string docsDir;

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
  if (docsDir.empty()) {
    docsDir = PathForDirectory(NSDocumentDirectory);
  }
  if (usingICloud) {
    g_sContentStorage = "icloud";
  } else if (wantICloud) {
    /* Asked for iCloud and did not get it: the container is missing from the
     * signing entitlements, or the box is not signed in to iCloud. */
    g_sContentStorage = "unavailable";
  } else {
    g_sContentStorage = "disabled";
  }
  if (outUsingICloud != nullptr) {
    *outUsingICloud = usingICloud;
  }
  return docsDir;
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
  bool usingICloud = false;
  std::string docsDir = UserDocumentsRoot(&usingICloud);

  NSString* docsNS = [NSString stringWithUTF8String:docsDir.c_str()];
  NSArray<NSString*>* docSubdirs =
      @[ @"Save", @"Songs", @"Packages", @"NoteSkins", @"Themes", @"Courses", @"Downloads" ];
  for (NSString* sub in docSubdirs) {
    NSString* subPath = [docsNS stringByAppendingPathComponent:sub];
    if (usingICloud) {
      // These live in the ubiquity container; coordinate the create so it does
      // not race the iCloud sync daemon (H3). Local sandbox needs no coordination.
      CoordinatedCreateDirectory(fm, [NSURL fileURLWithPath:subPath isDirectory:YES]);
    } else {
      [fm createDirectoryAtPath:subPath
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
    }
  }
  // MountUserFilesystems runs before LOG is initialized, so use NSLog so
  // this is still visible (in os_log / `xcrun simctl spawn booted log stream`).
  NSLog(
      @"[RRRevoloution] User Documents root: %s (%s)", docsDir.c_str(),
      usingICloud ? "iCloud Drive" : "local sandbox");

  // Pull down any iCloud content that exists only as a placeholder (added on
  // another device or evicted) before mounting, so the "dir" driver and the
  // song scan that follows can actually read it.
  if (usingICloud) {
    NSURL* icloudDocs = ICloudDocumentsURL();
    if (icloudDocs != nil) {
      MaterializeICloudTree(icloudDocs, kICloudMaterializeTimeoutSeconds);
      // After materialization, collapse any cross-device NSFileVersion conflicts
      // so the engine never reads a conflicted file (silent score loss). Cheap
      // no-conflict fast path keeps this near-free on a clean library.
      ResolveICloudConflicts(icloudDocs);
    }
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
  // Serve the same root MountUserFilesystems mounted (shared resolver +
  // cached container URL) so uploads land where the game reads from.
  std::string docsPath = UserDocumentsRoot(nullptr);
  UploadServer_Start(docsPath);
}

void ArchHooks_tvOS::RefreshUserContent() {
  if (g_sContentStorage != "icloud") {
    return;
  }
  /* Songs dropped into iCloud Drive from another device arrive as metadata
   * first: the rescan would list the filenames and find nothing behind them.
   * Boot already does this once; doing it again here is what lets a pack added
   * while the app is running show up without relaunching. */
  NSURL* icloudDocs = ICloudDocumentsURL();
  if (icloudDocs == nil) {
    return;
  }
  LOG->Info("iCloud: downloading any new content before reload");
  MaterializeICloudTree(icloudDocs, kICloudMaterializeTimeoutSeconds);
  ResolveICloudConflicts(icloudDocs);
}

std::string ArchHooks_tvOS::GetContentStorageStatus() const {
  std::string sUpload = UploadServer_GetURL();
  std::string sWhere;

  if (g_sContentStorage == "icloud") {
    sWhere = "Songs: iCloud Drive \xE2\x86\x92 " PRODUCT_ID " \xE2\x86\x92 Songs";
  } else if (g_sContentStorage == "unavailable") {
    /* Nothing the player does on the TV can fix this one, so name the two
     * causes rather than just reporting the symptom. */
    sWhere =
        "iCloud Drive unavailable (not signed in, or the app is missing the "
        "iCloud entitlement) \xE2\x80\x94 songs are stored on this device only";
  } else {
    sWhere = "iCloud Drive off \xE2\x80\x94 songs are stored on this device only";
  }

  if (!sUpload.empty()) {
    sWhere += ".  Add songs from a browser: " + sUpload;
  }
  return sWhere;
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
