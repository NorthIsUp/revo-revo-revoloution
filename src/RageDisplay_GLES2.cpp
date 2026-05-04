#include "RageDisplay_GLES2.h"

#include <cstddef>
#include <cstdint>
#include <vector>

#include "DisplaySpec.h"
#include "RageDisplay.h"
#include "RageDisplay_OGL_Helpers.h"
#include "RageLog.h"
#include "RageMath.h"
#include "RageSurface.h"
#include "RageTextureManager.h"
#include "RageTimer.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "arch/LowLevelWindow/LowLevelWindow.h"
#include "global.h"

#ifdef NO_GL_FLUSH
#define glFlush()
#endif

static GLuint g_ShaderProgram = 0;
static GLint g_UniformMVP = -1;
static GLint g_UniformTexMatrix = -1;
static GLint g_UniformTexture = -1;
static GLint g_UniformUseTexture = -1;
static GLint g_UniformMaterialDiffuse = -1;
static GLint g_UniformUseMaterial = -1;
static GLint g_AttribPosition = -1;
static GLint g_AttribColor = -1;
static GLint g_AttribTexCoord = -1;
static bool g_bTextureEnabled = false;
static RageColor g_MaterialDiffuse(1, 1, 1, 1);

static const char* g_VertexShader =
    "attribute vec3 aPosition;\n"
    "attribute vec4 aColor;\n"
    "attribute vec2 aTexCoord;\n"
    "uniform mat4 uMVP;\n"
    "uniform mat4 uTexMatrix;\n"
    "varying vec4 vColor;\n"
    "varying vec2 vTexCoord;\n"
    "void main() {\n"
    "    gl_Position = uMVP * vec4(aPosition, 1.0);\n"
    "    vColor = aColor.zyxw;\n" /* BGRA -> RGBA swizzle */
    "    vTexCoord = (uTexMatrix * vec4(aTexCoord, 0.0, 1.0)).xy;\n"
    "}\n";

static const char* g_FragmentShader =
    "precision mediump float;\n"
    "varying vec4 vColor;\n"
    "varying vec2 vTexCoord;\n"
    "uniform sampler2D uTexture;\n"
    "uniform int uUseTexture;\n"
    "uniform int uUseMaterial;\n"
    "uniform vec4 uMaterialDiffuse;\n"
    "void main() {\n"
    "    vec4 baseColor = (uUseMaterial != 0) ? uMaterialDiffuse : vColor;\n"
    "    if (uUseTexture != 0) {\n"
    "        gl_FragColor = baseColor * texture2D(uTexture, vTexCoord);\n"
    "    } else {\n"
    "        gl_FragColor = baseColor;\n"
    "    }\n"
    "}\n";

static GLuint CompileShader(GLenum type, const char* src) {
  GLuint s = glCreateShader(type);
  glShaderSource(s, 1, &src, NULL);
  glCompileShader(s);
  GLint ok = 0;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char buf[512];
    glGetShaderInfoLog(s, sizeof(buf), NULL, buf);
    LOG->Warn("GLES2 shader compile error: %s", buf);
  }
  return s;
}

static void InitShaders() {
  if (g_ShaderProgram) {
    return;
  }

  GLuint vs = CompileShader(GL_VERTEX_SHADER, g_VertexShader);
  GLuint fs = CompileShader(GL_FRAGMENT_SHADER, g_FragmentShader);

  g_ShaderProgram = glCreateProgram();
  glAttachShader(g_ShaderProgram, vs);
  glAttachShader(g_ShaderProgram, fs);
  glLinkProgram(g_ShaderProgram);

  GLint ok = 0;
  glGetProgramiv(g_ShaderProgram, GL_LINK_STATUS, &ok);
  if (!ok) {
    char buf[512];
    glGetProgramInfoLog(g_ShaderProgram, sizeof(buf), NULL, buf);
    LOG->Warn("GLES2 program link error: %s", buf);
  }

  g_AttribPosition = glGetAttribLocation(g_ShaderProgram, "aPosition");
  g_AttribColor = glGetAttribLocation(g_ShaderProgram, "aColor");
  g_AttribTexCoord = glGetAttribLocation(g_ShaderProgram, "aTexCoord");
  g_UniformMVP = glGetUniformLocation(g_ShaderProgram, "uMVP");
  g_UniformTexMatrix = glGetUniformLocation(g_ShaderProgram, "uTexMatrix");
  g_UniformTexture = glGetUniformLocation(g_ShaderProgram, "uTexture");
  g_UniformUseTexture = glGetUniformLocation(g_ShaderProgram, "uUseTexture");
  g_UniformMaterialDiffuse =
      glGetUniformLocation(g_ShaderProgram, "uMaterialDiffuse");
  g_UniformUseMaterial = glGetUniformLocation(g_ShaderProgram, "uUseMaterial");

  glDeleteShader(vs);
  glDeleteShader(fs);

  LOG->Info(
      "GLES2 shaders initialized: prog=%u pos=%d col=%d tex=%d",
      g_ShaderProgram, g_AttribPosition, g_AttribColor, g_AttribTexCoord);
}

