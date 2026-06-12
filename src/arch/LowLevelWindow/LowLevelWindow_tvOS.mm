#import "LowLevelWindow_tvOS.h"
#import "DisplaySpec.h"
#import "RageDisplay_OGL_Helpers.h"
#import "RageLog.h"
#import "RageThreads.h"
#import "RageUtil.h"
#import "arch/ArchHooks/ArchHooks.h"
#import "global.h"

#include <cstddef>
#include <cstdint>

#import <CoreVideo/CoreVideo.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

static EAGLContext* g_EAGLContext = nil;
static UIImageView* g_HostView = nil;
static GLuint g_Framebuffer = 0;
static GLuint g_DepthRenderbuffer = 0;
static GLint g_BackingWidth = 0;
static GLint g_BackingHeight = 0;

/* CVPixelBuffer zero-copy path (used on real hardware) */
static CVOpenGLESTextureCacheRef g_TextureCache = NULL;
static CVPixelBufferRef g_PixelBuffer = NULL;
static CVOpenGLESTextureRef g_CVTexture = NULL;
static bool g_bUseCVPath = false;

/* Readback path: double-buffered PBOs for async readback */
static GLuint g_PBO[2] = {0, 0};
static int g_PBOIndex = 0;
static bool g_bUsePBO = false;
static bool g_bFirstFrame = true;

/* Persistent pixel buffer for readback */
static uint8_t* g_ReadbackBuf = NULL;

static bool SetupCVRenderTarget(int w, int h) {
  CVReturn err =
      CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, g_EAGLContext, NULL, &g_TextureCache);
  if (err != kCVReturnSuccess) {
    return false;
  }

  NSDictionary* pbAttrs = @{
    (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (NSString*)kCVPixelBufferOpenGLESCompatibilityKey : @YES,
  };

  err = CVPixelBufferCreate(
      kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)pbAttrs,
      &g_PixelBuffer);
  if (err != kCVReturnSuccess) {
    CFRelease(g_TextureCache);
    g_TextureCache = NULL;
    return false;
  }

  err = CVOpenGLESTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, g_TextureCache, g_PixelBuffer, NULL, GL_TEXTURE_2D, GL_RGBA, w, h,
      GL_BGRA, GL_UNSIGNED_BYTE, 0, &g_CVTexture);
  if (err != kCVReturnSuccess) {
    CFRelease(g_PixelBuffer);
    g_PixelBuffer = NULL;
    CFRelease(g_TextureCache);
    g_TextureCache = NULL;
    return false;
  }

  GLuint texName = CVOpenGLESTextureGetName(g_CVTexture);
  glBindTexture(GL_TEXTURE_2D, texName);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texName, 0);

  GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
  if (status != GL_FRAMEBUFFER_COMPLETE) {
    CFRelease(g_CVTexture);
    g_CVTexture = NULL;
    CFRelease(g_PixelBuffer);
    g_PixelBuffer = NULL;
    CFRelease(g_TextureCache);
    g_TextureCache = NULL;
    return false;
  }

  LOG->Info("CVPixelBuffer render target created: %dx%d", w, h);
  return true;
}

static void SetupPBOs(int w, int h) {
  size_t dataSize = (size_t)w * h * 4;
  glGenBuffers(2, g_PBO);
  for (int i = 0; i < 2; i++) {
    glBindBuffer(GL_PIXEL_PACK_BUFFER, g_PBO[i]);
    glBufferData(GL_PIXEL_PACK_BUFFER, dataSize, NULL, GL_STREAM_READ);
  }
  glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  g_bUsePBO = true;
  g_bFirstFrame = true;
  LOG->Info("PBO async readback initialized: %dx%d", w, h);
}

static void FreeDataProviderCallback(void* info, const void* data, size_t size) { free(info); }

LowLevelWindow_tvOS::LowLevelWindow_tvOS() {
  m_EAGLContext = nil;
  m_GLView = nil;
}

