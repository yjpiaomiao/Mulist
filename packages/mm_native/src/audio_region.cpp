#include "audio_region.hpp"

#include <cstring>

namespace mm {

uint64_t fnv1a64(const void *data, size_t len, uint64_t h) {
  const unsigned char *p = static_cast<const unsigned char *>(data);
  for (size_t i = 0; i < len; i++) {
    h ^= p[i];
    h *= 1099511628211ULL;
  }
  return h;
}

namespace {

bool readExact(const Reader &r, uint64_t off, void *buf, size_t len) {
  if (off + len > r.size) return false;
  return r.read(off, buf, len) == len;
}

uint32_t be32(const unsigned char *p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}
uint64_t be64(const unsigned char *p) { return (uint64_t(be32(p)) << 32) | be32(p + 4); }
uint32_t le32(const unsigned char *p) {
  return (uint32_t(p[3]) << 24) | (uint32_t(p[2]) << 16) | (uint32_t(p[1]) << 8) | p[0];
}
uint64_t le64(const unsigned char *p) { return (uint64_t(le32(p + 4)) << 32) | le32(p); }

// Size of an ID3v2 tag starting at off (0 if none).
uint64_t id3v2SizeAt(const Reader &r, uint64_t off) {
  unsigned char h[10];
  if (!readExact(r, off, h, 10)) return 0;
  if (memcmp(h, "ID3", 3) != 0 || h[3] == 0xFF || h[4] == 0xFF) return 0;
  if ((h[6] | h[7] | h[8] | h[9]) & 0x80) return 0;
  uint64_t size = (uint64_t(h[6]) << 21) | (uint64_t(h[7]) << 14) | (uint64_t(h[8]) << 7) | h[9];
  size += 10;
  if (h[5] & 0x10) size += 10;  // footer
  return size;
}

uint64_t skipLeadingId3v2(const Reader &r) {
  uint64_t off = 0;
  for (int i = 0; i < 8; i++) {
    uint64_t s = id3v2SizeAt(r, off);
    if (s == 0 || off + s > r.size) break;
    off += s;
  }
  return off;
}

// Returns the offset where trailing tags (ID3v1, APEv2, Lyrics3v2) start.
uint64_t trailingTagsStart(const Reader &r, uint64_t minStart) {
  uint64_t end = r.size;
  for (int guard = 0; guard < 8; guard++) {
    bool found = false;
    unsigned char b[32];
    if (end >= minStart + 128 && readExact(r, end - 128, b, 3) && memcmp(b, "TAG", 3) == 0) {
      end -= 128;
      found = true;
    }
    if (end >= minStart + 32 && readExact(r, end - 32, b, 32) && memcmp(b, "APETAGEX", 8) == 0) {
      uint64_t size = le32(b + 12);   // items + footer
      uint32_t flags = le32(b + 20);
      if (flags & 0x80000000u) size += 32;  // has header
      if (size >= 32 && end >= minStart + size) {
        end -= size;
        found = true;
      }
    }
    if (end >= minStart + 15 && readExact(r, end - 9, b, 9) && memcmp(b, "LYRICS200", 9) == 0) {
      unsigned char sz[6];
      if (readExact(r, end - 15, sz, 6)) {
        uint64_t n = 0;
        bool ok = true;
        for (unsigned char c : sz) {
          if (c < '0' || c > '9') ok = false;
          n = n * 10 + (c - '0');
        }
        if (ok && end >= minStart + n + 15) {
          end -= n + 15;
          found = true;
        }
      }
    }
    if (!found) break;
  }
  return end;
}

AudioRegions mpegLike(const Reader &r) {
  AudioRegions a;
  uint64_t start = skipLeadingId3v2(r);
  uint64_t end = trailingTagsStart(r, start);
  if (end <= start) return a;
  a.kind = RegionKind::Ranges;
  a.ranges.push_back(Range{start, end - start});
  return a;
}

AudioRegions flac(const Reader &r) {
  AudioRegions a;
  uint64_t off = skipLeadingId3v2(r);
  unsigned char b[4];
  if (!readExact(r, off, b, 4) || memcmp(b, "fLaC", 4) != 0) return a;
  off += 4;
  for (int i = 0; i < 4096; i++) {
    if (!readExact(r, off, b, 4)) return a;
    uint64_t len = (uint64_t(b[1]) << 16) | (uint64_t(b[2]) << 8) | b[3];
    off += 4 + len;
    if (b[0] & 0x80) break;
  }
  uint64_t end = trailingTagsStart(r, off);
  if (end <= off) return a;
  a.kind = RegionKind::Ranges;
  a.ranges.push_back(Range{off, end - off});
  return a;
}

AudioRegions mp4(const Reader &r) {
  AudioRegions a;
  uint64_t off = 0;
  while (off + 8 <= r.size) {
    unsigned char h[16];
    if (!readExact(r, off, h, 8)) break;
    uint64_t size = be32(h);
    uint64_t hdr = 8;
    if (size == 1) {
      if (!readExact(r, off, h, 16)) break;
      size = be64(h + 8);
      hdr = 16;
    } else if (size == 0) {
      size = r.size - off;
    }
    if (size < hdr || off + size > r.size) break;
    if (memcmp(h + 4, "mdat", 4) == 0) a.ranges.push_back(Range{off + hdr, size - hdr});
    off += size;
  }
  if (!a.ranges.empty()) a.kind = RegionKind::Ranges;
  return a;
}

// RIFF (little endian sizes) / AIFF (big endian sizes).
AudioRegions riff(const Reader &r, bool bigEndian, const char *dataId) {
  AudioRegions a;
  unsigned char h[12];
  if (!readExact(r, 0, h, 12)) return a;
  uint64_t off = 12;
  while (off + 8 <= r.size) {
    if (!readExact(r, off, h, 8)) break;
    uint64_t size = bigEndian ? be32(h + 4) : le32(h + 4);
    if (memcmp(h, dataId, 4) == 0) {
      if (off + 8 + size > r.size) size = r.size - off - 8;
      a.ranges.push_back(Range{off + 8, size});
    }
    off += 8 + size + (size & 1);
  }
  if (!a.ranges.empty()) a.kind = RegionKind::Ranges;
  return a;
}

AudioRegions dsf(const Reader &r) {
  AudioRegions a;
  unsigned char h[28];
  if (!readExact(r, 0, h, 28) || memcmp(h, "DSD ", 4) != 0) return a;
  uint64_t meta = le64(h + 20);
  uint64_t end = (meta >= 28 && meta <= r.size) ? meta : r.size;
  a.kind = RegionKind::Ranges;
  a.ranges.push_back(Range{28, end - 28});
  return a;
}

AudioRegions dsdiff(const Reader &r) {
  AudioRegions a;
  unsigned char h[16];
  if (!readExact(r, 0, h, 16) || memcmp(h, "FRM8", 4) != 0) return a;
  uint64_t off = 16;
  while (off + 12 <= r.size) {
    if (!readExact(r, off, h, 12)) break;
    uint64_t size = be64(h + 4);
    if (off + 12 + size > r.size) break;
    if (memcmp(h, "DSD ", 4) == 0 || memcmp(h, "DST ", 4) == 0)
      a.ranges.push_back(Range{off + 12, size});
    off += 12 + size + (size & 1);
  }
  if (!a.ranges.empty()) a.kind = RegionKind::Ranges;
  return a;
}

AudioRegions asf(const Reader &r) {
  static const unsigned char kData[16] = {0x36, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
                                          0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C};
  AudioRegions a;
  uint64_t off = 0;
  while (off + 24 <= r.size) {
    unsigned char h[24];
    if (!readExact(r, off, h, 24)) break;
    uint64_t size = le64(h + 16);
    if (size < 24 || off + size > r.size) break;
    if (memcmp(h, kData, 16) == 0) a.ranges.push_back(Range{off + 24, size - 24});
    off += size;
  }
  if (!a.ranges.empty()) a.kind = RegionKind::Ranges;
  return a;
}

// Hashes every packet after the header packets of the first logical stream.
AudioRegions ogg(const Reader &r) {
  AudioRegions a;
  uint64_t off = 0;
  uint64_t packet = 0;       // index of the packet currently being assembled
  int64_t headerPackets = -1;
  uint64_t h = 1469598103934665603ULL;
  uint64_t hashed = 0;
  std::vector<unsigned char> buf;
  std::string first;         // bytes of packet 0 (for codec detection)
  uint32_t serial = 0;
  bool haveSerial = false;
  while (off + 27 <= r.size) {
    unsigned char ph[27];
    if (!readExact(r, off, ph, 27) || memcmp(ph, "OggS", 4) != 0) return AudioRegions();
    uint32_t pageSerial = le32(ph + 14);
    unsigned nseg = ph[26];
    unsigned char lacing[255];
    if (nseg && !readExact(r, off + 27, lacing, nseg)) return AudioRegions();
    uint64_t bodyOff = off + 27 + nseg;
    uint64_t bodyLen = 0;
    for (unsigned i = 0; i < nseg; i++) bodyLen += lacing[i];
    if (bodyOff + bodyLen > r.size) return AudioRegions();
    if (!haveSerial) {
      serial = pageSerial;
      haveSerial = true;
    }
    if (pageSerial == serial) {
      buf.resize(static_cast<size_t>(bodyLen));
      if (bodyLen && !readExact(r, bodyOff, buf.data(), buf.size())) return AudioRegions();
      size_t p = 0;
      for (unsigned i = 0; i < nseg; i++) {
        size_t n = lacing[i];
        if (packet == 0 && first.size() < 64) first.append(reinterpret_cast<char *>(buf.data() + p), n);
        if (headerPackets >= 0 && static_cast<int64_t>(packet) >= headerPackets) {
          h = fnv1a64(buf.data() + p, n, h);
          hashed += n;
        }
        p += n;
        if (lacing[i] < 255) {
          // packet finished
          if (packet == 0) {
            if (first.compare(0, 7, "\x01vorbis") == 0) headerPackets = 3;
            else if (first.compare(0, 8, "OpusHead") == 0) headerPackets = 2;
            else if (first.compare(0, 8, "Speex   ") == 0) headerPackets = 2;
            else if (first.size() >= 9 && first.compare(0, 5, "\x7f" "FLAC") == 0)
              headerPackets = 1 + ((static_cast<unsigned char>(first[7]) << 8) |
                                   static_cast<unsigned char>(first[8]));
            else return AudioRegions();
            // Ogg FLAC with unknown header count: count metadata packets by flag instead.
            if (headerPackets == 1) return AudioRegions();
          }
          // mix in a packet boundary so that re-segmentation is detected
          if (headerPackets >= 0 && static_cast<int64_t>(packet) >= headerPackets) {
            unsigned char sep = 0xA5;
            h = fnv1a64(&sep, 1, h);
          }
          packet++;
        }
      }
    }
    off = bodyOff + bodyLen;
  }
  if (headerPackets < 0) return AudioRegions();
  a.kind = RegionKind::OggHash;
  a.hash = h;
  a.hashedBytes = hashed;
  return a;
}

}  // namespace

AudioRegions locateAudio(const Reader &r, const std::string &ext) {
  if (ext == "flac") return flac(r);
  if (ext == "m4a" || ext == "m4b" || ext == "mp4" || ext == "m4p" || ext == "m4r" || ext == "3g2" ||
      ext == "aax")
    return mp4(r);
  if (ext == "wav") return riff(r, false, "data");
  if (ext == "aif" || ext == "aiff" || ext == "aifc" || ext == "afc") return riff(r, true, "SSND");
  if (ext == "dsf") return dsf(r);
  if (ext == "dff" || ext == "dsdiff") return dsdiff(r);
  if (ext == "wma" || ext == "asf") return asf(r);
  if (ext == "ogg" || ext == "oga" || ext == "opus" || ext == "spx") return ogg(r);
  if (ext == "mp3" || ext == "mp2" || ext == "aac" || ext == "ape" || ext == "wv" || ext == "mpc" ||
      ext == "tta")
    return mpegLike(r);
  return AudioRegions();
}

}  // namespace mm
