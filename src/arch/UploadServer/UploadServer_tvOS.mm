/*
 * tvOS-only embedded HTTP server for uploading Songs, Themes, etc. via browser.
 * Uses WebServerKit (GCDWebServer). GET / returns an upload form; POST /upload
 * accepts multipart form data and writes files under the app Documents directory.
 */

#include "UploadServer_tvOS.h"
#include <atomic>
#include <string>
#include "RageLog.h"
#include "global.h"

#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import "GCDWebServer.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerErrorResponse.h"
#import "GCDWebServerMultiPartFormRequest.h"
#import "GCDWebServerURLEncodedFormRequest.h"

static const NSUInteger kUploadPort = 8080;
static NSArray<NSString*>* s_allowedTargets = nil;
static NSString* s_documentsPath =
    nil;  // app Documents dir; same path mounted at /Songs, /Themes, etc.
static GCDWebServer* s_server = nil;
static BOOL s_startScheduled = NO;
/* Read from the game thread via UploadServer_GetURL() while the server starts
 * on the main queue. */
static std::atomic<bool> s_urlReady{false};
static NSString* s_url = nil;

/** Return first non-loopback IPv4 address as string, or empty if none. */
static NSString* GetLANIPAddress(void) {
  struct ifaddrs* ifa = nil;
  if (getifaddrs(&ifa) != 0) {
    return @"";
  }
  NSString* result = @"";
  for (struct ifaddrs* p = ifa; p != nil; p = p->ifa_next) {
    if (p->ifa_addr == nil || p->ifa_addr->sa_family != AF_INET) {
      continue;
    }
    struct sockaddr_in* sa = (struct sockaddr_in*)p->ifa_addr;
    if (sa->sin_addr.s_addr == inet_addr("127.0.0.1")) {
      continue;
    }
    char buf[INET_ADDRSTRLEN];
    if (inet_ntop(AF_INET, &sa->sin_addr, buf, sizeof(buf)) != nil) {
      result = [NSString stringWithUTF8String:buf];
    }
    break;
  }
  freeifaddrs(ifa);
  return result;
}

/** Build a JSON-serializable tree of directory contents (name + optional children). */
static NSArray* BuildFileTree(NSString* dirPath, NSFileManager* fm) {
  NSError* err = nil;
  NSArray<NSString*>* names = [fm contentsOfDirectoryAtPath:dirPath error:&err];
  if (names == nil || err != nil) {
    return @[];
  }
  NSMutableArray* nodes = [NSMutableArray array];
  // Sort: directories first, then alphabetically by name
  NSArray* sorted =
      [names sortedArrayUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
        NSString* pathA = [dirPath stringByAppendingPathComponent:a];
        NSString* pathB = [dirPath stringByAppendingPathComponent:b];
        BOOL dirA = NO, dirB = NO;
        (void)[fm fileExistsAtPath:pathA isDirectory:&dirA];
        (void)[fm fileExistsAtPath:pathB isDirectory:&dirB];
        if (dirA != dirB) {
          return dirA ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a caseInsensitiveCompare:b];
      }];
  for (NSString* name in sorted) {
    if ([name hasPrefix:@"."]) {
      continue;
    }
    NSString* fullPath = [dirPath stringByAppendingPathComponent:name];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:fullPath isDirectory:&isDir]) {
      continue;
    }
    if (isDir) {
      NSArray* children = BuildFileTree(fullPath, fm);
      [nodes addObject:@{@"name" : name, @"children" : children}];
    } else {
      [nodes addObject:@{@"name" : name}];
    }
  }
  return nodes;
}

