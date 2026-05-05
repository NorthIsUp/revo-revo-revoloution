if(CMAKE_GENERATOR MATCHES "Ninja")
  message(
    FATAL_ERROR
      "You cannot use the Ninja generator when building the bundled ffmpeg library."
    )
endif()

set(SM_FFMPEG_SRC_DIR "${SM_EXTERN_DIR}/ffmpeg")
set(SM_FFMPEG_CONFIGURE_EXE "${SM_FFMPEG_SRC_DIR}/configure")

list(APPEND FFMPEG_CONFIGURE
            "${SM_FFMPEG_CONFIGURE_EXE}"
            "--disable-autodetect"
            "--disable-avdevice"
            "--disable-avfilter"
            "--disable-devices"
            "--disable-doc"
            "--disable-filters"
            "--disable-lzma"
            "--disable-network"
            "--disable-postproc"
            "--disable-programs"
            "--disable-swresample"
            "--disable-vaapi"
            "--disable-bzlib"
            "--enable-gpl"
            "--enable-pthreads"
            "--enable-static"
            "--enable-zlib"
            "--prefix=/")

if(CMAKE_POSITION_INDEPENDENT_CODE)
  list(APPEND FFMPEG_CONFIGURE "--enable-pic")
endif()

if(MACOSX)
  list(APPEND FFMPEG_CONFIGURE "--enable-cross-compile")
  list(APPEND FFMPEG_CONFIGURE "--enable-videotoolbox")
  list(APPEND FFMPEG_CONFIGURE "--extra-cflags=-mmacosx-version-min=11")
  if(CMAKE_OSX_ARCHITECTURES STREQUAL "arm64")
    list(APPEND FFMPEG_CONFIGURE "--arch=arm64" "--extra-cflags=-arch arm64" "--extra-ldflags=-arch arm64")
  elseif(CMAKE_OSX_ARCHITECTURES STREQUAL "x86_64")
    list(APPEND FFMPEG_CONFIGURE "--arch=x86_64" "--extra-cflags=-arch x86_64" "--extra-ldflags=-arch x86_64")
  else()
    message(FATAL_ERROR
      "Unsupported macOS architecture: ${CMAKE_OSX_ARCHITECTURES}, set CMAKE_OSX_ARCHITECTURES to either arm64 or x86_64"
    )
  endif()
endif()

if(TVOS)
  set(TVOS_SDK_NAME "${CMAKE_OSX_SYSROOT}")
  execute_process(COMMAND xcrun --sdk ${TVOS_SDK_NAME} --show-sdk-path
                  OUTPUT_VARIABLE TVOS_SDK_PATH
                  OUTPUT_STRIP_TRAILING_WHITESPACE)
  if(TVOS_SDK_NAME MATCHES "simulator")
    set(TVOS_MIN_VERSION_FLAG "-mappletvsimulator-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
  else()
    set(TVOS_MIN_VERSION_FLAG "-mappletvos-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
  endif()
  list(APPEND FFMPEG_CONFIGURE "--enable-cross-compile"
                               "--target-os=darwin"
                               "--arch=arm64"
                               "--enable-videotoolbox"
                               "--sysroot=${TVOS_SDK_PATH}"
                               "--extra-cflags=-arch arm64 ${TVOS_MIN_VERSION_FLAG}"
                               "--extra-ldflags=-arch arm64 ${TVOS_MIN_VERSION_FLAG}")
  list(APPEND FFMPEG_CONFIGURE "--cc=xcrun --sdk ${TVOS_SDK_NAME} clang")
endif()

if(NOT WITH_EXTERNAL_WARNINGS)
  list(APPEND FFMPEG_CONFIGURE "--extra-cflags=-w")
endif()

# NOTE: ffmpeg's configure does not accept a ranlib command with spaces, so
# its handful of "has no symbols" warnings (libavformat/os_support.o etc.)
# are left as-is rather than wrapped via --ranlib=...

if(CMAKE_GENERATOR STREQUAL "Xcode")
  list(APPEND SM_FFMPEG_MAKE "make")
else()
  list(APPEND SM_FFMPEG_MAKE $(MAKE))
endif()

if(WITH_FFMPEG_JOBS GREATER 0)
  list(APPEND SM_FFMPEG_MAKE "-j${WITH_FFMPEG_JOBS}")
endif()
list(APPEND SM_FFMPEG_MAKE "&&" "make" "DESTDIR=./dest" "install")

externalproject_add("ffmpeg"
                    SOURCE_DIR "${SM_FFMPEG_SRC_DIR}"
                    CONFIGURE_COMMAND ${FFMPEG_CONFIGURE}
                    BUILD_COMMAND "${SM_FFMPEG_MAKE}"
                    UPDATE_COMMAND ""
                    INSTALL_COMMAND ""
                    TEST_COMMAND "")

externalproject_get_property("ffmpeg" BINARY_DIR)
set(SM_FFMPEG_LIB ${BINARY_DIR}/dest/lib)
set(SM_FFMPEG_INCLUDE ${BINARY_DIR}/dest/include)
