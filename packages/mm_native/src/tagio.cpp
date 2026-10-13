// Tag reading and safe tag writing on top of TagLib.
//
// Write protocol
// --------------
//   mm_prepare_write(request) -> plan
//     request: {
//       "set":   {"TITLE": ["..."], "GENRE": []},      // [] removes the key
//       "cover": {"action": "keep"|"remove"|"set", "path": "..."},
//       "backupPath": "...",     // byte-level backup of everything that changes
//       "stagePath":  "...",     // where new bytes are staged (required for fd)
//       "keepMtime":  true,
//       "expectSize": N, "expectMtimeNs": T   // optional: fail if file changed
//     }
//     Nothing is written to the audio file. TagLib saves into a piece table
//     (OverlayStream); the result is re-parsed and verified:
//       * edited keys have the requested values
//       * every other key, the unsupported-data list and the pictures are
//         unchanged
//       * audio properties are unchanged
//       * the audio payload is carried over byte for byte
//     A desktop rewrite always stages next to the target (atomic replace).
//     plan: {"ok":true, "mode":"patch"|"rewrite"|"noop", "stagePath",
//            "backupPath", "expectSize", "expectMtimeNs", "newSize",
//            "setMtimeNs", "patches":[[off,len,stageOff]...], "audioCheck",
//            "rejected":[keys], + snapshot of the result}
//
//   mm_commit(plan [+ "force": true])
//     patch:   overwrites the changed ranges in place (file size unchanged)
//     rewrite: path -> atomic replace with the staged file
//              fd   -> copies the staged file over the descriptor, truncates
//     Re-running a commit with force is safe (roll forward after a crash).
//
//   mm_prepare_restore({"backupPath","stagePath","keepMtime"}) -> plan that
//     restores the exact original bytes (only if the bytes the write
//     produced are still there); commit it with mm_commit.
#include <algorithm>
#include <functional>
#include <cstring>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "audio_region.hpp"
#include "base_file.hpp"
#include "json.hpp"
#include "mm_core.h"
#include "overlay_stream.hpp"
#include "thumbs.hpp"

#include "apefile.h"
#include "apetag.h"
#include "aifffile.h"
#include "asffile.h"
#include "dsdifffile.h"
#include "dsffile.h"
#include "fileref.h"
#include "flacfile.h"
#include "id3v1tag.h"
#include "id3v2header.h"
#include "id3v2tag.h"
#include "infotag.h"
#include "mp4file.h"
#include "mpcfile.h"
#include "mpegfile.h"
#include "oggflacfile.h"
#include "opusfile.h"
#include "speexfile.h"
#include "tpropertymap.h"
#include "trueaudiofile.h"
#include "vorbisfile.h"
#include "wavfile.h"
#include "wavpackfile.h"
#include "xiphcomment.h"

using namespace TagLib;

