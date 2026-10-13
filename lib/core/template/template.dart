// Rename template engine.
//
//   {title}               variable
//   {track:2}             numeric variable padded to 2 digits ("03")
//   {albumartist|artist|Unknown}
//                         first non-empty alternative; an alternative that is
//                         not a variable name is literal text
//   [{disc}-]             optional section: dropped if any variable in it is
//                         empty
//   /                     directory separator
//   \{ \} \[ \] \| \\     literal characters
//
// Variable values are sanitized *before* they are inserted (a "/" inside a
// value never creates a directory); every resulting path segment is then
// sanitized as a whole (see sanitizer.dart).
import '../path/path_key.dart';
import '../path/sanitizer.dart';

const templateVariables = [
  'title',
  'artist',
  'album',
  'albumartist',
  'track',
  'tracktotal',
  'disc',
  'disctotal',
  'year',
  'genre',
  'composer',
  'ext',
  'filename',
];

class TemplateError implements Exception {
  final String message;
  final int offset;
  TemplateError(this.message, this.offset);
  @override
  String toString() => 'TemplateError($message at $offset)';
}

sealed class _Node {}

class _Text extends _Node {
  final String text;
  _Text(this.text);
}

class _Sep extends _Node {}

class _Alt {
  final String? variable;
  final int pad;
  final String literal;
  _Alt.variable(this.variable, this.pad) : literal = '';
  _Alt.literal(this.literal)
      : variable = null,
        pad = 0;
}

class _Var extends _Node {
  final List<_Alt> alts;
  _Var(this.alts);
}

class _Optional extends _Node {
  final List<_Node> children;
  _Optional(this.children);
}

/// Values for one track. Numbers are passed as strings ('' when unknown).
typedef TemplateValues = String Function(String variable);

class RenderedPath {
  /// '/'-separated relative path (sanitized).
  final String path;

  /// Variables referenced (outside optional sections) that had no value.
  final Set<String> missing;

  /// Sanitizer issues over all segments.
  final Set<SanitizeIssue> issues;

  const RenderedPath(this.path, this.missing, this.issues);
}

class RenameTemplate {
  final String source;
  final List<_Node> _nodes;

  RenameTemplate._(this.source, this._nodes);

  /// Parses [source]; throws [TemplateError] on syntax errors.
  factory RenameTemplate.parse(String source) {
    final p = _Parser(source);
    final nodes = p.parseSeq(topLevel: true);
    return RenameTemplate._(source, nodes);
  }

  /// True if the template contains a directory separator.
  bool get hasDirectories => _hasSep(_nodes);

  static bool _hasSep(List<_Node> nodes) =>
      nodes.any((n) => n is _Sep || (n is _Optional && _hasSep(n.children)));

