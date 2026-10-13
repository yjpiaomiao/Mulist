/* Hand-written replacement for TagLib's CMake-generated config.h. */
#ifndef TAGLIB_CONFIG_H
#define TAGLIB_CONFIG_H
#if defined(_MSC_VER)
#define HAVE_MSC_BYTESWAP 1
#elif defined(__APPLE__)
#define HAVE_MAC_BYTESWAP 1
#elif defined(__GNUC__) || defined(__clang__)
#define HAVE_GCC_BYTESWAP 1
#endif
#define HAVE_ISO_STRDUP 1
#endif
