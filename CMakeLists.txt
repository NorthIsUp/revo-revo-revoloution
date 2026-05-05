cmake_minimum_required(VERSION 3.20)

# Apple's libtool/ranlib emit "has no symbols" warnings for translation
# units that compile down to nothing on arm64 (mbedtls, tomcrypt, tommath,
# vorbis, etc. all have several). Silence the noise repo-wide.
# Xcode generator uses libtool, Makefile/Ninja uses ar+ranlib — handle both.
# Must be set BEFORE project() so the Xcode attribute is captured globally.
if(APPLE OR CMAKE_HOST_APPLE)
  set(CMAKE_C_ARCHIVE_FINISH "<CMAKE_RANLIB> -no_warning_for_no_symbols <TARGET>")
  set(CMAKE_CXX_ARCHIVE_FINISH "<CMAKE_RANLIB> -no_warning_for_no_symbols <TARGET>")
  # Apple linker (libtool) flag — use the *_INIT variant so it propagates to
  # all targets including those defined via add_subdirectory(extern).
  set(CMAKE_STATIC_LINKER_FLAGS_INIT "-no_warning_for_no_symbols")
endif()

project(StepMania)

include(StepmaniaCore.cmake)

# The external libraries need to be included.
add_subdirectory(extern)

# The internal libraries and eventual executable to be used.
add_subdirectory(src)
