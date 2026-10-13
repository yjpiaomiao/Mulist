#include "overlay_stream.hpp"

#include <algorithm>
#include <cstring>

namespace mm {

OverlayStream::OverlayStream(BaseFile *base, const std::string &name) : base_(base), name_(name) {
  int64_t s = base_->size();
  baseSize_ = s < 0 ? 0 : static_cast<uint64_t>(s);
  length_ = baseSize_;
  if (baseSize_ > 0) pieces_.push_back(Piece{true, 0, std::string(), baseSize_});
#if defined(_WIN32)
  wname_.assign(name_.begin(), name_.end());
#endif
}

OverlayStream::~OverlayStream() = default;

TagLib::FileName OverlayStream::name() const {
#if defined(_WIN32)
  return TagLib::FileName(wname_.c_str());
#else
  return name_.c_str();
#endif
}

size_t OverlayStream::readBase(uint64_t off, void *out, size_t len) {
  char *dst = static_cast<char *>(out);
  size_t total = 0;
  while (total < len && off + total < baseSize_) {
    uint64_t cur = off + total;
    uint64_t blockOff = cur - (cur % kBlock);
    CacheBlock *hit = nullptr;
    for (auto &c : cache_)
      if (c.off == blockOff) hit = &c;
    if (!hit) {
      hit = &cache_[0];
      for (auto &c : cache_)
        if (c.stamp < hit->stamp) hit = &c;
      hit->buf.resize(kBlock);
      int64_t r = base_->pread(blockOff, hit->buf.data(), kBlock);
      if (r <= 0) {
        hit->off = UINT64_MAX;
        break;
      }
      hit->off = blockOff;
      hit->len = static_cast<size_t>(r);
    }
    hit->stamp = ++stamp_;
    size_t inBlock = static_cast<size_t>(cur - blockOff);
    if (inBlock >= hit->len) break;
    size_t n = std::min(len - total, hit->len - inBlock);
    memcpy(dst + total, hit->buf.data() + inBlock, n);
    total += n;
  }
  return total;
}

size_t OverlayStream::readAt(uint64_t off, void *out, size_t len) {
  char *dst = static_cast<char *>(out);
  size_t total = 0;
  uint64_t pieceStart = 0;
  for (const auto &p : pieces_) {
    if (total >= len) break;
    uint64_t pieceEnd = pieceStart + p.len;
    uint64_t cur = off + total;
    if (cur < pieceEnd && cur >= pieceStart) {
      uint64_t inPiece = cur - pieceStart;
      size_t n = static_cast<size_t>(std::min<uint64_t>(len - total, p.len - inPiece));
      if (p.base) {
        size_t got = readBase(p.boff + inPiece, dst + total, n);
        total += got;
        if (got < n) break;
      } else {
        memcpy(dst + total, p.data.data() + inPiece, n);
        total += n;
      }
    }
    pieceStart = pieceEnd;
  }
  return total;
}

TagLib::ByteVector OverlayStream::readBlock(size_t length) {
  if (pos_ >= length_ || length == 0) return TagLib::ByteVector();
  size_t n = static_cast<size_t>(std::min<uint64_t>(length, length_ - pos_));
  TagLib::ByteVector v(static_cast<unsigned int>(n), 0);
  size_t got = readAt(pos_, v.data(), n);
  if (got < n) v.resize(static_cast<unsigned int>(got));
  pos_ += got;
  return v;
}

size_t OverlayStream::splitAt(uint64_t off) {
  uint64_t start = 0;
  for (size_t i = 0; i < pieces_.size(); i++) {
    if (start == off) return i;
    uint64_t end = start + pieces_[i].len;
    if (off < end) {
      uint64_t head = off - start;
      Piece tail = pieces_[i];
      tail.len = pieces_[i].len - head;
      if (tail.base) {
        tail.boff += head;
      } else {
        tail.data = pieces_[i].data.substr(static_cast<size_t>(head));
        pieces_[i].data.resize(static_cast<size_t>(head));
      }
      pieces_[i].len = head;
      pieces_.insert(pieces_.begin() + static_cast<long>(i) + 1, std::move(tail));
      return i + 1;
    }
    start = end;
  }
  return pieces_.size();
}

void OverlayStream::replaceRange(uint64_t start, uint64_t removeLen, const char *data,
                                 size_t dataLen) {
  if (start > length_) {
    // Extend with zeros (sparse seek-then-write).
    uint64_t gap = start - length_;
    pieces_.push_back(Piece{false, 0, std::string(static_cast<size_t>(gap), '\0'), gap});
    length_ = start;
  }
  if (start + removeLen > length_) removeLen = length_ - start;
  size_t first = splitAt(start);
  size_t last = splitAt(start + removeLen);
  pieces_.erase(pieces_.begin() + static_cast<long>(first), pieces_.begin() + static_cast<long>(last));
  if (dataLen > 0) {
    // Merge with a preceding data piece to keep the table small.
    if (first > 0 && !pieces_[first - 1].base) {
      pieces_[first - 1].data.append(data, dataLen);
      pieces_[first - 1].len += dataLen;
    } else {
      pieces_.insert(pieces_.begin() + static_cast<long>(first),
                     Piece{false, 0, std::string(data, dataLen), dataLen});
    }
  }
  length_ = length_ - removeLen + dataLen;
}

void OverlayStream::writeBlock(const TagLib::ByteVector &data) {
  if (readOnly_ || data.isEmpty()) return;
  replaceRange(pos_, data.size(), data.data(), data.size());
  pos_ += data.size();
}

void OverlayStream::insert(const TagLib::ByteVector &data, TagLib::offset_t start, size_t replace) {
  if (readOnly_) return;
  replaceRange(static_cast<uint64_t>(start), replace, data.data(), data.size());
  pos_ = static_cast<uint64_t>(start) + data.size();
}

void OverlayStream::removeBlock(TagLib::offset_t start, size_t length) {
  if (readOnly_ || length == 0) return;
  replaceRange(static_cast<uint64_t>(start), length, nullptr, 0);
}

void OverlayStream::seek(TagLib::offset_t offset, Position p) {
  int64_t target = 0;
  switch (p) {
    case Beginning: target = offset; break;
    case Current: target = static_cast<int64_t>(pos_) + offset; break;
    case End: target = static_cast<int64_t>(length_) + offset; break;
  }
  pos_ = target < 0 ? 0 : static_cast<uint64_t>(target);
}

void OverlayStream::truncate(TagLib::offset_t length) {
  if (readOnly_) return;
  uint64_t l = static_cast<uint64_t>(length);
  if (l < length_) replaceRange(l, length_ - l, nullptr, 0);
  else if (l > length_) replaceRange(l, 0, nullptr, 0);
}

bool OverlayStream::modified() const {
  if (length_ != baseSize_) return true;
  if (pieces_.empty()) return false;
  return !(pieces_.size() == 1 && pieces_[0].base && pieces_[0].boff == 0);
}

bool OverlayStream::baseIsIdentity() const {
  uint64_t v = 0;
  for (const auto &p : pieces_) {
    if (p.base && p.boff != v) return false;
    v += p.len;
  }
  return true;
}

std::vector<Range> OverlayStream::dataRanges() const {
  std::vector<Range> out;
  uint64_t v = 0;
  for (const auto &p : pieces_) {
    if (!p.base && p.len > 0) {
      if (!out.empty() && out.back().end() == v) out.back().len += p.len;
      else out.push_back(Range{v, p.len});
    }
    v += p.len;
  }
  return out;
}

std::vector<OverlayStream::Kept> OverlayStream::basePieces() const {
  std::vector<Kept> out;
  uint64_t v = 0;
  for (const auto &p : pieces_) {
    if (p.base && p.len > 0) {
      if (!out.empty() && out.back().boff + out.back().len == p.boff &&
          out.back().voff + out.back().len == v)
        out.back().len += p.len;
      else
        out.push_back(Kept{p.boff, v, p.len});
    }
    v += p.len;
  }
  return out;
}

bool OverlayStream::mapsBase(uint64_t vstart, uint64_t bstart, uint64_t len) const {
  if (len == 0) return true;
  uint64_t v = 0;
  uint64_t covered = 0;
  for (const auto &p : pieces_) {
    uint64_t pe = v + p.len;
    uint64_t cur = vstart + covered;
    if (cur >= v && cur < pe) {
      if (!p.base) return false;
      uint64_t inPiece = cur - v;
      if (p.boff + inPiece != bstart + covered) return false;
      covered += std::min<uint64_t>(len - covered, p.len - inPiece);
      if (covered >= len) return true;
    }
    v = pe;
  }
  return false;
}

}  // namespace mm