LowLevelWindow_tvOS::~LowLevelWindow_tvOS() {
  [EAGLContext setCurrentContext:g_EAGLContext];
  if (g_Framebuffer) {
    glDeleteFramebuffers(1, &g_Framebuffer);
    g_Framebuffer = 0;
  }
  if (g_DepthRenderbuffer) {
    glDeleteRenderbuffers(1, &g_DepthRenderbuffer);
    g_DepthRenderbuffer = 0;
  }
  if (g_bUsePBO) {
    glDeleteBuffers(2, g_PBO);
    g_PBO[0] = g_PBO[1] = 0;
  }
  if (g_CVTexture) {
    CFRelease(g_CVTexture);
    g_CVTexture = NULL;
  }
  if (g_PixelBuffer) {
    CFRelease(g_PixelBuffer);
    g_PixelBuffer = NULL;
  }
  if (g_TextureCache) {
    CFRelease(g_TextureCache);
    g_TextureCache = NULL;
  }
  free(g_ReadbackBuf);
  g_ReadbackBuf = NULL;
  [EAGLContext setCurrentContext:nil];
  g_EAGLContext = nil;
  g_HostView = nil;
}

void* LowLevelWindow_tvOS::GetProcAddress(std::string s) { return nil; }

std::string LowLevelWindow_tvOS::TryVideoMode(const VideoModeParams& p, bool& newDeviceOut) {
  newDeviceOut = false;

  dispatch_sync(dispatch_get_main_queue(), ^{
    UIWindow* window = [UIApplication sharedApplication].keyWindow;
    if (!window) {
      return;
    }

    if (!g_HostView) {
      g_HostView = [[UIImageView alloc] initWithFrame:window.bounds];
      g_HostView.backgroundColor = [UIColor blackColor];
      g_HostView.autoresizingMask =
          UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
      g_HostView.contentMode = UIViewContentModeScaleToFill;
      g_HostView.opaque = YES;
      [window.rootViewController.view addSubview:g_HostView];

      newDeviceOut = true;
    }
  });

  if (newDeviceOut) {
    CGRect bounds = [UIScreen mainScreen].bounds;

    /*
     * On real hardware the CVPixelBuffer zero-copy path is fast at full res.
     * On the simulator (software renderer), reduce resolution for usable
     * framerates. The UIImageView scales it back up.
     */
#if TARGET_OS_SIMULATOR
    g_BackingWidth = static_cast<GLint>(bounds.size.width / 2);
    g_BackingHeight = static_cast<GLint>(bounds.size.height / 2);
#else
    g_BackingWidth = static_cast<GLint>(bounds.size.width);
    g_BackingHeight = static_cast<GLint>(bounds.size.height);
#endif

    g_EAGLContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (!g_EAGLContext) {
      g_EAGLContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    }

    [EAGLContext setCurrentContext:g_EAGLContext];

    glGenFramebuffers(1, &g_Framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, g_Framebuffer);

    g_bUseCVPath = SetupCVRenderTarget(g_BackingWidth, g_BackingHeight);
    if (!g_bUseCVPath) {
      LOG->Info("CVPixelBuffer path unavailable, using readback path.");
      GLuint rb;
      glGenRenderbuffers(1, &rb);
      glBindRenderbuffer(GL_RENDERBUFFER, rb);
      glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, g_BackingWidth, g_BackingHeight);
      glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);

      SetupPBOs(g_BackingWidth, g_BackingHeight);
    }

    glGenRenderbuffers(1, &g_DepthRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, g_DepthRenderbuffer);
    glRenderbufferStorage(
        GL_RENDERBUFFER, GL_DEPTH_COMPONENT24_OES, g_BackingWidth, g_BackingHeight);
    glFramebufferRenderbuffer(
        GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, g_DepthRenderbuffer);
  } else {
    [EAGLContext setCurrentContext:g_EAGLContext];
    glBindFramebuffer(GL_FRAMEBUFFER, g_Framebuffer);
  }

  m_EAGLContext = g_EAGLContext;
  m_GLView = g_HostView;

  m_CurrentParams.width = g_BackingWidth;
  m_CurrentParams.height = g_BackingHeight;
  m_CurrentParams.bpp = 32;
  m_CurrentParams.rate = 60;
  m_CurrentParams.vsync = true;
  m_CurrentParams.windowed = false;

  return std::string();
}

void LowLevelWindow_tvOS::GetDisplaySpecs(DisplaySpecs& specs) const {
  CGRect bounds = [UIScreen mainScreen].bounds;
  CGFloat scale = [UIScreen mainScreen].scale;

  int w = static_cast<int>(bounds.size.width * scale);
  int h = static_cast<int>(bounds.size.height * scale);

  DisplayMode mode = {static_cast<unsigned int>(w), static_cast<unsigned int>(h), 60.0};
  DisplaySpec spec("tvOS", "Apple TV Display", mode);
  specs.insert(spec);
}

