#ifndef LOW_LEVEL_WINDOW_TVOS_H
#define LOW_LEVEL_WINDOW_TVOS_H

#include <objc/objc.h>

#include <cstdint>

#include "LowLevelWindow.h"
#include "RageDisplay.h"

class LowLevelWindow_tvOS : public LowLevelWindow {
  VideoModeParams m_CurrentParams;
  id m_EAGLContext;
  id m_GLView;

 public:
  LowLevelWindow_tvOS();
  ~LowLevelWindow_tvOS();
  void* GetProcAddress(std::string s);
  std::string TryVideoMode(const VideoModeParams& p, bool& newDeviceOut);
  void GetDisplaySpecs(DisplaySpecs& specs) const;

  void SwapBuffers();
  void Update();

  void BeginConcurrentRendering();

  const ActualVideoModeParams GetActualVideoModeParams() const {
    return m_CurrentParams;
  }

  bool SupportsRenderToTexture() const { return true; }
  RenderTarget* CreateRenderTarget();
};

#ifdef ARCH_LOW_LEVEL_WINDOW
#error "More than one LowLevelWindow selected!"
#endif
#define ARCH_LOW_LEVEL_WINDOW LowLevelWindow_tvOS

#endif
