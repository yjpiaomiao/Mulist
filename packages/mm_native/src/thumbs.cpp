#include "thumbs.hpp"

#include <cstdlib>
#include <vector>

#include "base_file.hpp"

#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STB_IMAGE_RESIZE_STATIC
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image_resize2.h"

#define STBI_WRITE_NO_STDIO
#define STB_IMAGE_WRITE_STATIC
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

namespace mm {

static void appendCb(void *ctx, void *data, int size) {
  auto *v = static_cast<std::vector<unsigned char> *>(ctx);
  v->insert(v->end(), static_cast<unsigned char *>(data), static_cast<unsigned char *>(data) + size);
}

bool makeThumb(const unsigned char *data, size_t len, const std::string &outPath, int size,
               std::string &err) {
  if (size < 16) size = 16;
  if (size > 1024) size = 1024;
  int w = 0, h = 0, comp = 0;
  if (!stbi_info_from_memory(data, static_cast<int>(len), &w, &h, &comp) || w <= 0 || h <= 0) {
    err = "decode_failed";
    return false;
  }
  if (static_cast<long long>(w) * h > 64LL * 1000 * 1000) {
    err = "image_too_large";
    return false;
  }
  unsigned char *px = stbi_load_from_memory(data, static_cast<int>(len), &w, &h, &comp, 3);
  if (!px) {
    err = "decode_failed";
    return false;
  }
  int tw = w, th = h;
  if (w > size || h > size) {
    if (w >= h) {
      tw = size;
      th = static_cast<int>(static_cast<long long>(h) * size / w);
    } else {
      th = size;
      tw = static_cast<int>(static_cast<long long>(w) * size / h);
    }
    if (tw < 1) tw = 1;
    if (th < 1) th = 1;
  }
  std::vector<unsigned char> scaled;
  const unsigned char *src = px;
  if (tw != w || th != h) {
    scaled.resize(static_cast<size_t>(tw) * th * 3);
    if (!stbir_resize_uint8_srgb(px, w, h, 0, scaled.data(), tw, th, 0, STBIR_RGB)) {
      stbi_image_free(px);
      err = "resize_failed";
      return false;
    }
    src = scaled.data();
  }
  std::vector<unsigned char> jpg;
  int ok = stbi_write_jpg_to_func(appendCb, &jpg, tw, th, 3, src, 82);
  stbi_image_free(px);
  if (!ok || jpg.empty()) {
    err = "encode_failed";
    return false;
  }
  std::string tmp = outPath + "." + randomSuffix() + ".tmp";
  auto f = openPath(tmp, OpenMode::CreateNew, err);
  if (!f) return false;
  bool wrote = f->pwrite(0, jpg.data(), jpg.size());
  f.reset();
  if (!wrote || !renameFile(tmp, outPath)) {
    removeFile(tmp);
    err = "write_failed";
    return false;
  }
  return true;
}

}  // namespace mm
