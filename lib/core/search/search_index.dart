// In-memory search and sort over all tracks. Runs inside the search
// isolate; pure Dart so it can be unit tested and benchmarked.
//
// Query syntax: whitespace separated terms, all must match (AND). A term
// matches if it is a substring of any searchable field, or - for latin
// terms - of the field's pinyin (full spelling or initials). "field:term"
// restricts a term to one field (title, artist, album, albumartist,
// composer, genre, file).
import 'dart:typed_data';

import '../model/track.dart';
import '../pinyin/pinyin.dart';
import 'normalize.dart';

enum SortField { artist, album, title, duration, year, genre, format, path, added }

const _fieldSep = '\u0001';
const _fieldNames = ['title', 'artist', 'album', 'albumartist', 'composer', 'genre', 'file'];
const _fieldAliases = {
  'title': 0, 't': 0, '标题': 0,
  'artist': 1, 'a': 1, '艺术家': 1, '歌手': 1,
  'album': 2, '专辑': 2,
  'albumartist': 3, 'aa': 3, '专辑艺术家': 3,
  'composer': 4, '作曲': 4,
  'genre': 5, 'g': 5, '流派': 5,
  'file': 6, 'f': 6, 'filename': 6, '文件': 6, '文件名': 6,
};

class _Doc {
  final TrackRow row;
  final String hay; // fields joined by _fieldSep
  final String py; // pinyin variants per field, '\u0001' separated, each field prefixed "<n>="
  _Doc(this.row, this.hay, this.py);
}

class _Term {
  final String text;
  final int field; // -1 = any
  final bool latin;
  _Term(this.text, this.field) : latin = RegExp(r'^[a-z0-9]+$').hasMatch(text);
}

class SearchIndex {
  final _docs = <int, _Doc>{};
  final _sortCache = <SortField, Int32List>{};

  int get length => _docs.length;
  Iterable<int> get ids => _docs.keys;
  TrackRow? row(int id) => _docs[id]?.row;

  void clear() {
    _docs.clear();
    _sortCache.clear();
  }

  void upsertAll(Iterable<TrackRow> rows) {
    for (final r in rows) {
      _docs[r.id] = _build(r);
    }
    _sortCache.clear();
  }

  void removeAll(Iterable<int> ids) {
    for (final id in ids) {
      _docs.remove(id);
    }
    _sortCache.clear();
  }

  static _Doc _build(TrackRow r) {
    final fields = [
      r.title,
      r.artist,
      r.album,
      r.albumArtist,
      r.composer,
      r.genre,
      r.relPath,
    ].map(searchNormalize).toList();
    final py = StringBuffer();
    for (var i = 0; i < fields.length; i++) {
      final f = fields[i];
      if (!hasHan(f)) continue;
      for (final v in pinyinVariants(f)) {
        py
          ..write(_fieldSep)
          ..write(i)
          ..write('=')
          ..write(v.replaceAll(' ', ''));
      }
    }
    return _Doc(r, fields.join(_fieldSep), py.toString());
  }

  static List<_Term> parse(String query) {
    final terms = <_Term>[];
    for (final raw in searchNormalize(query).split(RegExp(r'\s+'))) {
      if (raw.isEmpty) continue;
      final c = raw.indexOf(':');
      if (c > 0 && c < raw.length - 1) {
        final f = _fieldAliases[raw.substring(0, c)];
        if (f != null) {
          terms.add(_Term(raw.substring(c + 1), f));
          continue;
        }
      }
      terms.add(_Term(raw, -1));
    }
    return terms;
  }

  static bool _matches(_Doc d, _Term t) {
    if (t.field < 0) {
      if (d.hay.contains(t.text)) return true;
      // Pinyin entries are "\u0001<n>=<letters>"; the term may not span two.
      if (t.latin && d.py.isNotEmpty) {
        var from = 0;
        while (true) {
          final i = d.py.indexOf(t.text, from);
          if (i < 0) return false;
          final start = d.py.lastIndexOf(_fieldSep, i);
          final end = d.py.indexOf(_fieldSep, i);
          final entry = d.py.substring(start + 1, end < 0 ? d.py.length : end);
          if (entry.substring(entry.indexOf('=') + 1).contains(t.text)) return true;
          from = i + 1;
        }
      }
      return false;
    }
    final field = d.hay.split(_fieldSep)[t.field];
    if (field.contains(t.text)) return true;
    if (!t.latin || d.py.isEmpty) return false;
    final prefix = '${t.field}=';
    for (final e in d.py.split(_fieldSep)) {
      if (e.startsWith(prefix) && e.contains(t.text, prefix.length)) return true;
    }
    return false;
  }