  /// Renders the template. The last segment is a file name; its extension
  /// (everything after the last '.') is preserved when shortening.
  ///
  /// [fileExt] is the extension the file is expected to keep; if the
  /// rendered name ends with it, only the stem is shortened when too long.
  RenderedPath render(
    TemplateValues values, {
    String? fileExt,
    IllegalCharMode mode = IllegalCharMode.fullWidth,
    int reserveBytes = 6,
  }) {
    final missing = <String>{};
    final issues = <SanitizeIssue>{};
    final segments = <StringBuffer>[StringBuffer()];

    String valueOf(_Alt a, Set<String>? miss) {
      if (a.variable == null) return a.literal;
      var v = values(a.variable!).trim();
      if (v.isEmpty) {
        miss?.add(a.variable!);
        return '';
      }
      if (a.pad > 0) {
        final n = int.tryParse(v);
        if (n != null) v = n.toString().padLeft(a.pad, '0');
      }
      return replaceIllegal(v, mode, issues);
    }

    String varText(_Var v, Set<String>? miss) {
      final localMiss = <String>{};
      for (final a in v.alts) {
        final s = valueOf(a, localMiss);
        if (s.isNotEmpty) return s;
      }
      miss?.addAll(localMiss);
      return '';
    }

    // Returns false if an optional section must be dropped.
    bool emit(List<_Node> nodes, List<StringBuffer> segs, Set<String>? miss, {required bool optional}) {
      for (final n in nodes) {
        switch (n) {
          case _Text():
            segs.last.write(n.text);
          case _Sep():
            segs.add(StringBuffer());
          case _Var():
            final s = varText(n, optional ? null : miss);
            if (s.isEmpty && optional) return false;
            segs.last.write(s);
          case _Optional():
            final tmp = <StringBuffer>[StringBuffer()];
            if (emit(n.children, tmp, miss, optional: true)) {
              segs.last.write(tmp.first);
              for (final extra in tmp.skip(1)) {
                segs.add(extra);
              }
            }
        }
      }
      return true;
    }

    emit(_nodes, segments, missing, optional: false);

    final raw = segments.map((b) => b.toString()).toList();
    final out = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final isFile = i == raw.length - 1;
      var seg = raw[i];
      if (!isFile && seg.trim().isEmpty) {
        // An empty directory level ("{genre}/" without genre) collapses.
        continue;
      }
      SanitizeResult r;
      if (isFile) {
        final e = fileExt ?? extOf(seg);
        final hasExt = e.isNotEmpty && seg.toLowerCase().endsWith('.${e.toLowerCase()}') && seg.length > e.length + 1;
        final stem = hasExt ? seg.substring(0, seg.length - e.length - 1) : seg;
        final origExt = hasExt ? seg.substring(seg.length - e.length) : null;
        r = sanitizeSegment(stem, ext: origExt, mode: mode, reserveBytes: reserveBytes);
      } else {
        r = sanitizeSegment(seg, mode: mode);
      }
      issues.addAll(r.issues);
      out.add(r.value);
    }
    return RenderedPath(out.join('/'), missing, issues);
  }
}

class _Parser {
  final String s;
  int i = 0;
  _Parser(this.s);

  List<_Node> parseSeq({required bool topLevel}) {
    final nodes = <_Node>[];
    final text = StringBuffer();
    void flush() {
      if (text.isNotEmpty) {
        nodes.add(_Text(text.toString()));
        text.clear();
      }
    }

    while (i < s.length) {
      final c = s[i];
      if (c == '\\') {
        if (i + 1 >= s.length) throw TemplateError('dangling escape', i);
        text.write(s[i + 1]);
        i += 2;
      } else if (c == '{') {
        flush();
        nodes.add(_parseVar());
      } else if (c == '[') {
        flush();
        final start = i;
        i++;
        final children = parseSeq(topLevel: false);
        if (i >= s.length || s[i] != ']') throw TemplateError('unclosed [', start);
        i++;
        nodes.add(_Optional(children));
      } else if (c == ']') {
        if (topLevel) throw TemplateError('unexpected ]', i);
        break;
      } else if (c == '}') {
        throw TemplateError('unexpected }', i);
      } else if (c == '/') {
        flush();
        nodes.add(_Sep());
        i++;
      } else {
        text.write(c);
        i++;
      }
    }
    flush();
    return nodes;
  }

  _Var _parseVar() {
    final start = i;
    i++; // {
    final parts = <String>[];
    final cur = StringBuffer();
    while (true) {
      if (i >= s.length) throw TemplateError('unclosed {', start);
      final c = s[i];
      if (c == '\\' && i + 1 < s.length) {
        cur.write(s[i + 1]);
        i += 2;
        continue;
      }
      if (c == '}') {
        parts.add(cur.toString());
        i++;
        break;
      }
      if (c == '|') {
        parts.add(cur.toString());
        cur.clear();
        i++;
        continue;
      }
      if (c == '{' || c == '[' || c == ']') throw TemplateError('unexpected $c', i);
      cur.write(c);
      i++;
    }
    final alts = <_Alt>[];
    for (final p in parts) {
      final m = RegExp(r'^\s*([a-zA-Z]+)\s*(?::\s*(\d{1,2}))?\s*$').firstMatch(p);
      final name = m?.group(1)?.toLowerCase();
      if (name != null && templateVariables.contains(name)) {
        alts.add(_Alt.variable(name, int.tryParse(m!.group(2) ?? '') ?? 0));
      } else {
        if (alts.isEmpty && parts.length == 1) throw TemplateError('unknown variable "$p"', start);
        alts.add(_Alt.literal(p));
      }
    }
    return _Var(alts);
  }
}