void LowLevelWindow_tvOS::BeginConcurrentRendering() {
  [EAGLContext setCurrentContext:g_EAGLContext];
  glBindFramebuffer(GL_FRAMEBUFFER, g_Framebuffer);
}

void LowLevelWindow_tvOS::SwapBuffers() {
  GLint w = g_BackingWidth;
  GLint h = g_BackingHeight;

  if (g_bUseCVPath) {
    glFlush();
    CVPixelBufferRef pb = g_PixelBuffer;
    CFRetain(pb);
    dispatch_async(dispatch_get_main_queue(), ^{
      g_HostView.layer.contents = (__bridge id)CVPixelBufferGetIOSurface(pb);
      /* GL renders bottom-up; flip the layer to display right-side up. */
      g_HostView.layer.transform = CATransform3DMakeScale(1.0, -1.0, 1.0);
      CFRelease(pb);
    });
    return;
  }

  size_t rowBytes = (size_t)w * 4;
  size_t dataSize = rowBytes * h;

  if (g_bUsePBO) {
    /*
     * Double-buffered PBO readback: initiate async read into PBO[index],
     * then map PBO[1-index] (which was started last frame) and display it.
     * This pipelines the GPU readback with CPU image creation.
     */
    int readIdx = g_PBOIndex;
    int mapIdx = 1 - g_PBOIndex;
    g_PBOIndex = mapIdx;

    /* Start async readback of current frame into readIdx */
    glBindBuffer(GL_PIXEL_PACK_BUFFER, g_PBO[readIdx]);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, 0);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);

    if (g_bFirstFrame) {
      g_bFirstFrame = false;
      return;
    }

    /* Map the previous frame's PBO */
    glBindBuffer(GL_PIXEL_PACK_BUFFER, g_PBO[mapIdx]);
    void* mapped = glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, dataSize, GL_MAP_READ_BIT);
    if (!mapped) {
      glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
      return;
    }

    uint8_t* pixels = (uint8_t*)malloc(dataSize);
    const uint8_t* src = (const uint8_t*)mapped;
    for (int y = 0; y < h; y++) {
      memcpy(pixels + y * rowBytes, src + (h - 1 - y) * rowBytes, rowBytes);
    }
    glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider =
        CGDataProviderCreateWithData(pixels, pixels, dataSize, FreeDataProviderCallback);
    CGImageRef img = CGImageCreate(
        w, h, 8, 32, rowBytes, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big,
        provider, NULL, false, kCGRenderingIntentDefault);
    UIImage* uiImage = [UIImage imageWithCGImage:img];
    CGImageRelease(img);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);

    dispatch_async(dispatch_get_main_queue(), ^{
      g_HostView.image = uiImage;
    });
  } else {
    /*
     * Synchronous readback fallback.
     *
     * Perf audit #5a: this whole file compiles tvOS-only, so anything here
     * runs every frame on a tile-based A-series GPU. An unconditional
     * glFinish() drains the entire command queue and serializes CPU/GPU,
     * defeating the pipeline overlap a TBDR architecture depends on. We only
     * need the rendered pixels to be available for the glReadPixels() below,
     * for which glFlush() (kick the queue, don't block) is sufficient — the
     * readback itself implies the necessary completion. Desktop/other-platform
     * present paths (RageDisplay_OGL.cpp's glFinish) are untouched; that file
     * is not part of the tvOS build (see CMakeData-rage.cmake: TVOS compiles
     * RageDisplay_GLES2.cpp only).
     */
    glFlush();

    uint8_t* raw = (uint8_t*)malloc(dataSize);
    if (!raw) {
      return;
    }

    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, raw);

    uint8_t* pixels = (uint8_t*)malloc(dataSize);
    for (int y = 0; y < h; y++) {
      memcpy(pixels + y * rowBytes, raw + (h - 1 - y) * rowBytes, rowBytes);
    }
    free(raw);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider =
        CGDataProviderCreateWithData(pixels, pixels, dataSize, FreeDataProviderCallback);
    CGImageRef img = CGImageCreate(
        w, h, 8, 32, rowBytes, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big,
        provider, NULL, false, kCGRenderingIntentDefault);
    UIImage* uiImage = [UIImage imageWithCGImage:img];
    CGImageRelease(img);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);

    dispatch_async(dispatch_get_main_queue(), ^{
      g_HostView.image = uiImage;
    });
  }
}

void LowLevelWindow_tvOS::Update() {}

RenderTarget* LowLevelWindow_tvOS::CreateRenderTarget() { return nullptr; }