namespace {
RageDisplay::RagePixelFormatDesc PIXEL_FORMAT_DESC[NUM_RagePixelFormat] = {
    {/* R8G8B8A8 */
     32,
     {0xFF000000, 0x00FF0000, 0x0000FF00, 0x000000FF}},
    {/* B8G8R8A8 */
     32,
     {0x0000FF00, 0x00FF0000, 0xFF000000, 0x000000FF}},
    {
        /* R4G4B4A4 */
        16,
        {0xF000, 0x0F00, 0x00F0, 0x000F},
    },
    {
        /* R5G5B5A1 */
        16,
        {0xF800, 0x07C0, 0x003E, 0x0001},
    },
    {
        /* R5G5B5X1 */
        16,
        {0xF800, 0x07C0, 0x003E, 0x0000},
    },
    {/* R8G8B8 */
     24,
     {0xFF0000, 0x00FF00, 0x0000FF, 0x000000}},
    {
        /* Paletted */
        8,
        {0, 0, 0, 0} /* N/A */
    },
    {/* B8G8R8 */
     24,
     {0x0000FF, 0x00FF00, 0xFF0000, 0x000000}},
    {
        /* A1R5G5B5 */
        16,
        {0x7C00, 0x03E0, 0x001F, 0x8000},
    },
    {
        /* X1R5G5B5 */
        16,
        {0x7C00, 0x03E0, 0x001F, 0x0000},
    }};

/* g_GLPixFmtInfo is used for both texture formats and surface formats.
 * For example, it's fine to ask for a RagePixelFormat_RGB5 texture, but to
 * supply a surface matching RagePixelFormat_RGB8.  OpenGL will simply
 * discard the extra bits.
 *
 * It's possible for a format to be supported as a texture format but
 * not as a surface format.  For example, if packed pixels aren't
 * supported, we can still use GL_RGB5_A1, but we'll have to convert to
 * a supported surface pixel format first.  It's not ideal, since we'll
 * convert to RGBA8 and OGL will convert back, but it works fine.
 */
struct GLPixFmtInfo_t {
  GLenum internalfmt; /* target format */
  GLenum format;      /* target format */
  GLenum type;        /* data format */
} const g_GLPixFmtInfo[NUM_RagePixelFormat] = {
    {
        /* R8G8B8A8 */
        GL_RGBA8,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
    },
    {
        /* R8G8B8A8 */
        GL_RGBA8,
        GL_BGRA,
        GL_UNSIGNED_BYTE,
    },
    {
        /* B4G4R4A4 */
        GL_RGBA4,
        GL_RGBA,
        GL_UNSIGNED_SHORT_4_4_4_4,
    },
    {
        /* B5G5R5A1 */
        GL_RGB5_A1,
        GL_RGBA,
        GL_UNSIGNED_SHORT_5_5_5_1,
    },
    {
        /* B5G5R5 */
        GL_RGB5,
        GL_RGBA,
        GL_UNSIGNED_SHORT_5_5_5_1,
    },
    {
        /* B8G8R8 */
        GL_RGB8,
        GL_RGB,
        GL_UNSIGNED_BYTE,
    },
    {
        /* Paletted */
        GL_COLOR_INDEX8_EXT,
        GL_COLOR_INDEX,
        GL_UNSIGNED_BYTE,
    },
    {
        /* B8G8R8 */
        GL_RGB8,
        GL_BGR,
        GL_UNSIGNED_BYTE,
    },
    {
        // TODO: These don't work on ES2. Work out what needs to happen.
        /* A1R5G5B5 (matches D3DFMT_A1R5G5B5) */
        GL_RGB5_A1,
        GL_BGRA,
        GL_UNSIGNED_SHORT_1_5_5_5_REV,
    },
    {
        /* X1R5G5B5 */
        GL_RGB5,
        GL_BGRA,
        GL_UNSIGNED_SHORT_1_5_5_5_REV,
    }};

LowLevelWindow* g_pWind;

void FixLittleEndian() {
  if constexpr (!Endian::little) {
    return;
  }

  static bool bInitialized = false;
  if (bInitialized) {
    return;
  }
  bInitialized = true;

  for (int i = 0; i < NUM_RagePixelFormat; ++i) {
    RageDisplay::RagePixelFormatDesc& pf = PIXEL_FORMAT_DESC[i];

    /* OpenGL and RageSurface handle byte formats differently; we need
     * to flip non-paletted masks to make them line up. */
    if (g_GLPixFmtInfo[i].type != GL_UNSIGNED_BYTE || pf.bpp == 8) {
      continue;
    }

    for (int mask = 0; mask < 4; ++mask) {
      int m = pf.masks[mask];
      switch (pf.bpp) {
        case 24:
          m = Swap24(m);
          break;
        case 32:
          m = Swap32(m);
          break;
        default:
          FAIL_M(ssprintf("Unsupported BPP value: %i", pf.bpp));
      }
      pf.masks[mask] = m;
    }
  }
}
namespace Caps {
int iMaxTextureUnits = 1;
int iMaxTextureSize = 256;
}  // namespace Caps
namespace State {
bool bZTestEnabled = false;
bool bZWriteEnabled = false;
bool bAlphaTestEnabled = false;
}  // namespace State
}  // namespace

RageDisplay_GLES2::RageDisplay_GLES2() {
  LOG->Trace("RageDisplay_GLES2::RageDisplay_GLES2()");
  LOG->MapLog("renderer", "Current renderer: OpenGL ES 2.0");

  FixLittleEndian();
  //	RageDisplay_GLES2_Helpers::Init();

  g_pWind = nullptr;
}

