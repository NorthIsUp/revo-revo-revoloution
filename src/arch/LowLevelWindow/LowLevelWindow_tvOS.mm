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

#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

/* This file is compiled without ARC (see CMakeData-arch.cmake, which only opts
 * WebServerKit and UploadServer into -fobjc-arc), so the +1 from each alloc is
 * deliberately never released: the context and the view live as long as the
 * process does. */

/* Backing this view with a CAEAGLLayer makes the layer itself the GL drawable,
 * so a frame is presented by swapping the renderbuffer CoreAnimation already
 * owns. The previous implementation rendered to an offscreen FBO and pushed
 * pixels into a UIImageView every frame, which cost either a full-frame
 * glReadPixels + malloc + CPU row-flip + CGImage build, or an unfenced handoff
 * of the same live IOSurface the GPU was still drawing into. Neither was
 * synchronized to the panel; presentRenderbuffer: is. */
@interface SMGLView : UIView
@end

@implementation SMGLView
+ (Class)layerClass { return [CAEAGLLayer class]; }
@end

static EAGLContext* g_EAGLContext = nil;
static SMGLView* g_HostView = nil;
static GLuint g_Framebuffer = 0;
static GLuint g_ColorRenderbuffer = 0;
static GLuint g_DepthRenderbuffer = 0;
static GLint g_BackingWidth = 0;
static GLint g_BackingHeight = 0;
static bool g_bES3 = false;

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
  if (g_ColorRenderbuffer) {
    glDeleteRenderbuffers(1, &g_ColorRenderbuffer);
    g_ColorRenderbuffer = 0;
  }
  if (g_DepthRenderbuffer) {
    glDeleteRenderbuffers(1, &g_DepthRenderbuffer);
    g_DepthRenderbuffer = 0;
  }
  [EAGLContext setCurrentContext:nil];
  g_EAGLContext = nil;
  g_HostView = nil;
}

void* LowLevelWindow_tvOS::GetProcAddress(std::string s) { return nil; }

std::string LowLevelWindow_tvOS::TryVideoMode(const VideoModeParams& p, bool& newDeviceOut) {
  __block bool bCreated = false;
  __block std::string sError;

  newDeviceOut = false;

  /* Called from the game thread. Everything that touches the view or its layer
   * is done here, on the main thread, including allocating the drawable's
   * storage — renderbufferStorage:fromDrawable: reads layer geometry that
   * UIKit owns. The context is handed back to the game thread afterwards. */
  dispatch_sync(dispatch_get_main_queue(), ^{
    if (g_HostView) {
      return;
    }

    UIWindow* window = [UIApplication sharedApplication].keyWindow;
    if (!window) {
      sError = "no key window";
      return;
    }

    g_HostView = [[SMGLView alloc] initWithFrame:window.bounds];
    g_HostView.backgroundColor = [UIColor blackColor];
    g_HostView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    g_HostView.opaque = YES;
#if TARGET_OS_SIMULATOR
    /* The simulator rasterizes GLES in software, so render at half resolution
     * and let the compositor scale it back up. */
    g_HostView.contentScaleFactor = 0.5f;
#endif
    [window.rootViewController.view addSubview:g_HostView];

    CAEAGLLayer* layer = (CAEAGLLayer*)g_HostView.layer;
    layer.opaque = YES;
    layer.drawableProperties = @{
      kEAGLDrawablePropertyRetainedBacking : @NO,
      kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8,
    };

    g_EAGLContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    g_bES3 = (g_EAGLContext != nil);
    if (!g_EAGLContext) {
      g_EAGLContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    }
    if (!g_EAGLContext) {
      sError = "could not create an OpenGL ES context";
      return;
    }

    [EAGLContext setCurrentContext:g_EAGLContext];

    glGenFramebuffers(1, &g_Framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, g_Framebuffer);

    glGenRenderbuffers(1, &g_ColorRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, g_ColorRenderbuffer);
    if (![g_EAGLContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:layer]) {
      sError = "renderbufferStorage:fromDrawable: failed";
      [EAGLContext setCurrentContext:nil];
      return;
    }
    glFramebufferRenderbuffer(
        GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, g_ColorRenderbuffer);

    /* The drawable's size comes from the layer, not from the mode request. */
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &g_BackingWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &g_BackingHeight);

    glGenRenderbuffers(1, &g_DepthRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, g_DepthRenderbuffer);
    glRenderbufferStorage(
        GL_RENDERBUFFER, GL_DEPTH_COMPONENT24_OES, g_BackingWidth, g_BackingHeight);
    glFramebufferRenderbuffer(
        GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, g_DepthRenderbuffer);

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
      sError = ssprintf("incomplete framebuffer (0x%x)", status);
      [EAGLContext setCurrentContext:nil];
      return;
    }

    /* A context is current on at most one thread; release it here so the game
     * thread can claim it below. */
    [EAGLContext setCurrentContext:nil];
    bCreated = true;
  });

  if (!sError.empty()) {
    return sError;
  }

  [EAGLContext setCurrentContext:g_EAGLContext];
  glBindFramebuffer(GL_FRAMEBUFFER, g_Framebuffer);

  if (bCreated) {
    LOG->Info(
        "CAEAGLLayer drawable created: %dx%d (OpenGL ES %d)", g_BackingWidth, g_BackingHeight,
        g_bES3 ? 3 : 2);
  }

  newDeviceOut = bCreated;

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
  if (!g_EAGLContext) {
    return;
  }

  /* Nothing samples depth once the frame is done, so let the tiler drop it
   * instead of writing it back to memory. */
  if (g_bES3) {
    const GLenum aDiscard[] = {GL_DEPTH_ATTACHMENT};
    glInvalidateFramebuffer(GL_FRAMEBUFFER, 1, aDiscard);
  }

  glBindRenderbuffer(GL_RENDERBUFFER, g_ColorRenderbuffer);
  [g_EAGLContext presentRenderbuffer:GL_RENDERBUFFER];

  glBindFramebuffer(GL_FRAMEBUFFER, g_Framebuffer);
}

void LowLevelWindow_tvOS::Update() {}

RenderTarget* LowLevelWindow_tvOS::CreateRenderTarget() { return nullptr; }