  /// Track ids in [sort] order (cached until the next change).
  Int32List sorted(SortField sort) => _sortCache[sort] ??= _sort(sort);

  Int32List _sort(SortField sort) {
    final docs = _docs.values.toList();
    int byStr(String a, String b) {
      // Empty values last.
      if (a.isEmpty != b.isEmpty) return a.isEmpty ? 1 : -1;
      return a.compareTo(b);
    }

    final keys = <int, String>{};
    String key(TrackRow r, String Function(TrackRow) f) => sortKey(f(r));
    final albumKey = <int, String>{};
    String album(TrackRow r) => albumKey[r.id] ??= key(r, (x) => x.album);
    int albumOrder(TrackRow a, TrackRow b) {
      var c = byStr(album(a), album(b));
      if (c != 0) return c;
      c = a.discNo.compareTo(b.discNo);
      if (c != 0) return c;
      c = a.trackNo.compareTo(b.trackNo);
      if (c != 0) return c;
      return byStr(keys[a.id] ??= key(a, (x) => x.relPath), keys[b.id] ??= key(b, (x) => x.relPath));
    }

    final pathKeys = <int, String>{};
    String path(TrackRow r) => pathKeys[r.id] ??= sortKey(r.relPath);

    int Function(_Doc, _Doc) cmp;
    switch (sort) {
      case SortField.artist:
        final k = {for (final d in docs) d.row.id: sortKey(d.row.effectiveAlbumArtist)};
        cmp = (a, b) {
          final c = byStr(k[a.row.id]!, k[b.row.id]!);
          return c != 0 ? c : albumOrder(a.row, b.row);
        };
      case SortField.album:
        cmp = (a, b) => albumOrder(a.row, b.row);
      case SortField.title:
        final k = {for (final d in docs) d.row.id: sortKey(d.row.displayTitle)};
        cmp = (a, b) {
          final c = byStr(k[a.row.id]!, k[b.row.id]!);
          return c != 0 ? c : byStr(path(a.row), path(b.row));
        };
      case SortField.duration:
        cmp = (a, b) {
          final c = a.row.durationMs.compareTo(b.row.durationMs);
          return c != 0 ? c : byStr(path(a.row), path(b.row));
        };
      case SortField.year:
        cmp = (a, b) {
          final c = byStr(a.row.year, b.row.year);
          return c != 0 ? c : albumOrder(a.row, b.row);
        };
      case SortField.genre:
        final k = {for (final d in docs) d.row.id: sortKey(d.row.genre)};
        cmp = (a, b) {
          final c = byStr(k[a.row.id]!, k[b.row.id]!);
          return c != 0 ? c : albumOrder(a.row, b.row);
        };
      case SortField.format:
        cmp = (a, b) {
          final c = byStr(a.row.ext, b.row.ext);
          return c != 0 ? c : byStr(path(a.row), path(b.row));
        };
      case SortField.path:
        cmp = (a, b) {
          final c = a.row.rootId.compareTo(b.row.rootId);
          return c != 0 ? c : byStr(path(a.row), path(b.row));
        };
      case SortField.added:
        cmp = (a, b) => a.row.id.compareTo(b.row.id);
    }
    docs.sort(cmp);
    return Int32List.fromList([for (final d in docs) d.row.id]);
  }

  /// Ids matching [query], in [sort] order (reversed if [descending]).
  /// [within] (ids of a previous result, in the same order) narrows the
  /// scan when the new query extends the previous one.
  Int32List search(String query, SortField sort, {bool descending = false, Int32List? within}) {
    final terms = parse(query);
    Int32List base = within ?? sorted(sort);
    if (within == null && descending) base = Int32List.fromList(base.reversed.toList());
    if (terms.isEmpty) return within == null ? base : Int32List.fromList(within);
    final out = <int>[];
    for (final id in base) {
      final d = _docs[id];
      if (d == null) continue;
      var ok = true;
      for (final t in terms) {
        if (!_matches(d, t)) {
          ok = false;
          break;
        }
      }
      if (ok) out.add(id);
    }
    return Int32List.fromList(out);
  }

  /// True if every term of [next] contains the corresponding term of
  /// [prev] (so the results of [next] are a subset of those of [prev]).
  static bool narrows(String prev, String next) {
    final a = parse(prev), b = parse(next);
    if (a.isEmpty) return false;
    if (b.length < a.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].field != b[i].field || !b[i].text.contains(a[i].text)) return false;
    }
    return true;
  }

  static List<String> get fieldNames => _fieldNames;
}
