set(CMAKE_SYSTEM_NAME tvOS)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_SYSROOT appletvos)

if(NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "Minimum tvOS deployment target")
endif()

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH NO)
set(CMAKE_IOS_INSTALL_COMBINED NO)

# Apple's ranlib emits "has no symbols" for translation units that compile
# down to nothing on arm64 (mbedtls/tomcrypt/tommath/vorbis/libjpeg-turbo
# all have several). Silence the noise repo-wide via -no_warning_for_no_symbols.
# Applies to all targets in this build AND propagates to ExternalProject_Add
# children that pick up the toolchain.
set(CMAKE_C_ARCHIVE_FINISH "<CMAKE_RANLIB> -no_warning_for_no_symbols <TARGET>")
set(CMAKE_CXX_ARCHIVE_FINISH "<CMAKE_RANLIB> -no_warning_for_no_symbols <TARGET>")
