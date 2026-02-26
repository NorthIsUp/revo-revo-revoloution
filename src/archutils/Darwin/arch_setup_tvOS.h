#ifndef ARCH_SETUP_TVOS_H
#define ARCH_SETUP_TVOS_H

extern "C" int sm_main( int argc, char *argv[] );

#define HAVE_CXA_DEMANGLE
#define HAVE_DECL_SIGUSR1 1

#define __STDC_FORMAT_MACROS

#define GL_GET_ERROR_IS_SLOW
#define NO_GL_FLUSH

#define CPU_AARCH64

#ifndef TVOS
# define TVOS
#endif

#endif
