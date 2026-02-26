#ifndef RAGE_DISPLAY_OGL_HELPERS_H
#define RAGE_DISPLAY_OGL_HELPERS_H

/* Import RageDisplay, for types.  Do not include RageDisplay_Legacy.h. */
#include <cstdint>
#include <string>

#include "RageDisplay.h"

#if defined(_WIN32)
#include <windows.h>
#endif

#if defined(TVOS)
#include <OpenGLES/ES2/gl.h>
#include <OpenGLES/ES2/glext.h>

/* Compatibility defines for desktop GL constants not in OpenGL ES 2.0 */
#ifndef GL_RGBA8
#define GL_RGBA8 GL_RGBA
#endif
#ifndef GL_RGB8
#define GL_RGB8 GL_RGB
#endif
#ifndef GL_RGB5
#define GL_RGB5 GL_RGB565
#endif
#ifndef GL_BGR
#define GL_BGR GL_RGB
#endif
#ifndef GL_BGRA
#define GL_BGRA GL_BGRA_EXT
#endif
#ifndef GL_COLOR_INDEX8_EXT
#define GL_COLOR_INDEX8_EXT 0x80E5
#endif
#ifndef GL_COLOR_INDEX
#define GL_COLOR_INDEX 0x1900
#endif
#ifndef GL_UNSIGNED_SHORT_1_5_5_5_REV
#define GL_UNSIGNED_SHORT_1_5_5_5_REV 0x8366
#endif
#ifndef GL_TEXTURE_WIDTH
#define GL_TEXTURE_WIDTH 0x1000
#endif
#ifndef GL_ALPHA_TEST
#define GL_ALPHA_TEST 0x0BC0
#endif
#ifndef GL_FILL
#define GL_FILL 0x1B02
#endif
#ifndef GL_LINE
#define GL_LINE 0x1B01
#endif
#ifndef GL_CLAMP
#define GL_CLAMP GL_CLAMP_TO_EDGE
#endif
#ifndef GL_MAX_TEXTURE_UNITS_ARB
#define GL_MAX_TEXTURE_UNITS_ARB GL_MAX_TEXTURE_IMAGE_UNITS
#endif

/* Stub out desktop GL functions not available in ES 2.0 */
#define glPolygonMode(face, mode) ((void)0)
#define glDepthRange glDepthRangef

#else
#include <GL/glew.h>
#endif

/* Windows defines GL_EXT_paletted_texture incompletely: */
#ifndef GL_TEXTURE_INDEX_SIZE_EXT
#define GL_TEXTURE_INDEX_SIZE_EXT 0x80ED
#endif

/** @brief Utilities for working with the RageDisplay. */
namespace RageDisplay_Legacy_Helpers {
void Init();
std::string GLToString(GLenum e);
};  // namespace RageDisplay_Legacy_Helpers

class RenderTarget {
 public:
  virtual ~RenderTarget() {}
  virtual void Create(
      const RenderTargetParam& param, int& iTextureWidthOut,
      int& iTextureHeightOut) = 0;

  virtual uintptr_t GetTexture() const = 0;

  /* Render to this RenderTarget. */
  virtual void StartRenderingTo() = 0;

  /* Stop rendering to this RenderTarget.  Update the texture, if necessary, and
   * make it available. */
  virtual void FinishRenderingTo() = 0;

  virtual bool InvertY() const { return false; }

  const RenderTargetParam& GetParam() const { return m_Param; }

 protected:
  RenderTargetParam m_Param;
};

#endif

/*
 * Copyright (c) 2001-2011 Chris Danford, Glenn Maynard, Colby Klein
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, and/or sell copies of the Software, and to permit persons to
 * whom the Software is furnished to do so, provided that the above
 * copyright notice(s) and this permission notice appear in all copies of
 * the Software and that both the above copyright notice(s) and this
 * permission notice appear in supporting documentation.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
 * THIRD PARTY RIGHTS. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS
 * INCLUDED IN THIS NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT
 * OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
 * OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
 * OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
 * PERFORMANCE OF THIS SOFTWARE.
 */
