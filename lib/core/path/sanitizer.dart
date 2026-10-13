// Cross-platform file name sanitizer. Applies the union of the Windows,
// macOS and Android rules so that every generated name is valid everywhere
// and the three platforms behave identically.
import 'dart:convert';

import 'package:characters/characters.dart';

import 'path_key.dart';

/// How characters that are illegal in file names are replaced.
enum IllegalCharMode {
  /// `: ? *` -> `： ？ ＊` (full-width look-alikes, keeps the text readable).
  fullWidth,

  /// Replaced with `_`.
  underscore,
}

/// Issues found while sanitizing (shown in the rename preview).
enum SanitizeIssue {
  illegalChars,
  trimmed,
  reservedName,
  truncated,
  empty,
}

class SanitizeResult {
  final String value;
  final Set<SanitizeIssue> issues;
  const SanitizeResult(this.value, this.issues);
  bool get changed => issues.isNotEmpty;
}

/// Maximum bytes of one path segment (ext4 / APFS / NTFS all allow 255
/// UTF-8 bytes or UTF-16 units; UTF-8 bytes is the strictest).
const int maxSegmentBytes = 255;

/// Windows MAX_PATH - 1. Longer paths work in this app (`\\?\`) but other
/// programs may fail to open them, so the preview warns.
const int windowsPathWarnLength = 259;

const _illegal = {
  0x5C: '＼', // \
  0x2F: '／', // /
  0x3A: '：', // :
  0x2A: '＊', // *
  0x3F: '？', // ?
  0x22: '＂', // "
  0x3C: '＜', // <
  0x3E: '＞', // >
  0x7C: '｜', // |
};

const _reserved = {
  'con', 'prn', 'aux', 'nul', //
  'com0', 'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'com¹', 'com²', 'com³',
  'lpt0', 'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
  'lpt¹', 'lpt²', 'lpt³',
};

/// Replaces illegal characters in a *value* before it is placed into a
/// template, so that e.g. "AC/DC" never creates a directory.
String replaceIllegal(String s, IllegalCharMode mode, [Set<SanitizeIssue>? issues]) {
  StringBuffer? out;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    String? rep;
    if (c < 0x20 || c == 0x7F) {
      rep = c == 0x09 ? ' ' : '_';
      if (c == 0x0A || c == 0x0D) rep = ' ';
    } else if (_illegal.containsKey(c)) {
      rep = mode == IllegalCharMode.fullWidth ? _illegal[c]! : '_';
    }
    if (rep != null) {
      out ??= StringBuffer(s.substring(0, i));
      out.write(rep);
      issues?.add(SanitizeIssue.illegalChars);
    } else {
      out?.writeCharCode(c);
    }
  }
  return out?.toString() ?? s;
}

int utf8Length(String s) {
  var n = 0;
  for (final r in s.runes) {
    n += r < 0x80 ? 1 : r < 0x800 ? 2 : r < 0x10000 ? 3 : 4;
  }
  return n;
}

/// Truncates at grapheme cluster boundaries so that the UTF-8 encoding is at
/// most [maxBytes] (never splits a character or an emoji sequence).
String truncateUtf8(String s, int maxBytes) {
  if (utf8Length(s) <= maxBytes) return s;
  final out = StringBuffer();
  var used = 0;
  for (final g in s.characters) {
    final n = utf8.encode(g).length;
    if (used + n > maxBytes) break;
    out.write(g);
    used += n;
  }
  return out.toString();
}

String _trimEnds(String s) {
  var a = 0, b = s.length;
  // Leading dots would make the file hidden on macOS / Android.
  while (a < b && (s.codeUnitAt(a) == 0x20 || s.codeUnitAt(a) == 0x2E || s.codeUnitAt(a) == 0x3000)) {
    a++;
  }
  // Windows strips trailing dots and spaces silently.
  while (b > a &&
      (s.codeUnitAt(b - 1) == 0x20 || s.codeUnitAt(b - 1) == 0x2E || s.codeUnitAt(b - 1) == 0x3000)) {
    b--;
  }
  return s.substring(a, b);
}

final _spaces = RegExp(r' {2,}');

bool isReservedWindowsName(String segment) {
  var stem = segment;
  final dot = stem.indexOf('.');
  if (dot >= 0) stem = stem.substring(0, dot);
  stem = stem.trimRight().toLowerCase();
  return _reserved.contains(stem);
}

/// Sanitizes one path segment (a directory name, or a file name when [ext]
/// is given: [ext] is kept intact and only the stem is shortened).
///
/// [reserveBytes] keeps room for a later conflict suffix such as " (12)".
SanitizeResult sanitizeSegment(
  String input, {
  String? ext,
  IllegalCharMode mode = IllegalCharMode.fullWidth,
  int reserveBytes = 0,
}) {
  final issues = <SanitizeIssue>{};
  var s = nfc(replaceIllegal(input, mode, issues));
  final collapsed = s.replaceAll(_spaces, ' ');
  final trimmed = _trimEnds(collapsed);
  if (trimmed != s) issues.add(SanitizeIssue.trimmed);
  s = trimmed;
  final suffix = (ext == null || ext.isEmpty) ? '' : '.${nfc(replaceIllegal(ext, mode, issues))}';
  if (s.isEmpty) {
    s = '_';
    issues.add(SanitizeIssue.empty);
  }
  final budget = maxSegmentBytes - utf8Length(suffix) - reserveBytes;
  if (utf8Length(s) > budget) {
    s = _trimEnds(truncateUtf8(s, budget < 1 ? 1 : budget));
    if (s.isEmpty) s = '_';
    issues.add(SanitizeIssue.truncated);
  }
  var full = '$s$suffix';
  if (isReservedWindowsName(full)) {
    s = '${s}_';
    full = '$s$suffix';
    issues.add(SanitizeIssue.reservedName);
  }
  return SanitizeResult(full, issues);
}

/// Adds " (n)" before the extension: `晴天.flac` -> `晴天 (2).flac`.
String withCounter(String fileName, int n) {
  final ext = extOf(fileName);
  final stem = ext.isEmpty ? fileName : fileName.substring(0, fileName.length - ext.length - 1);
  return ext.isEmpty ? '$stem ($n)' : '$stem ($n).${fileName.substring(fileName.length - ext.length)}';
}
