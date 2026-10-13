// Locates the audio payload inside a file without decoding it, so a tag
// write can be proven not to have touched the audio data.
#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "overlay_stream.hpp"

namespace mm {

struct Reader {
  std::function<size_t(uint64_t, void *, size_t)> read;
  uint64_t size = 0;
};

enum class RegionKind {
  None,     // format not understood: caller falls back to property checks
  Ranges,   // byte ranges that must be carried over unmodified
  OggHash,  // hash over the audio packets of an Ogg stream
};

struct AudioRegions {
  RegionKind kind = RegionKind::None;
  std::vector<Range> ranges;
  uint64_t hash = 0;
  uint64_t hashedBytes = 0;
};

// ext is the lower-case file extension without dot.
AudioRegions locateAudio(const Reader &r, const std::string &ext);

uint64_t fnv1a64(const void *data, size_t len, uint64_t seed = 1469598103934665603ULL);

}  // namespace mm