std::string RageDisplay_GLES2::Init(
    const VideoModeParams& p, bool bAllowUnacceleratedRenderer) {
  g_pWind = LowLevelWindow::Create();

  bool bIgnore = false;
  std::string sError = SetVideoMode(p, bIgnore);
  if (sError != "") {
    return sError;
  }

  // Get GPU capabilities up front so we don't have to query later.
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, &Caps::iMaxTextureSize);
  glGetIntegerv(GL_MAX_TEXTURE_IMAGE_UNITS, &Caps::iMaxTextureUnits);

  // Log driver details
  g_pWind->LogDebugInformation();
  LOG->Info("OGL Vendor: %s", glGetString(GL_VENDOR));
  LOG->Info("OGL Renderer: %s", glGetString(GL_RENDERER));
  LOG->Info("OGL Version: %s", glGetString(GL_VERSION));
  LOG->Info("OGL Max texture size: %i", Caps::iMaxTextureSize);
  LOG->Info("OGL Texture units: %i", Caps::iMaxTextureUnits);

  /* Pretty-print the extension string: */
  LOG->Info("OGL Extensions:");
  {
    // glGetString(GL_EXTENSIONS) doesn't work for GL3 core profiles.
    // this will be useful in the future.
#if 0
		std::vector<string> extensions;
		const char *ext = 0;
		for (int i = 0; (ext = (const char*)glGetStringi(GL_EXTENSIONS, i)); i++)
		{
			extensions.push_back(string(ext));
		}

		sort( extensions.begin(), extensions.end() );
		size_t next = 0;
		while( next < extensions.size() )
		{
			size_t last = next;
			string type;
			for( size_t i = next; i<extensions.size(); ++i )
			{
				std::vector<string> segments;
				split(extensions[i], '_', segments);
				string this_type;
				if (segments.size() > 2)
					this_type = join("_", segments.begin(), segments.begin()+2);
				if (i > next && this_type != type)
					break;
				type = this_type;
				last = i;
			}

			if (next == last)
			{
				printf( "  %s\n", extensions[next].c_str() );
				++next;
				continue;
			}

			string sList = ssprintf( "  %s: ", type.c_str() );
			while( next <= last )
			{
				std::vector<string> segments;
				split( extensions[next], '_', segments );
				string ext_short = join( "_", segments.begin()+2, segments.end() );
				sList += ext_short;
				if (next < last)
					sList += ", ";
				if (next == last || sList.size() + extensions[next+1].size() > 78)
				{
					printf( "%s\n", sList.c_str() );
					sList = "    ";
				}
				++next;
			}
		}
#else
    const char* szExtensionString = (const char*)glGetString(GL_EXTENSIONS);
    std::vector<std::string> asExtensions;
    split(szExtensionString, " ", asExtensions);
    sort(asExtensions.begin(), asExtensions.end());
    size_t iNextToPrint = 0;
    while (iNextToPrint < asExtensions.size()) {
      size_t iLastToPrint = iNextToPrint;
      std::string sType;
      for (size_t i = iNextToPrint; i < asExtensions.size(); ++i) {
        std::vector<std::string> asBits;
        split(asExtensions[i], "_", asBits);
        std::string sThisType;
        if (asBits.size() > 2) {
          sThisType = join("_", asBits.begin(), asBits.begin() + 2);
        }
        if (i > iNextToPrint && sThisType != sType) {
          break;
        }
        sType = sThisType;
        iLastToPrint = i;
      }

      if (iNextToPrint == iLastToPrint) {
        LOG->Info("  %s", asExtensions[iNextToPrint].c_str());
        ++iNextToPrint;
        continue;
      }

      std::string sList = ssprintf("  %s: ", sType.c_str());
      while (iNextToPrint <= iLastToPrint) {
        std::vector<std::string> asBits;
        split(asExtensions[iNextToPrint], "_", asBits);
        std::string sShortExt = join("_", asBits.begin() + 2, asBits.end());
        sList += sShortExt;
        if (iNextToPrint < iLastToPrint) {
          sList += ", ";
        }
        if (iNextToPrint == iLastToPrint ||
            sList.size() + asExtensions[iNextToPrint + 1].size() > 120) {
          LOG->Info("%s", sList.c_str());
          sList = "    ";
        }
        ++iNextToPrint;
      }
#endif
    }
  }

#if !defined(TVOS)
  glewExperimental = true;
  glewInit();
#endif

  /* Log this, so if people complain that the radar looks bad on their
   * system we can compare them: */
  // glGetFloatv( GL_LINE_WIDTH_RANGE, g_line_range );
  // glGetFloatv( GL_POINT_SIZE_RANGE, g_point_range );

  return std::string();
}

// Return true if mode change was successful.
// bNewDeviceOut is set true if a new device was created and textures
// need to be reloaded.
std::string RageDisplay_GLES2::TryVideoMode(
    const VideoModeParams& p, bool& bNewDeviceOut) {
  VideoModeParams vm = p;
  vm.windowed = 1;  // force windowed until I trust this thing.
  LOG->Warn(
      "RageDisplay_GLES2::TryVideoMode( %d, %d, %d, %d, %d, %d )", vm.windowed,
      vm.width, vm.height, vm.bpp, vm.rate, vm.vsync);

  std::string err = g_pWind->TryVideoMode(vm, bNewDeviceOut);
  if (err != "") {
    return err;  // failed to set video mode
  }

  if (bNewDeviceOut) {
#if !defined(TVOS)
    glewInit();
#endif

    /* We have a new OpenGL context, so we have to tell our textures that
     * their OpenGL texture number is invalid. */
    if (TEXTUREMAN) {
      TEXTUREMAN->InvalidateTextures();
    }

    /* Delete all render targets.  They may have associated resources other than
     * the texture itself. */
    // FOREACHM( unsigned, RenderTarget *, g_mapRenderTargets, rt )
    //	delete rt->second;
    // g_mapRenderTargets.clear();

    /* Recreate all vertex buffers. */
    // InvalidateObjects();

    InitShaders();
  }

  ResolutionChanged();

  return std::string();
}

