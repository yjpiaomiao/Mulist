// Cover thumbnails (JPEG/PNG in, JPEG out).
#pragma once

#include <cstddef>
#include <string>

namespace mm {

// Decodes an image and writes a JPEG whose longer side is at most `size`.
bool makeThumb(const unsigned char *data, size_t len, const std::string &outPath, int size,
               std::string &err);

}  // namespace mm
