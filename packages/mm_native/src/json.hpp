// Minimal JSON writer/parser used at the FFI boundary.
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace mm {

// ---------------------------------------------------------------- writer
class JsonWriter {
 public:
  JsonWriter &beginObject() { sep(); out_ += '{'; first_.push_back(true); return *this; }
  JsonWriter &endObject() { out_ += '}'; first_.pop_back(); return *this; }
  JsonWriter &beginArray() { sep(); out_ += '['; first_.push_back(true); return *this; }
  JsonWriter &endArray() { out_ += ']'; first_.pop_back(); return *this; }
  JsonWriter &key(const std::string &k) {
    sep();
    str(k);
    out_ += ':';
    pendingValue_ = true;
    return *this;
  }
  JsonWriter &value(const std::string &v) { sep(); str(v); return *this; }
  JsonWriter &value(const char *v) { return v ? value(std::string(v)) : null(); }
  JsonWriter &value(bool v) { sep(); out_ += v ? "true" : "false"; return *this; }
  JsonWriter &value(int v) { return value(static_cast<int64_t>(v)); }
  JsonWriter &value(unsigned v) { return value(static_cast<int64_t>(v)); }
  JsonWriter &value(int64_t v) { sep(); out_ += std::to_string(v); return *this; }
  JsonWriter &value(uint64_t v) { sep(); out_ += std::to_string(v); return *this; }
  JsonWriter &value(double v) {
    sep();
    char buf[32];
    snprintf(buf, sizeof buf, "%.6g", v);
    out_ += buf;
    return *this;
  }
  JsonWriter &null() { sep(); out_ += "null"; return *this; }
  template <typename T>
  JsonWriter &kv(const std::string &k, const T &v) { key(k); return value(v); }

  const std::string &str() const { return out_; }

 private:
  void sep() {
    if (pendingValue_) { pendingValue_ = false; return; }
    if (!first_.empty()) {
      if (!first_.back()) out_ += ',';
      first_.back() = false;
    }
  }
  void str(const std::string &s) {
    out_ += '"';
    for (unsigned char c : s) {
      switch (c) {
        case '"': out_ += "\\\""; break;
        case '\\': out_ += "\\\\"; break;
        case '\n': out_ += "\\n"; break;
        case '\r': out_ += "\\r"; break;
        case '\t': out_ += "\\t"; break;
        default:
          if (c < 0x20) {
            char buf[8];
            snprintf(buf, sizeof buf, "\\u%04x", c);
            out_ += buf;
          } else {
            out_ += static_cast<char>(c);
          }
      }
    }
    out_ += '"';
  }
  std::string out_;
  std::vector<bool> first_;
  bool pendingValue_ = false;
};

// ---------------------------------------------------------------- parser
struct Json {
  enum Type { Null, Bool, Number, String, Array, Object } type = Null;
  bool b = false;
  double n = 0;
  std::string s;
  std::vector<Json> arr;
  std::map<std::string, Json> obj;

  const Json &operator[](const std::string &k) const {
    static const Json empty;
    auto it = obj.find(k);
    return it == obj.end() ? empty : it->second;
  }
  bool has(const std::string &k) const { return obj.count(k) > 0; }
  bool isNull() const { return type == Null; }
  std::string str(const std::string &def = "") const { return type == String ? s : def; }
  // Integers are parsed from the literal text: doubles cannot represent
  // nanosecond timestamps (> 2^53) exactly.
  int64_t i64(int64_t def = 0) const {
    if (type != Number) return def;
    if (s.find_first_of(".eE") == std::string::npos) return strtoll(s.c_str(), nullptr, 10);
    return static_cast<int64_t>(n);
  }
  bool boolean(bool def = false) const { return type == Bool ? b : def; }

  static bool parse(const std::string &text, Json &out) {
    size_t pos = 0;
    if (!parseValue(text, pos, out)) return false;
    skipWs(text, pos);
    return pos == text.size();
  }

 private:
  static void skipWs(const std::string &t, size_t &p) {
    while (p < t.size() && (t[p] == ' ' || t[p] == '\n' || t[p] == '\r' || t[p] == '\t')) p++;
  }
  static void appendUtf8(std::string &o, uint32_t cp) {
    if (cp < 0x80) {
      o += static_cast<char>(cp);
    } else if (cp < 0x800) {
      o += static_cast<char>(0xC0 | (cp >> 6));
      o += static_cast<char>(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
      o += static_cast<char>(0xE0 | (cp >> 12));
      o += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
      o += static_cast<char>(0x80 | (cp & 0x3F));
    } else {
      o += static_cast<char>(0xF0 | (cp >> 18));
      o += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
      o += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
      o += static_cast<char>(0x80 | (cp & 0x3F));
    }
  }
  static bool hex4(const std::string &t, size_t &p, uint32_t &v) {
    if (p + 4 > t.size()) return false;
    v = 0;
    for (int i = 0; i < 4; i++) {
      char c = t[p++];
      v <<= 4;
      if (c >= '0' && c <= '9') v |= c - '0';
      else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
      else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
      else return false;
    }
    return true;
  }
  static bool parseString(const std::string &t, size_t &p, std::string &o) {
    if (t[p] != '"') return false;
    p++;
    while (p < t.size()) {
      char c = t[p++];
      if (c == '"') return true;
      if (c != '\\') { o += c; continue; }
      if (p >= t.size()) return false;
      char e = t[p++];
      switch (e) {
        case '"': o += '"'; break;
        case '\\': o += '\\'; break;
        case '/': o += '/'; break;
        case 'b': o += '\b'; break;
        case 'f': o += '\f'; break;
        case 'n': o += '\n'; break;
        case 'r': o += '\r'; break;
        case 't': o += '\t'; break;
        case 'u': {
          uint32_t cp;
          if (!hex4(t, p, cp)) return false;
          if (cp >= 0xD800 && cp <= 0xDBFF && p + 6 <= t.size() && t[p] == '\\' && t[p + 1] == 'u') {
            p += 2;
            uint32_t lo;
            if (!hex4(t, p, lo)) return false;
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
          }
          appendUtf8(o, cp);
          break;
        }
        default: return false;
      }
    }
    return false;
  }
  static bool parseValue(const std::string &t, size_t &p, Json &out) {
    skipWs(t, p);
    if (p >= t.size()) return false;
    char c = t[p];
    if (c == '{') {
      out.type = Object;
      p++;
      skipWs(t, p);
      if (p < t.size() && t[p] == '}') { p++; return true; }
      while (p < t.size()) {
        skipWs(t, p);
        std::string k;
        if (!parseString(t, p, k)) return false;
        skipWs(t, p);
        if (p >= t.size() || t[p] != ':') return false;
        p++;
        Json v;
        if (!parseValue(t, p, v)) return false;
        out.obj[k] = std::move(v);
        skipWs(t, p);
        if (p < t.size() && t[p] == ',') { p++; continue; }
        if (p < t.size() && t[p] == '}') { p++; return true; }
        return false;
      }
      return false;
    }
    if (c == '[') {
      out.type = Array;
      p++;
      skipWs(t, p);
      if (p < t.size() && t[p] == ']') { p++; return true; }
      while (p < t.size()) {
        Json v;
        if (!parseValue(t, p, v)) return false;
        out.arr.push_back(std::move(v));
        skipWs(t, p);
        if (p < t.size() && t[p] == ',') { p++; continue; }
        if (p < t.size() && t[p] == ']') { p++; return true; }
        return false;
      }
      return false;
    }
    if (c == '"') { out.type = String; return parseString(t, p, out.s); }
    if (t.compare(p, 4, "true") == 0) { out.type = Bool; out.b = true; p += 4; return true; }
    if (t.compare(p, 5, "false") == 0) { out.type = Bool; out.b = false; p += 5; return true; }
    if (t.compare(p, 4, "null") == 0) { out.type = Null; p += 4; return true; }
    size_t start = p;
    while (p < t.size() && (isdigit(static_cast<unsigned char>(t[p])) || t[p] == '-' || t[p] == '+' ||
                            t[p] == '.' || t[p] == 'e' || t[p] == 'E'))
      p++;
    if (start == p) return false;
    out.type = Number;
    out.s = t.substr(start, p - start);
    out.n = strtod(out.s.c_str(), nullptr);
    return true;
  }
};

}  // namespace mm