int RageDisplay_GLES2::GetMaxTextureSize() const {
  return Caps::iMaxTextureSize;
}

bool RageDisplay_GLES2::BeginFrame() {
  /* We do this in here, rather than ResolutionChanged, or we won't update the
   * viewport for the concurrent rendering context. */
  int fWidth = g_pWind->GetActualVideoModeParams().width;
  int fHeight = g_pWind->GetActualVideoModeParams().height;

  glViewport(0, 0, fWidth, fHeight);

  glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
  SetZWrite(true);
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

  return RageDisplay::BeginFrame();
}

void RageDisplay_GLES2::EndFrame() {
  glFlush();

  // XXX: This is broken on NVidia, as their xrandr sucks.
  FrameLimitBeforeVsync(g_pWind->GetActualVideoModeParams().rate);
  g_pWind->SwapBuffers();
  FrameLimitAfterVsync();

  g_pWind->Update();

  RageDisplay::EndFrame();
}

void RageDisplay_GLES2::BeginConcurrentRendering() {
  g_pWind->BeginConcurrentRendering();
  RageDisplay::BeginConcurrentRendering();
}

RageDisplay_GLES2::~RageDisplay_GLES2() { delete g_pWind; }

void RageDisplay_GLES2::GetDisplaySpecs(DisplaySpecs& out) const {
  out.clear();
  g_pWind->GetDisplaySpecs(out);
}

RageSurface* RageDisplay_GLES2::CreateScreenshot() {
  const RagePixelFormatDesc& desc = PIXEL_FORMAT_DESC[RagePixelFormat_RGB8];
  RageSurface* image = CreateSurface(
      640, 480, desc.bpp, desc.masks[0], desc.masks[1], desc.masks[2],
      desc.masks[3]);

  memset(image->pixels, 0, 480 * image->pitch);

  return image;
}

const RageDisplay::RagePixelFormatDesc* RageDisplay_GLES2::GetPixelFormatDesc(
    RagePixelFormat pf) const {
  ASSERT(pf >= 0 && pf < NUM_RagePixelFormat);
  return &PIXEL_FORMAT_DESC[pf];
}

RageMatrix RageDisplay_GLES2::GetOrthoMatrix(
    float l, float r, float b, float t, float zn, float zf) {
  RageMatrix m(
      2 / (r - l), 0, 0, 0, 0, 2 / (t - b), 0, 0, 0, 0, -2 / (zf - zn), 0,
      -(r + l) / (r - l), -(t + b) / (t - b), -(zf + zn) / (zf - zn), 1);
  return m;
}

class RageCompiledGeometryGLES2 : public RageCompiledGeometry {
 public:
  void Allocate(const std::vector<msMesh>& vMeshes) {
    const unsigned int verticesCount =
        std::max<unsigned int>(1u, GetTotalVertices());
    const unsigned int trianglesCount =
        std::max<unsigned int>(1u, GetTotalTriangles());

    m_vPosition.resize(verticesCount);
    m_vTexture.resize(verticesCount);
    m_vNormal.resize(verticesCount);
    m_vTexMatrixScale.resize(verticesCount);
    m_vTriangles.resize(trianglesCount);
  }
  void Change(const std::vector<msMesh>& vMeshes) {
    for (unsigned i = 0; i < vMeshes.size(); i++) {
      const MeshInfo& meshInfo = m_vMeshInfo[i];
      const msMesh& mesh = vMeshes[i];
      const std::vector<RageModelVertex>& Vertices = mesh.Vertices;
      const std::vector<msTriangle>& Triangles = mesh.Triangles;

      for (unsigned j = 0; j < Vertices.size(); j++) {
        m_vPosition[meshInfo.iVertexStart + j] = Vertices[j].p;
        m_vTexture[meshInfo.iVertexStart + j] = Vertices[j].t;
        m_vNormal[meshInfo.iVertexStart + j] = Vertices[j].n;
        m_vTexMatrixScale[meshInfo.iVertexStart + j] =
            Vertices[j].TextureMatrixScale;
      }

      for (unsigned j = 0; j < Triangles.size(); j++) {
        for (unsigned k = 0; k < 3; k++) {
          int iVertexIndexInVBO =
              meshInfo.iVertexStart + Triangles[j].nVertexIndices[k];
          m_vTriangles[meshInfo.iTriangleStart + j].nVertexIndices[k] =
              (uint16_t)iVertexIndexInVBO;
        }
      }
    }
  }
  void Draw(int iMeshIndex) const {
    const MeshInfo& meshInfo = m_vMeshInfo[iMeshIndex];

    glEnableVertexAttribArray(g_AttribPosition);
    glVertexAttribPointer(
        g_AttribPosition, 3, GL_FLOAT, GL_FALSE, 0, &m_vPosition[0]);

    glEnableVertexAttribArray(g_AttribTexCoord);
    glVertexAttribPointer(
        g_AttribTexCoord, 2, GL_FLOAT, GL_FALSE, 0, &m_vTexture[0]);

    if (g_AttribColor >= 0) {
      glDisableVertexAttribArray(g_AttribColor);
    }

    glDrawElements(
        GL_TRIANGLES, meshInfo.iTriangleCount * 3, GL_UNSIGNED_SHORT,
        &m_vTriangles[0] + meshInfo.iTriangleStart);

    glDisableVertexAttribArray(g_AttribPosition);
    glDisableVertexAttribArray(g_AttribTexCoord);
  }

