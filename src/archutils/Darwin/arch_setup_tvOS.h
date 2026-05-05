#ifndef ARCH_SETUP_TVOS_H
#define ARCH_SETUP_TVOS_H

#define HAVE_CXA_DEMANGLE
#define HAVE_DECL_SIGUSR1 1

#define __STDC_FORMAT_MACROS

#define GL_GET_ERROR_IS_SLOW
#define NO_GL_FLUSH

#ifndef CPU_AARCH64
#define CPU_AARCH64
#endif

#ifndef TVOS
#define TVOS
#endif

#endif