namespace mm {
namespace {

char *dup(const std::string &s) {
  char *p = static_cast<char *>(malloc(s.size() + 1));
  if (p) memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

char *fail(const std::string &code, const std::string &detail = "") {
  JsonWriter w;
  w.beginObject().kv("ok", false).kv("error", code);
  if (!detail.empty()) w.kv("detail", detail);
  w.endObject();
  return dup(w.str());
}

std::string u8(const String &s) { return s.to8Bit(true); }
String fromU8(const std::string &s) { return String(s, String::UTF8); }

std::string lowerExt(const std::string &name) {
  size_t p = name.find_last_of('.');
  if (p == std::string::npos) return "";
  std::string e = name.substr(p + 1);
  for (auto &c : e) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
  return e;
}

std::string hex16(uint64_t v) {
  char b[17];
  snprintf(b, sizeof b, "%016llx", static_cast<unsigned long long>(v));
  return b;
}

std::string pictureHash(const ByteVector &d) {
  return hex16(fnv1a64(d.data(), d.size())) + "-" + std::to_string(d.size());
}

struct Opened {
  std::unique_ptr<BaseFile> base;
  std::string name;  // file name used for type detection
};

bool openTarget(const char *path, int fd, const char *name, bool write, Opened &o, std::string &err) {
  if (fd >= 0) {
    o.base = wrapFd(fd, write);
    o.name = name ? name : "";
    if (!o.base) {
      err = "fd_unsupported";
      return false;
    }
  } else {
    if (!path) {
      err = "no_path";
      return false;
    }
    o.base = openPath(path, write ? OpenMode::ReadWrite : OpenMode::Read, err);
    o.name = (name && *name) ? name : baseName(path);
    if (!o.base) return false;
  }
  return true;
}

// ----------------------------------------------------------------- tags

std::string id3v2Name(ID3v2::Tag *t) {
  unsigned major = t->header() ? t->header()->majorVersion() : 4;
  return "ID3v2." + std::to_string(major);
}

ID3v2::Version id3v2SaveVersion(ID3v2::Tag *existing, bool existsOnDisk) {
  if (!existing || !existsOnDisk) return ID3v2::v3;  // new tags: v2.3 for compatibility
  return existing->header()->majorVersion() >= 4 ? ID3v2::v4 : ID3v2::v3;
}

// Describes the tags of a file: which exist on disk, and which tag objects
// must receive edits (primary tag is created if missing; secondary tags are
// only updated when they already exist).
struct TagSet {
  std::vector<std::string> formats;
  std::vector<Tag *> existing;  // parallel to formats (nullptr if unknown)
  std::vector<Tag *> targets;
};

TagSet collectTags(File *f, bool forWrite) {
  TagSet s;
  auto add = [&s](const std::string &name, Tag *t) {
    s.formats.push_back(name);
    s.existing.push_back(t);
  };
  if (auto *m = dynamic_cast<MPEG::File *>(f)) {
    if (m->hasID3v2Tag()) add(id3v2Name(m->ID3v2Tag()), m->ID3v2Tag());
    if (m->hasAPETag()) add("APEv2", m->APETag());
    if (m->hasID3v1Tag()) add("ID3v1", m->ID3v1Tag());
    if (forWrite) {
      s.targets.push_back(m->ID3v2Tag(true));
      if (m->hasAPETag()) s.targets.push_back(m->APETag());
      if (m->hasID3v1Tag()) s.targets.push_back(m->ID3v1Tag());
    }
  } else if (auto *fl = dynamic_cast<FLAC::File *>(f)) {
    if (fl->hasXiphComment()) add("Vorbis Comment", fl->xiphComment());
    if (fl->hasID3v2Tag()) add(id3v2Name(fl->ID3v2Tag()), fl->ID3v2Tag());
    if (fl->hasID3v1Tag()) add("ID3v1", fl->ID3v1Tag());
    if (forWrite) {
      s.targets.push_back(fl->xiphComment(true));
      if (fl->hasID3v2Tag()) s.targets.push_back(fl->ID3v2Tag());
      if (fl->hasID3v1Tag()) s.targets.push_back(fl->ID3v1Tag());
    }
  } else if (auto *w = dynamic_cast<RIFF::WAV::File *>(f)) {
    if (w->hasID3v2Tag()) add(id3v2Name(w->ID3v2Tag()), w->ID3v2Tag());
    if (w->hasInfoTag()) add("RIFF INFO", w->InfoTag());
    if (forWrite) {
      s.targets.push_back(w->ID3v2Tag());
      if (w->hasInfoTag()) s.targets.push_back(w->InfoTag());
    }
  } else if (auto *a = dynamic_cast<RIFF::AIFF::File *>(f)) {
    if (a->hasID3v2Tag()) add(id3v2Name(a->tag()), a->tag());
    if (forWrite) s.targets.push_back(a->tag());
  } else if (auto *d = dynamic_cast<DSF::File *>(f)) {
    if (d->tag() && d->tag()->header()->tagSize() > 0) add(id3v2Name(d->tag()), d->tag());
    if (forWrite) s.targets.push_back(d->tag());
  } else if (auto *dd = dynamic_cast<DSDIFF::File *>(f)) {
    if (dd->hasID3v2Tag()) add(id3v2Name(dd->ID3v2Tag()), dd->ID3v2Tag());
    if (dd->hasDIINTag()) add("DIIN", dd->DIINTag());
    if (forWrite) {
      s.targets.push_back(dd->ID3v2Tag(true));
      if (dd->hasDIINTag()) s.targets.push_back(dd->DIINTag());
    }
  } else if (auto *ap = dynamic_cast<APE::File *>(f)) {
    if (ap->hasAPETag()) add("APEv2", ap->APETag());
    if (ap->hasID3v1Tag()) add("ID3v1", ap->ID3v1Tag());
    if (forWrite) {
      s.targets.push_back(ap->APETag(true));
      if (ap->hasID3v1Tag()) s.targets.push_back(ap->ID3v1Tag());
    }
  } else if (auto *wv = dynamic_cast<WavPack::File *>(f)) {
    if (wv->hasAPETag()) add("APEv2", wv->APETag());
    if (wv->hasID3v1Tag()) add("ID3v1", wv->ID3v1Tag());
    if (forWrite) {
      s.targets.push_back(wv->APETag(true));
      if (wv->hasID3v1Tag()) s.targets.push_back(wv->ID3v1Tag());
    }
  } else if (auto *mp = dynamic_cast<MPC::File *>(f)) {
    if (mp->hasAPETag()) add("APEv2", mp->APETag());
    if (mp->hasID3v1Tag()) add("ID3v1", mp->ID3v1Tag());
    if (forWrite) {
      s.targets.push_back(mp->APETag(true));
      if (mp->hasID3v1Tag()) s.targets.push_back(mp->ID3v1Tag());
    }
  } else if (auto *tt = dynamic_cast<TrueAudio::File *>(f)) {
    if (tt->hasID3v2Tag()) add(id3v2Name(tt->ID3v2Tag()), tt->ID3v2Tag());
    if (tt->hasID3v1Tag()) add("ID3v1", tt->ID3v1Tag());
    if (forWrite) {
      s.targets.push_back(tt->ID3v2Tag(true));
      if (tt->hasID3v1Tag()) s.targets.push_back(tt->ID3v1Tag());
    }
  } else if (dynamic_cast<MP4::File *>(f)) {
    if (f->tag() && !f->tag()->isEmpty()) add("MP4 (iTunes)", f->tag());
  } else if (dynamic_cast<ASF::File *>(f)) {
    if (f->tag() && !f->tag()->isEmpty()) add("ASF", f->tag());
  } else if (dynamic_cast<Ogg::File *>(f)) {
    if (f->tag()) add("Vorbis Comment", f->tag());
  }
  return s;
}

bool saveFile(File *f) {
  if (auto *m = dynamic_cast<MPEG::File *>(f)) {
    auto v = id3v2SaveVersion(m->ID3v2Tag(), m->hasID3v2Tag());
    return m->save(MPEG::File::AllTags, File::StripNone, v, File::DoNotDuplicate);
  }
  if (auto *w = dynamic_cast<RIFF::WAV::File *>(f)) {
    auto v = id3v2SaveVersion(w->ID3v2Tag(), w->hasID3v2Tag());
    auto tags = w->hasInfoTag() ? RIFF::WAV::File::AllTags : RIFF::WAV::File::ID3v2;
    return w->save(tags, File::StripNone, v);
  }
  if (auto *a = dynamic_cast<RIFF::AIFF::File *>(f))
    return a->save(id3v2SaveVersion(a->tag(), a->hasID3v2Tag()));
  if (auto *d = dynamic_cast<DSF::File *>(f)) {
    bool had = d->tag() && d->tag()->header() && d->tag()->header()->tagSize() > 0;
    return d->save(id3v2SaveVersion(d->tag(), had));
  }
  if (auto *dd = dynamic_cast<DSDIFF::File *>(f)) {
    auto v = id3v2SaveVersion(dd->ID3v2Tag(), dd->hasID3v2Tag());
    return dd->save(DSDIFF::File::AllTags, File::StripNone, v);
  }
  return f->save();
}

// ------------------------------------------------------------- snapshot

struct PictureInfo {
  std::string mime, type, desc, hash;
  uint64_t size = 0;
};

struct AudioInfo {
  std::string container, codec;
  int bitrate = 0, sampleRate = 0, channels = 0, bitDepth = 0;
  int64_t durationMs = 0;
  bool operator==(const AudioInfo &o) const {
    return codec == o.codec && sampleRate == o.sampleRate && channels == o.channels &&
           bitDepth == o.bitDepth && std::llabs(durationMs - o.durationMs) <= 50;
  }
};

struct Snapshot {
  std::map<std::string, std::vector<std::string>> props;
  std::vector<std::string> unsupported;
  std::vector<PictureInfo> pictures;
  AudioInfo audio;
  std::vector<std::string> formats;
  // Per-tag property maps (only filled in detail mode).
  std::vector<std::pair<std::string, std::map<std::string, std::vector<std::string>>>> tags;
};

std::map<std::string, std::vector<std::string>> toStd(const PropertyMap &m) {
  std::map<std::string, std::vector<std::string>> out;
  for (const auto &[k, vals] : m) {
    std::vector<std::string> v;
    for (const auto &s : vals) v.push_back(u8(s));
    out[u8(k)] = v;
  }
  return out;
}

AudioInfo audioInfo(File *f, const std::string &ext) {
  AudioInfo a;
  AudioProperties *p = f->audioProperties();
  if (p) {
    a.bitrate = p->bitrate();
    a.sampleRate = p->sampleRate();
    a.channels = p->channels();
    a.durationMs = p->lengthInMilliseconds();
  }
  if (auto *m = dynamic_cast<MPEG::File *>(f)) {
    auto *mp = m->audioProperties();
    if (mp && mp->isADTS()) {
      a.container = "ADTS";
      a.codec = "AAC";
    } else {
      a.container = "MPEG";
      int layer = mp ? mp->layer() : 3;
      a.codec = layer == 3 ? "MP3" : (layer == 2 ? "MP2" : "MP1");
    }
  } else if (auto *fl = dynamic_cast<FLAC::File *>(f)) {
    a.container = "FLAC";
    a.codec = "FLAC";
    if (fl->audioProperties()) a.bitDepth = fl->audioProperties()->bitsPerSample();
  } else if (auto *m4 = dynamic_cast<MP4::File *>(f)) {
    a.container = "MP4";
    auto *mp = m4->audioProperties();
    if (mp) {
      a.codec = mp->codec() == MP4::Properties::ALAC ? "ALAC"
                : mp->codec() == MP4::Properties::AAC ? "AAC" : u8(mp->codecId());
      if (mp->codec() == MP4::Properties::ALAC) a.bitDepth = mp->bitsPerSample();
    }
  } else if (dynamic_cast<Ogg::Vorbis::File *>(f)) {
    a.container = "Ogg";
    a.codec = "Vorbis";
  } else if (dynamic_cast<Ogg::Opus::File *>(f)) {
    a.container = "Ogg";
    a.codec = "Opus";
  } else if (dynamic_cast<Ogg::Speex::File *>(f)) {
    a.container = "Ogg";
    a.codec = "Speex";
  } else if (auto *of = dynamic_cast<Ogg::FLAC::File *>(f)) {
    a.container = "Ogg";
    a.codec = "FLAC";
    if (of->audioProperties()) a.bitDepth = of->audioProperties()->bitsPerSample();
  } else if (auto *w = dynamic_cast<RIFF::WAV::File *>(f)) {
    a.container = "WAV";
    auto *wp = w->audioProperties();
    if (wp) {
      a.bitDepth = wp->bitsPerSample();
      int fmt = wp->format();
      a.codec = fmt == 1 ? "PCM" : fmt == 3 ? "PCM (float)" : "WAVE format " + std::to_string(fmt);
    }
  } else if (auto *ai = dynamic_cast<RIFF::AIFF::File *>(f)) {
    a.container = "AIFF";
    auto *ap = ai->audioProperties();
    if (ap) {
      a.bitDepth = ap->bitsPerSample();
      a.codec = ap->isAiffC() ? u8(String(ap->compressionType(), String::Latin1)) : "PCM";
    }
  } else if (auto *d = dynamic_cast<DSF::File *>(f)) {
    a.container = "DSF";
    a.codec = "DSD";
    if (d->audioProperties()) a.bitDepth = d->audioProperties()->bitsPerSample();
  } else if (auto *dd = dynamic_cast<DSDIFF::File *>(f)) {
    a.container = "DSDIFF";
    a.codec = "DSD";
    if (dd->audioProperties()) a.bitDepth = dd->audioProperties()->bitsPerSample();
  } else if (auto *ape = dynamic_cast<APE::File *>(f)) {
    a.container = "APE";
    a.codec = "Monkey's Audio";
    if (ape->audioProperties()) a.bitDepth = ape->audioProperties()->bitsPerSample();
  } else if (auto *wv = dynamic_cast<WavPack::File *>(f)) {
    a.container = "WavPack";
    a.codec = "WavPack";
    if (wv->audioProperties()) a.bitDepth = wv->audioProperties()->bitsPerSample();
  } else if (dynamic_cast<MPC::File *>(f)) {
    a.container = "Musepack";
    a.codec = "Musepack";
  } else if (auto *tt = dynamic_cast<TrueAudio::File *>(f)) {
    a.container = "TTA";
    a.codec = "True Audio";
    if (tt->audioProperties()) a.bitDepth = tt->audioProperties()->bitsPerSample();
  } else if (auto *as = dynamic_cast<ASF::File *>(f)) {
    a.container = "ASF";
    auto *ap = as->audioProperties();
    if (ap) {
      a.codec = u8(ap->codecName());
      if (a.codec.empty()) a.codec = "WMA";
      a.bitDepth = ap->bitsPerSample();
    }
  } else {
    a.container = ext;
  }
  return a;
}

Snapshot snapshot(File *f, const std::string &ext, List<VariantMap> *rawPictures = nullptr,
                  bool detail = false) {
  Snapshot s;
  PropertyMap pm = f->properties();
  s.props = toStd(pm);
  for (const auto &u : pm.unsupportedData()) s.unsupported.push_back(u8(u));
  std::sort(s.unsupported.begin(), s.unsupported.end());
  List<VariantMap> pics = f->complexProperties("PICTURE");
  for (const auto &p : pics) {
    PictureInfo pi;
    ByteVector data = p.value("data").toByteVector();
    pi.mime = u8(p.value("mimeType").toString());
    pi.type = u8(p.value("pictureType").toString());
    pi.desc = u8(p.value("description").toString());
    pi.size = data.size();
    pi.hash = pictureHash(data);
    s.pictures.push_back(pi);
  }
  if (rawPictures) *rawPictures = pics;
  s.audio = audioInfo(f, ext);
  TagSet ts = collectTags(f, false);
  s.formats = ts.formats;
  if (detail)
    for (size_t i = 0; i < ts.formats.size(); i++)
      s.tags.emplace_back(ts.formats[i], ts.existing[i] ? toStd(ts.existing[i]->properties())
                                                        : std::map<std::string, std::vector<std::string>>());
  return s;
}

void writeProps(JsonWriter &w, const std::map<std::string, std::vector<std::string>> &props) {
  w.beginObject();
  for (const auto &[k, vals] : props) {
    w.key(k).beginArray();
    for (const auto &v : vals) w.value(v);
    w.endArray();
  }
  w.endObject();
}

void writeSnapshot(JsonWriter &w, const Snapshot &s) {
  w.key("props");
  writeProps(w, s.props);
  if (!s.tags.empty()) {
    w.key("tags").beginArray();
    for (const auto &[name, props] : s.tags) {
      w.beginObject().kv("format", name).key("props");
      writeProps(w, props);
      w.endObject();
    }
    w.endArray();
  }
  w.key("unsupported").beginArray();
  for (const auto &u : s.unsupported) w.value(u);
  w.endArray();
  w.key("audio").beginObject();
  w.kv("container", s.audio.container).kv("codec", s.audio.codec);
  w.kv("bitrate", s.audio.bitrate).kv("sampleRate", s.audio.sampleRate);
  w.kv("channels", s.audio.channels).kv("bitDepth", s.audio.bitDepth);
  w.kv("durationMs", s.audio.durationMs);
  w.endObject();
  w.key("tagFormats").beginArray();
  for (const auto &t : s.formats) w.value(t);
  w.endArray();
  w.key("pictures").beginArray();
  for (const auto &p : s.pictures) {
    w.beginObject();
    w.kv("mime", p.mime).kv("type", p.type).kv("desc", p.desc).kv("size", p.size).kv("hash", p.hash);
    w.endObject();
  }
  w.endArray();
}

// Picks the picture used as cover: "Front Cover" if present, else the first.
int coverIndex(const std::vector<PictureInfo> &pics) {
  for (size_t i = 0; i < pics.size(); i++)
    if (pics[i].type == "Front Cover") return static_cast<int>(i);
  return pics.empty() ? -1 : 0;
}

bool writeWhole(const std::string &path, const void *data, size_t len, std::string &err) {
  std::string tmp = path + "." + randomSuffix() + ".tmp";
  auto f = openPath(tmp, OpenMode::CreateNew, err);
  if (!f) return false;
  bool ok = f->pwrite(0, data, len);
  f.reset();
  if (!ok) {
    err = "write_failed";
    removeFile(tmp);
    return false;
  }
  if (!renameFile(tmp, path)) {
    err = "rename_failed";
    removeFile(tmp);
    return false;
  }
  return true;
}

bool readWhole(const std::string &path, std::string &out, std::string &err, uint64_t maxSize) {
  auto f = openPath(path, OpenMode::Read, err);
  if (!f) return false;
  int64_t sz = f->size();
  if (sz < 0 || static_cast<uint64_t>(sz) > maxSize) {
    err = "too_large";
    return false;
  }
  out.resize(static_cast<size_t>(sz));
  if (sz > 0 && f->pread(0, &out[0], out.size()) != sz) {
    err = "read_failed";
    return false;
  }
  return true;
}

std::string sniffMime(const std::string &d) {
  if (d.size() > 3 && static_cast<unsigned char>(d[0]) == 0xFF && static_cast<unsigned char>(d[1]) == 0xD8)
    return "image/jpeg";
  if (d.size() > 8 && d.compare(0, 8, "\x89PNG\r\n\x1a\n") == 0) return "image/png";
  if (d.size() > 12 && d.compare(0, 4, "RIFF") == 0 && d.compare(8, 4, "WEBP") == 0) return "image/webp";
  if (d.size() > 6 && d.compare(0, 3, "GIF") == 0) return "image/gif";
  if (d.size() > 2 && d.compare(0, 2, "BM") == 0) return "image/bmp";
  return "";
}

// ------------------------------------------------------------ stage/plan

// Streams the virtual file into a new file at path.
bool writeImage(OverlayStream &ov, const std::string &path, std::string &err) {
  removeFile(path);
  auto out = openPath(path, OpenMode::CreateNew, err);
  if (!out) return false;
  std::vector<char> buf(1 << 20);
  uint64_t off = 0;
  while (off < ov.size()) {
    size_t n = ov.readAt(off, buf.data(), buf.size());
    if (n == 0) {
      err = "read_failed";
      return false;
    }
    if (!out->pwrite(off, buf.data(), n)) {
      err = "stage_write_failed";
      return false;
    }
    off += n;
  }
  if (!out->sync()) {
    err = "stage_sync_failed";
    return false;
  }
  return true;
}

// Hash over the given ranges of a file, used to make sure a byte-level
// restore is only applied to exactly the bytes a write produced.
bool hashRanges(const std::function<size_t(uint64_t, void *, size_t)> &read,
                const std::vector<Range> &ranges, uint64_t &out) {
  uint64_t h = 1469598103934665603ULL;
  std::vector<char> buf(1 << 16);
  for (const auto &r : ranges) {
    uint64_t done = 0;
    while (done < r.len) {
      size_t n = static_cast<size_t>(std::min<uint64_t>(buf.size(), r.len - done));
      if (read(r.start + done, buf.data(), n) != n) return false;
      h = fnv1a64(buf.data(), n, h);
      done += n;
    }
  }
  out = h;
  return true;
}

// Backup format: one JSON header line, then a blob.
//   {"v":2,"origSize":N,"newSize":M,"origMtimeNs":T,
//    "segs":[[0,newOff,len],[1,blobOff,len],...],
//    "check":[[off,len],...],"checkHash":"..."}
// The original file is the concatenation of the segments: type 0 copies
// bytes from the *new* file, type 1 copies bytes from the blob. "check"
// lists the ranges of the new file that the write produced; their hash must
// match before a restore is applied.
bool writeBackup(OverlayStream &ov, int64_t origMtime, const std::string &path, std::string &err) {
  // Base runs in the order of the original file. TagLib only inserts,
  // removes and overwrites, so runs normally stay ordered; if they do not,
  // fall back to storing the reordered part literally.
  std::vector<OverlayStream::Kept> all = ov.basePieces(), kept;
  uint64_t next = 0;
  for (const auto &k : all) {
    if (k.boff < next) continue;
    kept.push_back(k);
    next = k.boff + k.len;
  }
  JsonWriter w;
  std::string blob;
  w.beginObject().kv("v", 2).kv("origSize", ov.baseSize()).kv("newSize", ov.size());
  w.kv("origMtimeNs", origMtime);
  w.key("segs").beginArray();
  uint64_t b = 0;
  auto literal = [&](uint64_t from, uint64_t to) -> bool {
    if (to <= from) return true;
    uint64_t len = to - from;
    size_t at = blob.size();
    blob.resize(at + static_cast<size_t>(len));
    if (ov.readBase(from, &blob[at], static_cast<size_t>(len)) != len) return false;
    w.beginArray().value(1).value(static_cast<uint64_t>(at)).value(len).endArray();
    return true;
  };
  for (const auto &k : kept) {
    if (!literal(b, k.boff)) {
      err = "backup_read_failed";
      return false;
    }
    w.beginArray().value(0).value(k.voff).value(k.len).endArray();
    b = k.boff + k.len;
  }
  if (!literal(b, ov.baseSize())) {
    err = "backup_read_failed";
    return false;
  }
  w.endArray();
  // Everything in the new file that is not a kept base run must be verified.
  std::vector<Range> check;
  {
    std::vector<OverlayStream::Kept> byV = kept;
    std::sort(byV.begin(), byV.end(), [](const auto &x, const auto &y) { return x.voff < y.voff; });
    uint64_t v = 0;
    for (const auto &k : byV) {
      if (k.voff > v) check.push_back(Range{v, k.voff - v});
      v = std::max(v, k.voff + k.len);
    }
    if (ov.size() > v) check.push_back(Range{v, ov.size() - v});
  }
  uint64_t h = 0;
  if (!hashRanges([&](uint64_t o, void *buf, size_t n) { return ov.readAt(o, buf, n); }, check, h)) {
    err = "backup_read_failed";
    return false;
  }
  w.key("check").beginArray();
  for (const auto &r : check) w.beginArray().value(r.start).value(r.len).endArray();
  w.endArray();
  w.kv("checkHash", hex16(h));
  w.endObject();
  std::string out = w.str() + "\n" + blob;
  removeFile(path);
  return writeWhole(path, out.data(), out.size(), err);
}

struct Compare {
  bool ok = true;
  std::string why;
  void failIf(bool c, const std::string &w) {
    if (c && ok) {
      ok = false;
      why = w;
    }
  }
};

std::string sideStagePath(const char *path) {
  return joinPath(dirName(path), ".mm-" + randomSuffix() + ".tmp");
}

char *prepareWrite(const char *path, int fd, const char *name, const char *requestJson) {
  Json req;
  if (!requestJson || !Json::parse(requestJson, req)) return fail("bad_request");
  Opened o;
  std::string err;
  if (!openTarget(path, fd, name, false, o, err)) return fail(err);
  const std::string ext = lowerExt(o.name);
  const int64_t origSize = o.base->size();
  const int64_t origMtime = o.base->mtimeNs();
  if (req.has("expectSize") && req["expectSize"].i64() != origSize)
    return fail("file_changed_since_read");
  if (req.has("expectMtimeNs") && req["expectMtimeNs"].i64() != origMtime)
    return fail("file_changed_since_read");

  OverlayStream ov(o.base.get(), o.name);
  Snapshot before, after;
  std::vector<std::string> rejected;
  std::map<std::string, std::string> joinedKeys;  // multi-values stored joined
  bool coverChanged = false;
  std::string newCoverHash;
  const std::string action = req["cover"]["action"].str("keep");
  {
    FileRef ref(&ov, true, AudioProperties::Average);
    File *f = ref.file();
    if (!f || !f->isValid()) return fail("unsupported_or_corrupt");
    before = snapshot(f, ext);

    // Nothing to do when every requested value is already there.
    if (action == "keep") {
      bool same = true;
      for (const auto &[k, v] : req["set"].obj) {
        auto it = before.props.find(u8(fromU8(k).upper()));
        std::vector<std::string> want;
        for (const auto &item : v.arr) want.push_back(item.str());
        if (want.empty() ? it != before.props.end() : (it == before.props.end() || it->second != want))
          same = false;
      }
      if (same) {
        JsonWriter w;
        w.beginObject().kv("ok", true).kv("mode", "noop");
        writeSnapshot(w, before);
        w.endObject();
        return dup(w.str());
      }
    }

    // ---- text properties, applied to each tag on its own property set.
    // The primary tag is created when missing; it is then seeded with the
    // values visible before (e.g. from ID3v1 / RIFF INFO / DIIN) so that the
    // new tag does not hide them. Secondary tags are only updated.
    const Json &set = req["set"];
    const std::string joiner = req["multiSeparator"].str("; ");
    TagSet ts = collectTags(f, true);
    const bool primaryNew =
        !ts.targets.empty() &&
        std::find(ts.existing.begin(), ts.existing.end(), ts.targets[0]) == ts.existing.end();
    auto apply = [&](PropertyMap pm) {
      for (const auto &[k, v] : set.obj) {
        String key = fromU8(k);
        if (v.type != Json::Array || v.arr.empty()) {
          pm.erase(key);
        } else {
          StringList vals;
          for (const auto &item : v.arr) vals.append(fromU8(item.str()));
          pm.replace(key, vals);
        }
      }
      return pm;
    };
    // Tags that cannot hold several values for a key (ASF Author, ID3v1,
    // RIFF INFO, ...) get the values joined with the configured separator.
    auto setOn = [&](auto *t, PropertyMap base, bool primary) {
      PropertyMap rej = t->setProperties(apply(base));
      PropertyMap now = t->properties();
      PropertyMap fix;
      for (const auto &[k, v] : set.obj) {
        if (v.type != Json::Array || v.arr.size() < 2) continue;
        String key = fromU8(k).upper();
        if (rej.contains(key) || !now.contains(key) || now[key].size() == v.arr.size()) continue;
        std::string joined;
        for (size_t i = 0; i < v.arr.size(); i++) joined += (i ? joiner : "") + v.arr[i].str();
        fix.replace(key, StringList(fromU8(joined)));
      }
      if (!fix.isEmpty()) {
        PropertyMap pm = t->properties();
        for (const auto &[k, v] : fix) pm.replace(k, v);
        t->setProperties(pm);
      }
      if (primary) {
        for (const auto &[k, _] : rej) rejected.push_back(u8(k));
        for (const auto &[k, v] : fix) joinedKeys[u8(k)] = u8(v.front());
      }
    };
    if (!set.obj.empty() || primaryNew) {
      if (ts.targets.empty()) {
        setOn(f, f->properties(), true);
      } else {
        for (size_t i = 0; i < ts.targets.size(); i++) {
          Tag *t = ts.targets[i];
          setOn(t, (i == 0 && primaryNew) ? f->properties() : t->properties(), i == 0);
        }
      }
    }

    // ---- cover
    if (action == "remove") {
      if (!before.pictures.empty()) {
        f->setComplexProperties("PICTURE", List<VariantMap>());
        coverChanged = true;
      }
    } else if (action == "set") {
      std::string img;
      if (!readWhole(req["cover"]["path"].str(), img, err, 32u << 20)) return fail("cover_" + err);
      std::string mime = sniffMime(img);
      if (mime.empty()) return fail("cover_unsupported_image");
      ByteVector data(img.data(), static_cast<unsigned int>(img.size()));
      newCoverHash = pictureHash(data);
      VariantMap pic;
      pic.insert("data", data);
      pic.insert("mimeType", String(mime));
      pic.insert("description", String());
      pic.insert("pictureType", String("Front Cover"));
      // Keep the other pictures (back cover, artist, ...): only the front
      // cover is replaced.
      // The replaced picture is the one shown as cover (see coverIndex):
      // every "Front Cover", or else the first picture.
      List<VariantMap> l;
      l.append(pic);
      const List<VariantMap> old = f->complexProperties("PICTURE");
      bool hasFront = false;
      for (const auto &p : old)
        if (p.value("pictureType").toString() == "Front Cover") hasFront = true;
      bool skippedFirst = false;
      for (const auto &p : old) {
        if (hasFront ? p.value("pictureType").toString() == "Front Cover" : !skippedFirst) {
          skippedFirst = true;
          continue;
        }
        l.append(p);
      }
      if (!f->setComplexProperties("PICTURE", l)) return fail("cover_unsupported_by_format");
      coverChanged = true;
    }

    if (!saveFile(f)) return fail("taglib_save_failed");
  }

  bool changed = ov.modified();
  if (changed && ov.size() == ov.baseSize() && ov.baseIsIdentity()) {
    // TagLib re-renders tags even when nothing changed; compare the bytes.
    changed = false;
    std::vector<char> x, y;
    for (const auto &r : ov.dataRanges()) {
      x.resize(static_cast<size_t>(r.len));
      y.resize(static_cast<size_t>(r.len));
      if (ov.readAt(r.start, x.data(), x.size()) != x.size() ||
          ov.readBase(r.start, y.data(), y.size()) != y.size() || x != y) {
        changed = true;
        break;
      }
    }
  }
  if (!changed) {
    JsonWriter w;
    w.beginObject().kv("ok", true).kv("mode", "noop");
    writeSnapshot(w, before);
    w.endObject();
    return dup(w.str());
  }

  // ---- verification on the virtual result
  ov.setReadOnly(true);
  ov.seek(0);
  {
    FileRef ref(&ov, true, AudioProperties::Average);
    File *f = ref.file();
    if (!f || !f->isValid()) return fail("verify_reparse_failed");
    after = snapshot(f, ext);
  }
  Compare c;
  {
    const Json &set = req["set"];
    std::set<std::string> rej(rejected.begin(), rejected.end());
    std::set<std::string> edited;
    for (const auto &[k, v] : set.obj) {
      std::string key = u8(fromU8(k).upper());
      edited.insert(key);
      if (rej.count(key) || rej.count(k)) continue;
      auto it = after.props.find(key);
      if (v.arr.empty()) {
        c.failIf(it != after.props.end(), "verify_key_not_removed:" + key);
      } else {
        std::vector<std::string> want;
        auto j = joinedKeys.find(key);
        if (j != joinedKeys.end()) want.push_back(j->second);
        else
          for (const auto &item : v.arr) want.push_back(item.str());
        std::string got;
        if (it != after.props.end())
          for (const auto &x : it->second) got += (got.empty() ? "" : "|") + x;
        // Some formats order values themselves (ID3v2.3 TCON puts ID3v1
        // genre references first); the same set of values is accepted.
        bool same = it != after.props.end() && it->second == want;
        if (!same && it != after.props.end() && it->second.size() == want.size()) {
          std::vector<std::string> x = it->second, y = want;
          std::sort(x.begin(), x.end());
          std::sort(y.begin(), y.end());
          same = x == y;
        }
        c.failIf(!same, "verify_value_mismatch:" + key + "=" + got);
      }
    }
    // ASF stores the values of one attribute in up to three header objects,
    // so their order is not stable across saves; compare those as sets.
    const bool unordered = after.audio.container == "ASF";
    auto same = [unordered](std::vector<std::string> x, std::vector<std::string> y) {
      if (unordered) {
        std::sort(x.begin(), x.end());
        std::sort(y.begin(), y.end());
      }
      return x == y;
    };
    for (const auto &[k, v] : before.props) {
      if (edited.count(k)) continue;
      auto it = after.props.find(k);
      c.failIf(it == after.props.end() || !same(it->second, v), "verify_other_key_changed:" + k);
    }
    for (const auto &[k, v] : after.props) {
      if (edited.count(k)) continue;
      c.failIf(!before.props.count(k), "verify_unexpected_key:" + k);
    }
    {
      // Picture frames/items show up in the unsupported list of some formats.
      auto strip = [coverChanged](std::vector<std::string> u) {
        if (!coverChanged) return u;
        u.erase(std::remove_if(u.begin(), u.end(), [](const std::string &x) {
                  std::string l = x;
                  for (auto &ch : l) ch = static_cast<char>(tolower(static_cast<unsigned char>(ch)));
                  return l.rfind("apic", 0) == 0 || l.rfind("pic", 0) == 0 || l == "covr" ||
                         l.rfind("wm/picture", 0) == 0 || l.rfind("cover art", 0) == 0 ||
                         l == "metadata_block_picture";
                }),
                u.end());
        return u;
      };
      c.failIf(strip(before.unsupported) != strip(after.unsupported),
               "verify_unsupported_data_changed");
    }
    c.failIf(!(before.audio == after.audio), "verify_audio_properties_changed");
    if (!coverChanged) {
      c.failIf(before.pictures.size() != after.pictures.size(), "verify_picture_count_changed");
      for (size_t i = 0; c.ok && i < before.pictures.size(); i++)
        c.failIf(before.pictures[i].hash != after.pictures[i].hash, "verify_picture_changed");
    } else if (action == "remove") {
      c.failIf(!after.pictures.empty(), "verify_picture_not_removed");
    } else {
      int ci = coverIndex(after.pictures);
      c.failIf(ci < 0 || after.pictures[static_cast<size_t>(ci)].hash != newCoverHash,
               "verify_picture_not_set");
    }
  }
  std::string audioCheck = "properties";
  if (c.ok) {
    Reader rb{[&](uint64_t off, void *b, size_t n) { return ov.readBase(off, b, n); }, ov.baseSize()};
    Reader rn{[&](uint64_t off, void *b, size_t n) { return ov.readAt(off, b, n); }, ov.size()};
    AudioRegions ab = locateAudio(rb, ext), an = locateAudio(rn, ext);
    c.failIf(ab.kind != an.kind, "verify_audio_layout_changed");
    if (c.ok && ab.kind == RegionKind::Ranges) {
      c.failIf(ab.ranges.size() != an.ranges.size(), "verify_audio_layout_changed");
      for (size_t i = 0; c.ok && i < ab.ranges.size(); i++) {
        c.failIf(ab.ranges[i].len != an.ranges[i].len, "verify_audio_size_changed");
        c.failIf(c.ok && !ov.mapsBase(an.ranges[i].start, ab.ranges[i].start, ab.ranges[i].len),
                 "verify_audio_bytes_changed");
      }
      audioCheck = "bytes";
    } else if (c.ok && ab.kind == RegionKind::OggHash) {
      c.failIf(ab.hash != an.hash || ab.hashedBytes != an.hashedBytes, "verify_audio_bytes_changed");
      audioCheck = "packets";
    }
  }
  if (!c.ok) return fail("verification_failed", c.why);

  // ---- backup + staging
  const std::string backupPath = req["backupPath"].str();
  if (!backupPath.empty() && !writeBackup(ov, origMtime, backupPath, err))
    return fail("backup_failed", err);

  const bool patch = ov.size() == ov.baseSize() && ov.baseIsIdentity();
  // A desktop rewrite is committed by atomically replacing the file, so its
  // stage must live in the same directory (same volume) as the target.
  std::string stagePath = req["stagePath"].str();
  if (fd < 0 && (!patch || stagePath.empty())) stagePath = sideStagePath(path);
  if (stagePath.empty()) return fail("stage_path_required");

  JsonWriter w;
  w.beginObject().kv("ok", true);
  if (patch) {
    std::vector<Range> ranges = ov.dataRanges();
    std::string blob;
    w.kv("mode", "patch");
    w.key("patches").beginArray();
    for (const auto &r : ranges) {
      size_t at = blob.size();
      blob.resize(at + static_cast<size_t>(r.len));
      if (ov.readAt(r.start, &blob[at], static_cast<size_t>(r.len)) != r.len)
        return fail("stage_read_failed");
      w.beginArray().value(r.start).value(r.len).value(static_cast<uint64_t>(at)).endArray();
    }
    w.endArray();
    removeFile(stagePath);
    if (!writeWhole(stagePath, blob.data(), blob.size(), err)) return fail("stage_failed", err);
  } else {
    w.kv("mode", "rewrite");
    if (!writeImage(ov, stagePath, err)) {
      removeFile(stagePath);
      return fail("stage_failed", err);
    }
  }
  const bool keepMtime = req["keepMtime"].boolean(true);
  w.kv("stagePath", stagePath).kv("backupPath", backupPath);
  w.kv("expectSize", origSize).kv("expectMtimeNs", origMtime).kv("newSize", ov.size());
  w.kv("setMtimeNs", keepMtime ? origMtime : static_cast<int64_t>(0));
  w.kv("audioCheck", audioCheck);
  w.key("rejected").beginArray();
  for (const auto &r : rejected) w.value(r);
  w.endArray();
  w.key("joined").beginArray();
  for (const auto &[k, _] : joinedKeys) w.value(k);
  w.endArray();
  writeSnapshot(w, after);
  w.endObject();
  return dup(w.str());
}

// Applies a plan. Without "force" the file must still have the size and
// modification time it had at prepare time; crash recovery passes force to
// roll an interrupted commit forward (every mode is idempotent).
char *commit(const char *path, int fd, const char *planJson) {
  Json plan;
  if (!planJson || !Json::parse(planJson, plan)) return fail("bad_plan");
  const std::string mode = plan["mode"].str();
  if (mode == "noop") return dup("{\"ok\":true}");
  const std::string stagePath = plan["stagePath"].str();
  const int64_t expectSize = plan["expectSize"].i64(-1);
  const int64_t expectMtime = plan["expectMtimeNs"].i64();
  const int64_t newSize = plan["newSize"].i64(-1);
  const int64_t setMtime = plan["setMtimeNs"].i64();
  const bool force = plan["force"].boolean(false);
  std::string err;

  auto done = [&](BaseFile *f, bool already) {
    JsonWriter w;
    w.beginObject().kv("ok", true);
    if (already) w.kv("already", true);
    if (f) w.kv("size", f->size()).kv("mtimeNs", f->mtimeNs());
    w.endObject();
    return dup(w.str());
  };

  if (mode == "rewrite" && fd < 0) {
    if (!path) return fail("no_path");
    if (!fileExists(stagePath)) {
      // Already committed (crash after the replace)?
      auto cur = openPath(path, OpenMode::Read, err);
      if (cur && cur->size() == newSize) return done(cur.get(), true);
      return fail("stage_missing");
    }
    {
      auto cur = openPath(path, OpenMode::Read, err);
      if (!cur) return fail(err);
      if (!force && (cur->size() != expectSize || cur->mtimeNs() != expectMtime))
        return fail("file_changed_since_prepare");
    }
    {
      // Make sure nobody else has the file open for writing (Windows).
      auto probe = openPath(path, OpenMode::ReadWrite, err);
      if (!probe) return fail(err);
    }
    copyPermissions(path, stagePath);
    if (!replaceFile(path, stagePath, err)) return fail("replace_failed", err);
    auto f = openPath(path, OpenMode::ReadWrite, err);
    if (f && setMtime > 0) f->setMtimeNs(setMtime);
    return done(f.get(), false);
  }

  Opened o;
  if (!openTarget(path, fd, nullptr, true, o, err)) return fail(err);
  auto stage = openPath(stagePath, OpenMode::Read, err);
  if (!stage) return fail("stage_missing", err);

  if (mode == "patch") {
    if (o.base->size() != expectSize) return fail("file_changed_since_prepare");
    if (!force && o.base->mtimeNs() != expectMtime) return fail("file_changed_since_prepare");
    std::vector<char> buf;
    for (const auto &p : plan["patches"].arr) {
      if (p.arr.size() != 3) return fail("bad_plan");
      uint64_t off = static_cast<uint64_t>(p.arr[0].i64());
      size_t len = static_cast<size_t>(p.arr[1].i64());
      uint64_t at = static_cast<uint64_t>(p.arr[2].i64());
      buf.resize(len);
      if (stage->pread(at, buf.data(), len) != static_cast<int64_t>(len)) return fail("stage_read_failed");
      if (!o.base->pwrite(off, buf.data(), len)) return fail("write_failed");
    }
  } else if (mode == "rewrite") {
    if (!force && (o.base->size() != expectSize || o.base->mtimeNs() != expectMtime))
      return fail("file_changed_since_prepare");
    int64_t total = stage->size();
    if (total != newSize) return fail("stage_size_mismatch");
    std::vector<char> buf(1 << 20);
    int64_t off = 0;
    while (off < total) {
      int64_t n = stage->pread(static_cast<uint64_t>(off), buf.data(), buf.size());
      if (n <= 0) return fail("stage_read_failed");
      if (!o.base->pwrite(static_cast<uint64_t>(off), buf.data(), static_cast<size_t>(n)))
        return fail("write_failed");
      off += n;
    }
    if (!o.base->truncate(static_cast<uint64_t>(total))) return fail("truncate_failed");
  } else {
    return fail("bad_plan");
  }
  if (!o.base->sync()) return fail("sync_failed");
  if (setMtime > 0) o.base->setMtimeNs(setMtime);
  return done(o.base.get(), false);
}

char *prepareRestore(const char *path, int fd, const char *name, const char *requestJson) {
  Json req;
  if (!requestJson || !Json::parse(requestJson, req)) return fail("bad_request");
  std::string err, bk;
  if (!readWhole(req["backupPath"].str(), bk, err, 1ull << 31)) return fail("backup_" + err);
  size_t nl = bk.find('\n');
  Json head;
  if (nl == std::string::npos || !Json::parse(bk.substr(0, nl), head)) return fail("backup_corrupt");
  if (head["v"].i64() != 2) return fail("backup_unsupported_version");
  const char *blob = bk.data() + nl + 1;
  const size_t blobLen = bk.size() - nl - 1;

  Opened o;
  if (!openTarget(path, fd, name, false, o, err)) return fail(err);
  const int64_t curSize = o.base->size();
  const int64_t curMtime = o.base->mtimeNs();
  if (curSize != head["newSize"].i64()) return fail("file_changed_since_write");
  const int64_t origSize = head["origSize"].i64();

  // The bytes written back then must still be there.
  {
    std::vector<Range> check;
    for (const auto &r : head["check"].arr) {
      if (r.arr.size() != 2) return fail("backup_corrupt");
      check.push_back(Range{static_cast<uint64_t>(r.arr[0].i64()), static_cast<uint64_t>(r.arr[1].i64())});
    }
    uint64_t h = 0;
    BaseFile *bf = o.base.get();
    auto rd = [bf](uint64_t off, void *buf, size_t n) -> size_t {
      int64_t r = bf->pread(off, buf, n);
      return r < 0 ? 0 : static_cast<size_t>(r);
    };
    if (!hashRanges(rd, check, h)) return fail("read_failed");
    if (hex16(h) != head["checkHash"].str()) return fail("file_changed_since_write");
  }

  bool patch = curSize == origSize;
  uint64_t pos = 0;
  for (const auto &s : head["segs"].arr) {
    if (s.arr.size() != 3) return fail("backup_corrupt");
    if (s.arr[0].i64() == 0 && static_cast<uint64_t>(s.arr[1].i64()) != pos) patch = false;
    if (s.arr[0].i64() == 1 && static_cast<uint64_t>(s.arr[1].i64() + s.arr[2].i64()) > blobLen)
      return fail("backup_corrupt");
    pos += static_cast<uint64_t>(s.arr[2].i64());
  }
  if (static_cast<int64_t>(pos) != origSize) return fail("backup_corrupt");

  std::string stagePath = req["stagePath"].str();
  if (fd < 0 && (!patch || stagePath.empty())) stagePath = sideStagePath(path);
  if (stagePath.empty()) return fail("stage_path_required");

  JsonWriter w;
  w.beginObject().kv("ok", true);
  removeFile(stagePath);
  if (patch) {
    std::string stage;
    w.kv("mode", "patch").key("patches").beginArray();
    pos = 0;
    for (const auto &s : head["segs"].arr) {
      uint64_t len = static_cast<uint64_t>(s.arr[2].i64());
      if (s.arr[0].i64() == 1) {
        size_t at = stage.size();
        stage.append(blob + s.arr[1].i64(), static_cast<size_t>(len));
        w.beginArray().value(pos).value(len).value(static_cast<uint64_t>(at)).endArray();
      }
      pos += len;
    }
    w.endArray();
    if (!writeWhole(stagePath, stage.data(), stage.size(), err)) return fail("stage_failed", err);
  } else {
    w.kv("mode", "rewrite");
    auto out = openPath(stagePath, OpenMode::CreateNew, err);
    if (!out) return fail("stage_failed", err);
    std::vector<char> buf(1 << 20);
    pos = 0;
    for (const auto &s : head["segs"].arr) {
      uint64_t len = static_cast<uint64_t>(s.arr[2].i64());
      uint64_t src = static_cast<uint64_t>(s.arr[1].i64());
      if (s.arr[0].i64() == 1) {
        if (!out->pwrite(pos, blob + src, static_cast<size_t>(len))) return fail("stage_write_failed");
      } else {
        uint64_t copied = 0;
        while (copied < len) {
          size_t n = static_cast<size_t>(std::min<uint64_t>(buf.size(), len - copied));
          if (o.base->pread(src + copied, buf.data(), n) != static_cast<int64_t>(n))
            return fail("read_failed");
          if (!out->pwrite(pos + copied, buf.data(), n)) return fail("stage_write_failed");
          copied += n;
        }
      }
      pos += len;
    }
    if (!out->sync()) return fail("stage_sync_failed");
  }
  const bool keepMtime = req["keepMtime"].boolean(true);
  w.kv("stagePath", stagePath).kv("backupPath", "");
  w.kv("expectSize", curSize).kv("expectMtimeNs", curMtime).kv("newSize", origSize);
  w.kv("setMtimeNs", keepMtime ? head["origMtimeNs"].i64() : static_cast<int64_t>(0));
  w.endObject();
  return dup(w.str());
}

char *readFile(const char *path, int fd, const char *name, const char *optsJson) {
  Json opts;
  if (optsJson && *optsJson) Json::parse(optsJson, opts);
  Opened o;
  std::string err;
  if (!openTarget(path, fd, name, false, o, err)) return fail(err);
  const std::string ext = lowerExt(o.name);
  OverlayStream ov(o.base.get(), o.name);
  ov.setReadOnly(true);
  FileRef ref(&ov, true, AudioProperties::Average);
  File *f = ref.file();
  if (!f || !f->isValid()) return fail("unsupported_or_corrupt");
  List<VariantMap> raw;
  Snapshot s = snapshot(f, ext, &raw, opts["detail"].boolean(false));

  JsonWriter w;
  w.beginObject().kv("ok", true);
  w.kv("size", o.base->size()).kv("mtimeNs", o.base->mtimeNs());
  writeSnapshot(w, s);
  int ci = coverIndex(s.pictures);
  if (ci >= 0) {
    w.kv("coverHash", s.pictures[static_cast<size_t>(ci)].hash);
    const std::string thumbDir = opts["thumbDir"].str();
    if (!thumbDir.empty()) {
      std::string out = joinPath(thumbDir, s.pictures[static_cast<size_t>(ci)].hash + ".jpg");
      bool have = fileExists(out);
      if (!have) {
        ByteVector data = raw[static_cast<unsigned int>(ci)].value("data").toByteVector();
        int size = static_cast<int>(opts["thumbSize"].i64(256));
        std::string terr;
        have = makeThumb(reinterpret_cast<const unsigned char *>(data.data()), data.size(), out, size, terr);
      }
      w.kv("thumb", have);
    }
  }
  w.endObject();
  return dup(w.str());
}

char *extractPicture(const char *path, int fd, const char *name, int index, const char *outPath) {
  Opened o;
  std::string err;
  if (!openTarget(path, fd, name, false, o, err)) return fail(err);
  OverlayStream ov(o.base.get(), o.name);
  ov.setReadOnly(true);
  FileRef ref(&ov, false);
  File *f = ref.file();
  if (!f || !f->isValid()) return fail("unsupported_or_corrupt");
  List<VariantMap> pics = f->complexProperties("PICTURE");
  if (index < 0 || static_cast<unsigned int>(index) >= pics.size()) return fail("no_such_picture");
  ByteVector data = pics[static_cast<unsigned int>(index)].value("data").toByteVector();
  removeFile(outPath);
  if (!writeWhole(outPath, data.data(), data.size(), err)) return fail(err);
  JsonWriter w;
  w.beginObject().kv("ok", true).kv("size", static_cast<uint64_t>(data.size()));
  w.kv("mime", u8(pics[static_cast<unsigned int>(index)].value("mimeType").toString())).endObject();
  return dup(w.str());
}

template <typename F>
char *guarded(F f) {
  try {
    return f();
  } catch (const std::bad_alloc &) {
    return fail("out_of_memory");
  } catch (const std::exception &e) {
    return fail("exception", e.what());
  } catch (...) {
    return fail("exception");
  }
}

}  // namespace
}  // namespace mm

extern "C" {

void mm_free(char *p) { free(p); }

char *mm_version(void) { return mm::dup("mm_core 1.0 / TagLib 2.3.2"); }

char *mm_read(const char *path, int fd, const char *name, const char *opts) {
  return mm::guarded([&] { return mm::readFile(path, fd, name, opts); });
}

char *mm_extract_picture(const char *path, int fd, const char *name, int index, const char *out_path) {
  return mm::guarded([&] { return mm::extractPicture(path, fd, name, index, out_path); });
}

char *mm_prepare_write(const char *path, int fd, const char *name, const char *request) {
  return mm::guarded([&] { return mm::prepareWrite(path, fd, name, request); });
}

char *mm_commit(const char *path, int fd, const char *plan) {
  return mm::guarded([&] { return mm::commit(path, fd, plan); });
}

char *mm_prepare_restore(const char *path, int fd, const char *name, const char *request) {
  return mm::guarded([&] { return mm::prepareRestore(path, fd, name, request); });
}

char *mm_make_thumb(const char *image_path, const char *out_path, int size) {
  return mm::guarded([&]() -> char * {
    std::string data, err;
    if (!mm::readWhole(image_path, data, err, 64u << 20)) return mm::fail(err);
    if (!mm::makeThumb(reinterpret_cast<const unsigned char *>(data.data()), data.size(), out_path, size, err))
      return mm::fail("thumb_failed", err);
    return mm::dup("{\"ok\":true}");
  });
}

int mm_close_fd(int fd) { return mm::closeFd(fd); }

char *mm_copy_out(const char *path, int fd, const char *out_path) {
  return mm::guarded([&]() -> char * {
    mm::Opened o;
    std::string err;
    if (!mm::openTarget(path, fd, nullptr, false, o, err)) return mm::fail(err);
    if (!out_path) return mm::fail("no_out_path");
    std::string tmp = std::string(out_path) + ".part";
    mm::removeFile(tmp);
    auto out = mm::openPath(tmp, mm::OpenMode::CreateNew, err);
    if (!out) return mm::fail(err);
    std::vector<char> buf(1 << 20);
    uint64_t off = 0;
    while (true) {
      int64_t n = o.base->pread(off, buf.data(), buf.size());
      if (n < 0) return mm::fail("read_failed");
      if (n == 0) break;
      if (!out->pwrite(off, buf.data(), static_cast<size_t>(n))) return mm::fail("write_failed");
      off += static_cast<uint64_t>(n);
    }
    if (!out->sync()) return mm::fail("sync_failed");
    out.reset();
    mm::removeFile(out_path);
    if (!mm::renameFile(tmp, out_path)) return mm::fail("rename_failed");
    mm::JsonWriter w;
    w.beginObject().kv("ok", true).kv("size", off).endObject();
    return mm::dup(w.str());
  });
}

int mm_open_fd(const char *path, int writable) { return path ? mm::openFd(path, writable != 0) : -1; }

}  // extern "C"