  bool NeedsTextureMatrixScale(int iMeshIndex) const {
    return m_vMeshInfo[iMeshIndex].m_bNeedsTextureMatrixScale;
  }

 protected:
  std::vector<RageVector3> m_vPosition;
  std::vector<RageVector2> m_vTexture;
  std::vector<RageVector3> m_vNormal;
  std::vector<msTriangle> m_vTriangles;
  std::vector<RageVector2> m_vTexMatrixScale;
};

RageCompiledGeometry* RageDisplay_GLES2::CreateCompiledGeometry() {
  return new RageCompiledGeometryGLES2;
}

void RageDisplay_GLES2::DeleteCompiledGeometry(RageCompiledGeometry* p) {
  delete p;
}

std::string RageDisplay_GLES2::GetApiDescription() const {
  return "OpenGL ES 2.0";
}

ActualVideoModeParams RageDisplay_GLES2::GetActualVideoModeParams() const {
  return g_pWind->GetActualVideoModeParams();
}

void RageDisplay_GLES2::SetBlendMode(BlendMode mode) {
  glEnable(GL_BLEND);

  GLenum iSourceRGB, iDestRGB;
  GLenum iSourceAlpha = GL_ONE, iDestAlpha = GL_ONE_MINUS_SRC_ALPHA;
  switch (mode) {
    case BLEND_NORMAL:
      iSourceRGB = GL_SRC_ALPHA;
      iDestRGB = GL_ONE_MINUS_SRC_ALPHA;
      break;
    case BLEND_ADD:
      iSourceRGB = GL_SRC_ALPHA;
      iDestRGB = GL_ONE;
      break;
    case BLEND_COPY_SRC:
      iSourceRGB = GL_ONE;
      iDestRGB = GL_ZERO;
      iSourceAlpha = GL_ONE;
      iDestAlpha = GL_ZERO;
      break;
    case BLEND_NO_EFFECT:
      iSourceRGB = GL_ZERO;
      iDestRGB = GL_ONE;
      iSourceAlpha = GL_ZERO;
      iDestAlpha = GL_ONE;
      break;
    default:
      iSourceRGB = GL_SRC_ALPHA;
      iDestRGB = GL_ONE_MINUS_SRC_ALPHA;
      break;
  }
  glBlendFuncSeparate(iSourceRGB, iDestRGB, iSourceAlpha, iDestAlpha);
}

bool RageDisplay_GLES2::SupportsTextureFormat(
    RagePixelFormat pixfmt, bool realtime) {
  /* If we support a pixfmt for texture formats but not for surface formats,
   * then we'll have to convert the texture to a supported surface format before
   * uploading. This is too slow for dynamic textures. */
  if (realtime && !SupportsSurfaceFormat(pixfmt)) {
    return false;
  }

  switch (g_GLPixFmtInfo[pixfmt].format) {
    case GL_COLOR_INDEX:
      return false;
    case GL_BGR:
    case GL_BGRA:
      // return !!GLEW_EXT_bgra;
      return false;  // no BGRA on ES2 (without exts)
    default:
      return true;
  }

  return true;
}

bool RageDisplay_GLES2::SupportsPerVertexMatrixScale() { return true; }

uintptr_t RageDisplay_GLES2::CreateTexture(
    RagePixelFormat pixfmt, RageSurface* img, bool bGenerateMipMaps) {
  GLuint iTexHandle;
  glGenTextures(1, &iTexHandle);
  glBindTexture(GL_TEXTURE_2D, iTexHandle);

  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

  GLenum glFormat = GL_RGBA;
  GLenum glType = GL_UNSIGNED_BYTE;
  GLenum internalFormat = GL_RGBA;

  const RageDisplay::RagePixelFormatDesc& pf = PIXEL_FORMAT_DESC[pixfmt];
  if (pf.bpp == 32) {
    glFormat = GL_RGBA;
    internalFormat = GL_RGBA;
  } else if (pf.bpp == 24) {
    glFormat = GL_RGB;
    internalFormat = GL_RGB;
  } else if (pf.bpp == 16) {
    glFormat = GL_RGBA;
    glType = GL_UNSIGNED_SHORT_4_4_4_4;
    internalFormat = GL_RGBA;
  }

  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D(
      GL_TEXTURE_2D, 0, internalFormat, img->w, img->h, 0, glFormat, glType,
      img->pixels);

  if (bGenerateMipMaps) {
    glGenerateMipmap(GL_TEXTURE_2D);
  }

  return static_cast<uintptr_t>(iTexHandle);
}

void RageDisplay_GLES2::UpdateTexture(
    uintptr_t iTexHandle, RageSurface* img, int xoffset, int yoffset, int width,
    int height) {
  glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(iTexHandle));

  GLenum glFormat = GL_RGBA;
  GLenum glType = GL_UNSIGNED_BYTE;

  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexSubImage2D(
      GL_TEXTURE_2D, 0, xoffset, yoffset, width, height, glFormat, glType,
      img->pixels);
}

void RageDisplay_GLES2::DeleteTexture(uintptr_t iTexHandle) {
  if (iTexHandle == 0) {
    return;
  }
  GLuint id = static_cast<GLuint>(iTexHandle);
  glDeleteTextures(1, &id);
}

void RageDisplay_GLES2::ClearAllTextures() {
  FOREACH_ENUM(TextureUnit, i)
  SetTexture(i, 0);

  // HACK:  Reset the active texture to 0.
  // TODO:  Change all texture functions to take a stage number.
  glActiveTexture(GL_TEXTURE0);
}

int RageDisplay_GLES2::GetNumTextureUnits() { return Caps::iMaxTextureUnits; }

