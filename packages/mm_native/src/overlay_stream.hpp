// A copy-on-write TagLib IOStream. Reads come from an underlying file;
// writes, inserts and removals are recorded in a piece table in memory, so
// TagLib can "save" without touching the original file. Afterwards the
// piece table tells us exactly which byte ranges changed and where every
// original byte ended up, which drives both the write strategy (in-place
// patch vs. full rewrite) and the verification that audio data is intact.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "base_file.hpp"
#include "tiostream.h"

namespace mm {

struct Range {
  uint64_t start = 0;
  uint64_t len = 0;
  uint64_t end() const { return start + len; }
};

class OverlayStream : public TagLib::IOStream {
 public:
  OverlayStream(BaseFile *base, const std::string &name);
  ~OverlayStream() override;

  // TagLib::IOStream
  TagLib::FileName name() const override;
  TagLib::ByteVector readBlock(size_t length) override;
  void writeBlock(const TagLib::ByteVector &data) override;
  void insert(const TagLib::ByteVector &data, TagLib::offset_t start = 0, size_t replace = 0) override;
  void removeBlock(TagLib::offset_t start = 0, size_t length = 0) override;
  bool readOnly() const override { return readOnly_; }
  bool isOpen() const override { return true; }
  void seek(TagLib::offset_t offset, Position p = Beginning) override;
  void clear() override {}
  TagLib::offset_t tell() const override { return static_cast<TagLib::offset_t>(pos_); }
  TagLib::offset_t length() override { return static_cast<TagLib::offset_t>(length_); }
  void truncate(TagLib::offset_t length) override;

  void setReadOnly(bool ro) { readOnly_ = ro; }

  // Analysis helpers
  uint64_t size() const { return length_; }
  uint64_t baseSize() const { return baseSize_; }
  bool modified() const;
  // Reads virtual bytes at off. Returns number of bytes read.
  size_t readAt(uint64_t off, void *buf, size_t len);
  // True if all original bytes stay at their original offsets.
  bool baseIsIdentity() const;
  // Virtual ranges whose content came from writes (not from the base file).
  std::vector<Range> dataRanges() const;
  // True if virtual [vstart, vstart+len) is an unmodified copy of base
  // [bstart, bstart+len).
  bool mapsBase(uint64_t vstart, uint64_t bstart, uint64_t len) const;
  // Unmodified runs of the base file: where they were and where they are now.
  struct Kept { uint64_t boff, voff, len; };
  std::vector<Kept> basePieces() const;
  // Reads from the base file directly (original content).
  size_t readBase(uint64_t off, void *buf, size_t len);

 private:
  struct Piece {
    bool base;
    uint64_t boff;      // base offset (base pieces)
    std::string data;   // owned bytes (data pieces)
    uint64_t len;
  };
  void replaceRange(uint64_t start, uint64_t removeLen, const char *data, size_t dataLen);
  size_t splitAt(uint64_t off);  // returns index of first piece starting at off

  BaseFile *base_;
  std::string name_;
#if defined(_WIN32)
  std::wstring wname_;
#endif
  std::vector<Piece> pieces_;
  uint64_t length_ = 0;
  uint64_t baseSize_ = 0;
  uint64_t pos_ = 0;
  bool readOnly_ = false;

  // tiny block cache for base reads
  struct CacheBlock {
    uint64_t off = UINT64_MAX;
    size_t len = 0;
    uint64_t stamp = 0;
    std::vector<char> buf;
  };
  static constexpr size_t kBlock = 64 * 1024;
  CacheBlock cache_[4];
  uint64_t stamp_ = 0;
};

}  // namespace mm