/** Sanitize a single path component: no "..", only safe chars. */
static NSString* SanitizePathComponent(NSString* segment) {
  if (segment.length == 0 || [segment isEqualToString:@"."] || [segment isEqualToString:@".."]) {
    return nil;
  }
  NSCharacterSet* unsafe = [[NSCharacterSet
      characterSetWithCharactersInString:
          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._- "] invertedSet];
  NSArray<NSString*>* parts = [segment componentsSeparatedByCharactersInSet:unsafe];
  NSString* safe = [parts componentsJoinedByString:@""];
  return safe.length > 0 ? safe : nil;
}

/**
 * Sanitize an uploaded relative path ("My Pack/A Song/song.sm") one component
 * at a time, keeping the folder structure.
 *
 * A song is a directory, not a file: the engine finds charts as
 * Songs/<group>/<song>/, and its .sm metadata refers to sibling audio and
 * banners by name. Flattening an upload into Songs/ therefore transfers every
 * byte and still yields nothing playable. Spaces survive too, since pack and
 * song directories are full of them.
 *
 * Returns nil when no component survives.
 */
static NSString* SanitizeRelativePath(NSString* path) {
  NSMutableArray<NSString*>* safe = [NSMutableArray array];
  for (NSString* segment in [path componentsSeparatedByString:@"/"]) {
    NSString* clean = SanitizePathComponent(segment);
    if (clean != nil) {
      [safe addObject:clean];
    }
  }
  if (safe.count == 0) {
    return nil;
  }
  return [safe componentsJoinedByString:@"/"];
}

static NSString* UploadHTML(void) {
  NSMutableString* tabs = [NSMutableString string];
  for (NSString* t in s_allowedTargets) {
    NSString* tid = [t lowercaseString];
    [tabs
        appendFormat:
            @"<div class=\"tab\" data-target=\"%@\">"
            @"<h2>%@</h2>"
            @"<div class=\"dropzone\" data-target=\"%@\" "
            @"ondragover=\"event.preventDefault();event.stopPropagation();this.classList.add('drag-"
            @"over');this.querySelector('.dropzone-text').textContent='Release to upload';\" "
            @"ondragleave=\"event.preventDefault();this.classList.remove('drag-over');this."
            @"querySelector('.dropzone-text').textContent='Drop folder or files here';\" "
            @"ondrop=\"handleDrop(event,'%@')\"><span class=\"dropzone-text\">Drop folder or files "
            @"here</span><span class=\"dropzone-status\" aria-live=\"polite\"></span></div>"
            @"<p><button type=\"button\" "
            @"onclick=\"document.getElementById('target').value='%@';document.getElementById('"
            @"files').click()\">Add folder…</button></p>"
            @"</div>",
            t, t, t, t, t];
  }
  return [NSString
      stringWithFormat:
          @"<!DOCTYPE html><html><head><meta charset=\"UTF-8\"><title>ITGmania Upload</title>"
          @"<style>"
          @"body{font-family:system-ui;margin:1rem;} "
          @".tabs{display:flex;flex-wrap:wrap;gap:0.5rem;} .tab{border:1px solid "
          @"#ccc;padding:1rem;min-width:10rem;} .tab.active{background:#e8f4fc;} "
          @".dropzone{border:2px dashed #999;padding:2rem;margin:0.5rem "
          @"0;min-height:5rem;display:flex;flex-direction:column;align-items:center;justify-"
          @"content:center;text-align:center;transition:border-color .15s,background .15s;} "
          @".dropzone.drag-over{border-color:#06c;border-width:3px;background:#e0f0ff;} "
          @".dropzone.uploading{border-color:#690;background:#f0ffe0;} .dropzone.uploading "
          @".dropzone-text{font-weight:bold;} "
          @".dropzone.done{border-color:#060;background:#e8f8e8;} "
          @".dropzone.error{border-color:#c00;background:#ffe8e8;} "
          @".dropzone-status{margin-top:0.5rem;font-size:0.9em;} label{display:block;margin:0.5rem "
          @"0;} .overwrite-wrap{margin:1rem 0;} .overwrite-wrap .radio{margin:0.25rem 0;}"
          @"</style></head><body><h1>ITGmania Upload</h1>"
          @"<form action=\"/upload\" method=\"post\" enctype=\"multipart/form-data\" "
          @"id=\"uploadForm\">"
          @"<input type=\"hidden\" name=\"target\" id=\"target\" value=\"Songs\">"
          @"<input type=\"file\" name=\"files\" id=\"files\" multiple webkitdirectory directory "
          @"style=\"display:none\">"
          @"<div class=\"tabs\">%@</div>"
          @"<p class=\"overwrite-wrap\">When an uploaded folder has the same name:<br>"
          @"<label class=\"radio\"><input type=\"radio\" name=\"overwrite\" value=\"1\"> Replace "
          @"the current contents with the new folder</label>"
          @"<label class=\"radio\"><input type=\"radio\" name=\"overwrite\" value=\"\" checked> "
          @"Merge two folders contents</label></p>"
          @"<p><button type=\"submit\">Upload</button> <span id=\"formStatus\" "
          @"aria-live=\"polite\"></span></p>"
          @"</form>"
          @"<script>"
          @"function handleDrop(e,target){e.preventDefault();e.stopPropagation();var "
          @"zone=e.currentTarget;zone.classList.remove('drag-over');zone.querySelector('.dropzone-"
          @"text').textContent='Drop folder or files here';"
          @"var files=e.dataTransfer.files;if(files.length===0)return;"
          @"zone.classList.add('uploading');zone.classList.remove('done','error');zone."
          @"querySelector('.dropzone-status').textContent='Uploading '+files.length+' item(s)...';"
          @"var fd=new "
          @"FormData();fd.append('target',target);fd.append('overwrite',(document.querySelector('["
          @"name=overwrite]:checked')&&document.querySelector('[name=overwrite]:checked').value)||'"
          @"');for(var i=0;i<files.length;i++)fd.append('files',files[i],files[i]."
          @"webkitRelativePath||files[i].name);"
          @"fetch('/"
          @"upload',{method:'POST',body:fd}).then(r=>r.text()).then(function(t){zone.classList."
          @"remove('uploading');var status=zone.querySelector('.dropzone-status');"
          @"if(t.indexOf('Saved')>=0){zone.classList.add('done');var n=(t.match(/Saved "
          @"(\\d+)/)||[])[1]||'?';status.textContent='Saved '+n+' file(s).';}"
          @"else{zone.classList.add('error');status.textContent=(t.indexOf('error')>=0||t.indexOf('"
          @"Error')>=0)?(t.replace(/<[^>]*>/g,'').trim().slice(0,150)):'Upload failed.';}"
          @"}).catch(function(err){zone.classList.remove('uploading');zone.classList.add('error');"
          @"zone.querySelector('.dropzone-status').textContent='Error: '+err.message;});}"
          /* A native form POST sends bare basenames -- webkitRelativePath is a
             JS-only property -- so the folder the user picked would arrive
             flattened. Send it ourselves instead. */
          @"document.getElementById('uploadForm').addEventListener('submit',function(e){"
          @"e.preventDefault();var files=document.getElementById('files').files;"
          @"var out=document.getElementById('formStatus');"
          @"if(!files.length){out.textContent='Choose a folder first.';return;}"
          @"out.textContent='Uploading '+files.length+' file(s)...';"
          @"var fd=new FormData();fd.append('target',document.getElementById('target').value);"
          @"fd.append('overwrite',(document.querySelector('[name=overwrite]:checked')&&document."
          @"querySelector('[name=overwrite]:checked').value)||'');"
          @"for(var i=0;i<files.length;i++)fd.append('files',files[i],files[i].webkitRelativePath||"
          @"files[i].name);"
          @"fetch('/upload',{method:'POST',body:fd}).then(r=>r.text()).then(function(t){"
          @"var n=(t.match(/Saved (\\d+)/)||[])[1];"
          @"out.textContent=n?('Saved '+n+' file(s). Reload songs on the TV to see them.'):"
          @"t.replace(/<[^>]*>/g,'').trim().slice(0,150);"
          @"}).catch(function(err){out.textContent='Error: '+err.message;});});"
          @"</script></body></html>",
          tabs];
}

static void StartServerOnMainQueue(void) {
  s_startScheduled = NO;
  if (s_documentsPath == nil) {
    return;
  }
  // GCDWebServer +initialize asserts main thread; create server only here on main queue
  s_server = [[GCDWebServer alloc] init];

  // Register static/fallback GET first so it is tried last (handlers are LIFO: last registered =
  // first tried). We want /list, /upload, /delete to take precedence over the base path.
  NSFileManager* fm = [NSFileManager defaultManager];
  NSString* bundleResources = [[NSBundle mainBundle] resourcePath];
  NSString* uploadUIPath =
      bundleResources != nil ? [bundleResources stringByAppendingPathComponent:@"dist"] : nil;
  BOOL useReactUI = (uploadUIPath != nil && [fm fileExistsAtPath:uploadUIPath]);
  if (useReactUI) {
    [s_server addGETHandlerForBasePath:@"/"
                         directoryPath:uploadUIPath
                         indexFilename:@"index.html"
                              cacheAge:0
                    allowRangeRequests:NO];
  } else {
    [s_server addHandlerForMethod:@"GET"
                             path:@"/"
                     requestClass:[GCDWebServerRequest class]
                     processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                       return [GCDWebServerDataResponse responseWithHTML:UploadHTML()];
                     }];
  }

  [s_server
      addHandlerForMethod:@"POST"
                     path:@"/upload"
             requestClass:[GCDWebServerMultiPartFormRequest class]
             processBlock:^GCDWebServerResponse*(GCDWebServerRequest* req) {
               GCDWebServerMultiPartFormRequest* request = (GCDWebServerMultiPartFormRequest*)req;
               NSString* target = @"Songs";
               GCDWebServerMultiPartArgument* arg = [request firstArgumentForControlName:@"target"];
               if (arg.string.length > 0) {
                 NSString* t = arg.string;
                 if ([s_allowedTargets containsObject:t]) {
                   target = t;
                 }
               }
               NSString* targetDir = [s_documentsPath stringByAppendingPathComponent:target];
               NSFileManager* fm = [NSFileManager defaultManager];
               NSError* mkdirErr = nil;
               if (![fm createDirectoryAtPath:targetDir
                       withIntermediateDirectories:YES
                                        attributes:nil
                                             error:&mkdirErr]) {
                 LOG->Warn(
                     "Upload server: could not create directory '%s': %s", targetDir.UTF8String,
                     mkdirErr.localizedDescription.UTF8String);
                 return [GCDWebServerErrorResponse
                     responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                     message:@"Invalid target"];
               }
               BOOL overwrite = NO;
               GCDWebServerMultiPartArgument* overwriteArg =
                   [request firstArgumentForControlName:@"overwrite"];
               if (overwriteArg != nil && overwriteArg.string.length > 0 &&
                   [overwriteArg.string.lowercaseString hasPrefix:@"1"]) {
                 overwrite = YES;
               }
               NSMutableArray<NSString*>* saved = [NSMutableArray array];
               NSString* resolvedTarget =
                   [[targetDir stringByStandardizingPath] stringByAppendingString:@"/"];
               for (GCDWebServerMultiPartFile* file in request.files) {
                 NSString* safeName = SanitizeRelativePath(file.fileName);
                 if (safeName.length == 0) {
                   continue;
                 }
                 NSString* destPath = [targetDir stringByAppendingPathComponent:safeName];
                 /* Belt and braces: the per-component sanitize already drops
                  * "..", so a path escaping the target means a bug here, not a
                  * request to honor. */
                 if (![[destPath stringByStandardizingPath] hasPrefix:resolvedTarget]) {
                   LOG->Warn(
                       "Upload server: rejected '%s' (escapes %s)", file.fileName.UTF8String,
                       target.UTF8String);
                   continue;
                 }
                 if (!overwrite && [fm fileExistsAtPath:destPath]) {
                   continue;  // deep merge: only new files
                 }
                 NSError* mkErr = nil;
                 if (![fm createDirectoryAtPath:[destPath stringByDeletingLastPathComponent]
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:&mkErr]) {
                   LOG->Warn(
                       "Upload server: could not create '%s': %s", destPath.UTF8String,
                       mkErr.localizedDescription.UTF8String);
                   continue;
                 }
                 NSError* err = nil;
                 if (overwrite && [fm removeItemAtPath:destPath error:nil]) {
                   (void)0;
                 }
                 if ([fm copyItemAtPath:file.temporaryPath toPath:destPath error:&err]) {
                   [saved addObject:safeName];
                   LOG->Info(
                       "Upload server: saved '%s' to %s", safeName.UTF8String, target.UTF8String);
                 } else {
                   LOG->Warn(
                       "Upload server: failed to save '%s': %s", destPath.UTF8String,
                       err.localizedDescription.UTF8String);
                 }
               }
               NSString* body = saved.count > 0
                                    ? [NSString stringWithFormat:@"<p>Saved %lu file(s) to %@.</p>",
                                                                 (unsigned long)saved.count, target]
                                    : @"<p>No files saved.</p>";
               return [GCDWebServerDataResponse
                   responseWithHTML:
                       [@"<!DOCTYPE html><html><body><h1>Upload</h1>"
                           stringByAppendingString:
                               [body stringByAppendingString:
                                         @"<p><a href=\"/\">Back</a></p></body></html>"]]];
             }];

  [s_server addHandlerForMethod:@"GET"
                           path:@"/list"
                   requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse*(GCDWebServerRequest* req) {
                     @try {
                       NSString* target = req.query[@"target"] ?: @"Songs";
                       if (![s_allowedTargets containsObject:target]) {
                         return [GCDWebServerErrorResponse
                             responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                             message:@"Invalid target"];
                       }
                       if (s_documentsPath == nil || s_documentsPath.length == 0) {
                         return [GCDWebServerDataResponse responseWithJSONObject:@{@"tree" : @[]}];
                       }
                       NSString* targetDir =
                           [s_documentsPath stringByAppendingPathComponent:target];
                       NSFileManager* fm = [NSFileManager defaultManager];
                       if (![fm fileExistsAtPath:targetDir isDirectory:NULL]) {
                         return [GCDWebServerDataResponse responseWithJSONObject:@{@"tree" : @[]}];
                       }
                       NSArray* tree = BuildFileTree(targetDir, fm);
                       return [GCDWebServerDataResponse responseWithJSONObject:@{@"tree" : tree}];
                     } @catch (NSException* ex) {
                       LOG->Warn("Upload server: /list failed: %s", ex.reason.UTF8String);
                       return [GCDWebServerDataResponse responseWithJSONObject:@{@"tree" : @[]}];
                     }
                   }];

  [s_server
      addHandlerForMethod:@"POST"
                     path:@"/delete"
             requestClass:[GCDWebServerURLEncodedFormRequest class]
             processBlock:^GCDWebServerResponse*(GCDWebServerRequest* req) {
               GCDWebServerURLEncodedFormRequest* request = (GCDWebServerURLEncodedFormRequest*)req;
               NSString* target = request.arguments[@"target"];
               if (!target || ![s_allowedTargets containsObject:target]) {
                 return [GCDWebServerErrorResponse
                     responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                     message:@"Invalid target"];
               }
               NSString* pathArg = request.arguments[@"path"];
               if (!pathArg || pathArg.length == 0) {
                 return [GCDWebServerErrorResponse
                     responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                     message:@"Missing path"];
               }
               NSArray<NSString*>* segments = [pathArg componentsSeparatedByString:@"/"];
               NSMutableArray<NSString*>* safeSegments = [NSMutableArray array];
               for (NSString* seg in segments) {
                 NSString* s = SanitizePathComponent(
                     [seg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]);
                 if (s == nil) {
                   return [GCDWebServerErrorResponse
                       responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                       message:@"Invalid path"];
                 }
                 [safeSegments addObject:s];
               }
               NSString* relativePath = [safeSegments componentsJoinedByString:@"/"];
               NSString* targetDir = [s_documentsPath stringByAppendingPathComponent:target];
               NSString* fullPath = [targetDir stringByAppendingPathComponent:relativePath];
               NSString* resolved = [fullPath stringByResolvingSymlinksInPath];
               NSString* resolvedTarget = [targetDir stringByResolvingSymlinksInPath];
               if (![resolved hasPrefix:resolvedTarget] ||
                   [resolved isEqualToString:resolvedTarget]) {
                 return [GCDWebServerErrorResponse
                     responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                     message:@"Invalid path"];
               }
               NSFileManager* fm = [NSFileManager defaultManager];
               if (![fm fileExistsAtPath:fullPath]) {
                 return [GCDWebServerErrorResponse
                     responseWithClientError:kGCDWebServerHTTPStatusCode_NotFound
                                     message:@"Not found"];
               }
               NSError* err = nil;
               if (![fm removeItemAtPath:fullPath error:&err]) {
                 LOG->Warn(
                     "Upload server: failed to delete '%s': %s", fullPath.UTF8String,
                     err.localizedDescription.UTF8String);
                 return [GCDWebServerErrorResponse
                     responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError
                             underlyingError:err
                                     message:@"Delete failed"];
               }
               LOG->Info(
                   "Upload server: deleted '%s' from %s", relativePath.UTF8String,
                   target.UTF8String);
               return [GCDWebServerDataResponse responseWithJSONObject:@{@"ok" : @YES}];
             }];

  NSError* err = nil;
  NSDictionary* opts = @{GCDWebServerOption_Port : @(kUploadPort)};
  if (![s_server startWithOptions:opts error:&err]) {
    LOG->Warn("Upload server: failed to start: %s", err.localizedDescription.UTF8String);
    s_server = nil;
    return;
  }
  NSString* ip = GetLANIPAddress();
  if (ip.length > 0) {
    s_url = [NSString stringWithFormat:@"http://%@:%lu", ip, (unsigned long)kUploadPort];
    s_urlReady = true;
    LOG->Info("Upload at %s", s_url.UTF8String);
  } else {
    LOG->Info("Upload server running on port %lu", (unsigned long)kUploadPort);
  }
}

void UploadServer_Start(const std::string& documentsPath) {
  if (s_server != nil && s_server.running) {
    return;
  }
  if (s_startScheduled) {
    return;
  }
  if (documentsPath.empty()) {
    LOG->Warn("Upload server: no Documents path provided");
    return;
  }

  s_allowedTargets = @[ @"Songs", @"Themes", @"NoteSkins", @"Courses", @"Packages" ];
  s_documentsPath = [NSString stringWithUTF8String:documentsPath.c_str()];
  s_startScheduled = YES;
  // GCDWebServer requires first use (including +initialize) on main thread; do all creation on main
  // queue
  dispatch_async(dispatch_get_main_queue(), ^{
    StartServerOnMainQueue();
  });
}

void UploadServer_Stop(void) {
  if (s_server != nil) {
    [s_server stop];
    s_server = nil;
  }
  s_urlReady = false;
}

std::string UploadServer_GetURL(void) {
  if (!s_urlReady) {
    return std::string();
  }
  return std::string(s_url.UTF8String);
}