static bool SetTextureUnit(TextureUnit tu) {
  if ((int)tu > Caps::iMaxTextureUnits) {
    return false;
  }
  glActiveTexture(enum_add2(GL_TEXTURE0, tu));
  return true;
}

void RageDisplay_GLES2::SetTexture(TextureUnit tu, uintptr_t iTexture) {
  if (!SetTextureUnit(tu)) {
    return;
  }

  if (iTexture) {
    glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(iTexture));
    if (tu == TextureUnit_1) {
      g_bTextureEnabled = true;
    }
  } else {
    glBindTexture(GL_TEXTURE_2D, 0);
    if (tu == TextureUnit_1) {
      g_bTextureEnabled = false;
    }
  }
}

void RageDisplay_GLES2::SetTextureMode(TextureUnit tu, TextureMode tm) {
  // TODO
}

void RageDisplay_GLES2::SetTextureWrapping(TextureUnit tu, bool b) {
  // TODO
}

void RageDisplay_GLES2::SetTextureFiltering(TextureUnit tu, bool b) {
  glTexParameteri(
      GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, b ? GL_LINEAR : GL_NEAREST);

  GLint iMinFilter = 0;
  if (b) {
#if defined(TVOS)
    iMinFilter = GL_LINEAR;
#else
    GLint iWidth1 = -1;
    GLint iWidth2 = -1;
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &iWidth1);
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 1, GL_TEXTURE_WIDTH, &iWidth2);
    if (iWidth1 > 1 && iWidth2 != 0) {
      if (g_pWind->GetActualVideoModeParams().bTrilinearFiltering) {
        iMinFilter = GL_LINEAR_MIPMAP_LINEAR;
      } else {
        iMinFilter = GL_LINEAR_MIPMAP_NEAREST;
      }
    } else {
      iMinFilter = GL_LINEAR;
    }
#endif
  } else {
    iMinFilter = GL_NEAREST;
  }

  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, iMinFilter);
}

bool RageDisplay_GLES2::IsZWriteEnabled() const {
  return State::bZWriteEnabled;
}

bool RageDisplay_GLES2::IsZTestEnabled() const { return State::bZTestEnabled; }

void RageDisplay_GLES2::SetZWrite(bool b) {
  if (State::bZWriteEnabled != b) {
    State::bZWriteEnabled = b;
    glDepthMask(b);
  }
}

void RageDisplay_GLES2::SetZBias(float f) {
  float fNear = SCALE(f, 0.0f, 1.0f, 0.05f, 0.0f);
  float fFar = SCALE(f, 0.0f, 1.0f, 1.0f, 0.95f);

  glDepthRange(fNear, fFar);
}

void RageDisplay_GLES2::SetZTestMode(ZTestMode mode) {
  glEnable(GL_DEPTH_TEST);
  switch (mode) {
    case ZTEST_OFF:
      glDisable(GL_DEPTH_TEST);
      glDepthFunc(GL_ALWAYS);
      State::bZTestEnabled = false;
      break;
    case ZTEST_WRITE_ON_PASS:
      glDepthFunc(GL_LEQUAL);
      break;
    case ZTEST_WRITE_ON_FAIL:
      glDepthFunc(GL_GREATER);
      break;
    default:
      FAIL_M(ssprintf("Invalid ZTestMode: %i", mode));
  }
  State::bZTestEnabled = true;
}

/*


void RageDisplay_Legacy::SetBlendMode( BlendMode mode )
{
        glEnable(GL_BLEND);

        if (glBlendEquation != nullptr)
        {
                if (mode == BLEND_INVERT_DEST)
                        glBlendEquation( GL_FUNC_SUBTRACT );
                else if (mode == BLEND_SUBTRACT)
                        glBlendEquation( GL_FUNC_REVERSE_SUBTRACT );
                else
                        glBlendEquation( GL_FUNC_ADD );
        }

        int iSourceRGB, iDestRGB;
        int iSourceAlpha = GL_ONE, iDestAlpha = GL_ONE_MINUS_SRC_ALPHA;
        switch( mode )
        {
        case BLEND_NORMAL:
                iSourceRGB = GL_SRC_ALPHA; iDestRGB = GL_ONE_MINUS_SRC_ALPHA;
                break;
        case BLEND_ADD:
                iSourceRGB = GL_SRC_ALPHA; iDestRGB = GL_ONE;
                break;
        case BLEND_SUBTRACT:
                iSourceRGB = GL_SRC_ALPHA; iDestRGB = GL_ONE_MINUS_SRC_ALPHA;
                break;
        case BLEND_MODULATE:
                iSourceRGB = GL_ZERO; iDestRGB = GL_SRC_COLOR;
                break;
        case BLEND_COPY_SRC:
                iSourceRGB = GL_ONE; iDestRGB = GL_ZERO;
                iSourceAlpha = GL_ONE; iDestAlpha = GL_ZERO;
                break;
        case BLEND_ALPHA_MASK:
                iSourceRGB = GL_ZERO; iDestRGB = GL_ONE;
                iSourceAlpha = GL_ZERO; iDestAlpha = GL_SRC_ALPHA;
                break;
        case BLEND_ALPHA_KNOCK_OUT:
                iSourceRGB = GL_ZERO; iDestRGB = GL_ONE;
                iSourceAlpha = GL_ZERO; iDestAlpha = GL_ONE_MINUS_SRC_ALPHA;
                break;
        case BLEND_ALPHA_MULTIPLY:
                iSourceRGB = GL_SRC_ALPHA; iDestRGB = GL_ZERO;
                break;
        case BLEND_WEIGHTED_MULTIPLY:
                // output = 2*(dst*src).  0.5,0.5,0.5 is identity; darker colors
darken the image,
                // and brighter colors lighten the image.
                iSourceRGB = GL_DST_COLOR; iDestRGB = GL_SRC_COLOR;
                break;
        case BLEND_INVERT_DEST:
                // out = src - dst.  The source color should almost always be
#FFFFFF, to make it "1 - dst". iSourceRGB = GL_ONE; iDestRGB = GL_ONE; break;
        case BLEND_NO_EFFECT:
                iSourceRGB = GL_ZERO; iDestRGB = GL_ONE;
                iSourceAlpha = GL_ZERO; iDestAlpha = GL_ONE;
                break;
        DEFAULT_FAIL( mode );
        }

        if (GLEW_EXT_blend_equation_separate)
                glBlendFuncSeparateEXT( iSourceRGB, iDestRGB, iSourceAlpha,
iDestAlpha ); else glBlendFunc( iSourceRGB, iDestRGB );
}

bool RageDisplay_Legacy::IsZWriteEnabled() const
{
        bool a;
        glGetBooleanv( GL_DEPTH_WRITEMASK, (unsigned char*)&a );
        return a;
}


*/

void RageDisplay_GLES2::ClearZBuffer() {
  bool write = IsZWriteEnabled();
  SetZWrite(true);
  glClear(GL_DEPTH_BUFFER_BIT);
  SetZWrite(write);
}

void RageDisplay_GLES2::SetCullMode(CullMode mode) {
  if (mode != CULL_NONE) {
    glEnable(GL_CULL_FACE);
  }
  switch (mode) {
    case CULL_BACK:
      glCullFace(GL_BACK);
      break;
    case CULL_FRONT:
      glCullFace(GL_FRONT);
      break;
    case CULL_NONE:
      glDisable(GL_CULL_FACE);
      break;
    default:
      FAIL_M(ssprintf("Invalid CullMode: %i", mode));
  }
}

void RageDisplay_GLES2::SetAlphaTest(bool b) {
  if (State::bAlphaTestEnabled != b) {
    State::bAlphaTestEnabled = b;
    b ? glEnable(GL_ALPHA_TEST) : glDisable(GL_ALPHA_TEST);
  }
}

void RageDisplay_GLES2::SetMaterial(
    const RageColor& emissive, const RageColor& ambient,
    const RageColor& diffuse, const RageColor& specular, float shininess) {
  g_MaterialDiffuse = diffuse;
}

void RageDisplay_GLES2::SetLineWidth(float fWidth) { glLineWidth(fWidth); }

void RageDisplay_GLES2::SetPolygonMode(PolygonMode pm) {
  GLenum m;
  switch (pm) {
    case POLYGON_FILL:
      m = GL_FILL;
      break;
    case POLYGON_LINE:
      m = GL_LINE;
      break;
    default:
      FAIL_M(ssprintf("Invalid PolygonMode: %i", pm));
  }
  glPolygonMode(GL_FRONT_AND_BACK, m);
}

void RageDisplay_GLES2::SetLighting(bool b) {
  // TODO
}

void RageDisplay_GLES2::SetLightOff(int index) {
  // TODO
}

void RageDisplay_GLES2::SetLightDirectional(
    int index, const RageColor& ambient, const RageColor& diffuse,
    const RageColor& specular, const RageVector3& dir) {
  // TODO
}

void RageDisplay_GLES2::SetSphereEnvironmentMapping(TextureUnit tu, bool b) {
  // TODO
}

void RageDisplay_GLES2::SetCelShaded(int stage) {
  // TODO
}

static void SetupShaderAndDraw(
    GLenum mode, const RageSpriteVertex v[], int iNumVerts,
    const RageMatrix* proj, const RageMatrix* view, const RageMatrix* world,
    const RageMatrix* tex) {
  if (!g_ShaderProgram) {
    return;
  }

  glUseProgram(g_ShaderProgram);

  RageMatrix mvp;
  RageMatrixMultiply(&mvp, view, world);
  RageMatrix tmp;
  RageMatrixMultiply(&tmp, proj, &mvp);
  glUniformMatrix4fv(g_UniformMVP, 1, GL_FALSE, (const GLfloat*)&tmp);

  if (tex) {
    glUniformMatrix4fv(g_UniformTexMatrix, 1, GL_FALSE, (const GLfloat*)tex);
  } else {
    RageMatrix identity;
    RageMatrixIdentity(&identity);
    glUniformMatrix4fv(
        g_UniformTexMatrix, 1, GL_FALSE, (const GLfloat*)&identity);
  }

  glUniform1i(g_UniformTexture, 0);
  glUniform1i(g_UniformUseTexture, g_bTextureEnabled ? 1 : 0);
  glUniform1i(g_UniformUseMaterial, 0);

  glEnableVertexAttribArray(g_AttribPosition);
  glEnableVertexAttribArray(g_AttribColor);
  glEnableVertexAttribArray(g_AttribTexCoord);

  /* RageSpriteVertex layout: p(vec3), n(vec3), c(vec4 bytes), t(vec2) */
  const int stride = sizeof(RageSpriteVertex);
  glVertexAttribPointer(
      g_AttribPosition, 3, GL_FLOAT, GL_FALSE, stride, &v[0].p);
  glVertexAttribPointer(
      g_AttribColor, 4, GL_UNSIGNED_BYTE, GL_TRUE, stride, &v[0].c);
  glVertexAttribPointer(
      g_AttribTexCoord, 2, GL_FLOAT, GL_FALSE, stride, &v[0].t);

  glDrawArrays(mode, 0, iNumVerts);

  glDisableVertexAttribArray(g_AttribPosition);
  glDisableVertexAttribArray(g_AttribColor);
  glDisableVertexAttribArray(g_AttribTexCoord);

  glUseProgram(0);
}

void RageDisplay_GLES2::DrawQuadsInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  /* GL ES has no GL_QUADS; convert each quad to two triangles. */
  int iNumQuads = iNumVerts / 4;
  int iNumTriVerts = iNumQuads * 6;
  std::vector<RageSpriteVertex> tri(iNumTriVerts);
  for (int i = 0; i < iNumQuads; i++) {
    tri[i * 6 + 0] = v[i * 4 + 0];
    tri[i * 6 + 1] = v[i * 4 + 1];
    tri[i * 6 + 2] = v[i * 4 + 2];
    tri[i * 6 + 3] = v[i * 4 + 0];
    tri[i * 6 + 4] = v[i * 4 + 2];
    tri[i * 6 + 5] = v[i * 4 + 3];
  }
  SetupShaderAndDraw(
      GL_TRIANGLES, tri.data(), iNumTriVerts, GetProjectionTop(), GetViewTop(),
      GetWorldTop(), GetTextureTop());
}

void RageDisplay_GLES2::DrawQuadStripInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  SetupShaderAndDraw(
      GL_TRIANGLE_STRIP, v, iNumVerts, GetProjectionTop(), GetViewTop(),
      GetWorldTop(), GetTextureTop());
}

void RageDisplay_GLES2::DrawFanInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  SetupShaderAndDraw(
      GL_TRIANGLE_FAN, v, iNumVerts, GetProjectionTop(), GetViewTop(),
      GetWorldTop(), GetTextureTop());
}

void RageDisplay_GLES2::DrawStripInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  SetupShaderAndDraw(
      GL_TRIANGLE_STRIP, v, iNumVerts, GetProjectionTop(), GetViewTop(),
      GetWorldTop(), GetTextureTop());
}

void RageDisplay_GLES2::DrawTrianglesInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  SetupShaderAndDraw(
      GL_TRIANGLES, v, iNumVerts, GetProjectionTop(), GetViewTop(),
      GetWorldTop(), GetTextureTop());
}

void RageDisplay_GLES2::DrawCompiledGeometryInternal(
    const RageCompiledGeometry* p, int iMeshIndex) {
  if (!g_ShaderProgram) {
    return;
  }

  glUseProgram(g_ShaderProgram);

  RageMatrix mvp;
  RageMatrixMultiply(&mvp, GetViewTop(), GetWorldTop());
  RageMatrix tmp;
  RageMatrixMultiply(&tmp, GetProjectionTop(), &mvp);
  glUniformMatrix4fv(g_UniformMVP, 1, GL_FALSE, (const GLfloat*)&tmp);

  const RageMatrix* tex = GetTextureTop();
  const RageCompiledGeometryGLES2* pGLES2 =
      static_cast<const RageCompiledGeometryGLES2*>(p);
  if (tex && pGLES2->NeedsTextureMatrixScale(iMeshIndex)) {
    RageMatrix texNoTranslate = *tex;
    texNoTranslate.m[3][0] = 0;
    texNoTranslate.m[3][1] = 0;
    texNoTranslate.m[3][2] = 0;
    glUniformMatrix4fv(
        g_UniformTexMatrix, 1, GL_FALSE, (const GLfloat*)&texNoTranslate);
  } else if (tex) {
    glUniformMatrix4fv(g_UniformTexMatrix, 1, GL_FALSE, (const GLfloat*)tex);
  } else {
    RageMatrix identity;
    RageMatrixIdentity(&identity);
    glUniformMatrix4fv(
        g_UniformTexMatrix, 1, GL_FALSE, (const GLfloat*)&identity);
  }

  glUniform1i(g_UniformTexture, 0);
  glUniform1i(g_UniformUseTexture, g_bTextureEnabled ? 1 : 0);
  glUniform1i(g_UniformUseMaterial, 1);
  glUniform4f(
      g_UniformMaterialDiffuse, g_MaterialDiffuse.r, g_MaterialDiffuse.g,
      g_MaterialDiffuse.b, g_MaterialDiffuse.a);

  p->Draw(iMeshIndex);

  glUniform1i(g_UniformUseMaterial, 0);
  glUseProgram(0);
}

void RageDisplay_GLES2::DrawLineStripInternal(
    const RageSpriteVertex v[], int iNumVerts, float LineWidth) {
  glLineWidth(LineWidth);
  SetupShaderAndDraw(
      GL_LINE_STRIP, v, iNumVerts, GetProjectionTop(), GetViewTop(),
      GetWorldTop(), GetTextureTop());
}

void RageDisplay_GLES2::DrawSymmetricQuadStripInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  SetupShaderAndDraw(
      GL_TRIANGLE_STRIP, v, iNumVerts, GetProjectionTop(), GetViewTop(),
      GetWorldTop(), GetTextureTop());
}

bool RageDisplay_GLES2::SupportsSurfaceFormat(RagePixelFormat pixfmt) {
  switch (g_GLPixFmtInfo[pixfmt].type) {
    case GL_UNSIGNED_SHORT_1_5_5_5_REV:
      return false;
      // return GLEW_EXT_bgra && g_bReversePackedPixelsWorks;
    default:
      return true;
  }
}

/*
 * Copyright (c) 2012 Colby Klein
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
