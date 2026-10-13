// Mapping between TagLib property maps and the normalized track columns.
import 'dart:convert';

/// Editable fields shown in the editor, in display order, with their
/// TagLib property keys.
enum TagField {
  title('TITLE'),
  artist('ARTIST'),
  album('ALBUM'),
  albumArtist('ALBUMARTIST'),
  trackNumber('TRACKNUMBER'),
  discNumber('DISCNUMBER'),
  date('DATE'),
  genre('GENRE'),
  composer('COMPOSER'),
  comment('COMMENT');

  final String key;
  const TagField(this.key);

  /// Fields whose values are lists (joined for display).
  bool get multiValued => this == artist || this == albumArtist || this == genre || this == composer;
}

int _int(String? s) {
  if (s == null) return 0;
  final m = RegExp(r'\d+').firstMatch(s);
  return m == null ? 0 : int.tryParse(m.group(0)!) ?? 0;
}

(int, int) parseNumberPair(List<String>? number, List<String>? total1, List<String>? total2) {
  final s = number == null || number.isEmpty ? '' : number.first;
  final parts = s.split('/');
  final n = _int(parts.first);
  var t = parts.length > 1 ? _int(parts[1]) : 0;
  if (t == 0 && total1 != null && total1.isNotEmpty) t = _int(total1.first);
  if (t == 0 && total2 != null && total2.isNotEmpty) t = _int(total2.first);
  return (n, t);
}

String yearOf(Map<String, List<String>> p) {
  for (final k in ['DATE', 'YEAR', 'ORIGINALDATE']) {
    final v = p[k];
    if (v == null || v.isEmpty) continue;
    final m = RegExp(r'\b(\d{4})\b').firstMatch(v.first) ?? RegExp(r'\d{4}').firstMatch(v.first);
    if (m != null) return m.group(1) ?? m.group(0)!;
  }
  return '';
}

/// Column values derived from a native read result (see MmNative.read).
/// [sep] joins multiple values for display.
Map<String, Object?> columnsFromRead(Map<String, dynamic> r, String sep) {
  final props = (r['props'] as Map<String, dynamic>? ?? const {})
      .map((k, v) => MapEntry(k, (v as List).cast<String>()));
  String j(String k) => (props[k] ?? const []).where((s) => s.isNotEmpty).join(sep);
  final (trackNo, trackTotal) = parseNumberPair(props['TRACKNUMBER'], props['TRACKTOTAL'], props['TOTALTRACKS']);
  final (discNo, discTotal) = parseNumberPair(props['DISCNUMBER'], props['DISCTOTAL'], props['TOTALDISCS']);
  final audio = r['audio'] as Map<String, dynamic>? ?? const {};
  final tags = r['tags'];
  return {
    'title': j('TITLE'),
    'artist': j('ARTIST'),
    'album': j('ALBUM'),
    'album_artist': j('ALBUMARTIST'),
    'track_no': trackNo,
    'track_total': trackTotal,
    'disc_no': discNo,
    'disc_total': discTotal,
    'year': yearOf(props),
    'genre': j('GENRE'),
    'composer': j('COMPOSER'),
    'comment': j('COMMENT'),
    'container': audio['container'] as String? ?? '',
    'codec': audio['codec'] as String? ?? '',
    'bitrate': (audio['bitrate'] as num?)?.toInt() ?? 0,
    'sample_rate': (audio['sampleRate'] as num?)?.toInt() ?? 0,
    'channels': (audio['channels'] as num?)?.toInt() ?? 0,
    'bit_depth': (audio['bitDepth'] as num?)?.toInt() ?? 0,
    'duration_ms': (audio['durationMs'] as num?)?.toInt() ?? 0,
    'tag_formats': ((r['tagFormats'] as List?) ?? const []).join(','),
    'props_json': jsonEncode(props),
    'tags_json': tags == null ? null : jsonEncode(tags),
    'pictures_json': jsonEncode(r['pictures'] ?? const []),
    'cover_hash': r['coverHash'] as String?,
  };
}

/// Display text of a multi-valued property.
String joinValues(List<String>? v, String sep) => (v ?? const []).where((s) => s.isNotEmpty).join(sep);

/// Splits user input back into values ("A; B" -> ["A", "B"]). The separator
/// is matched with or without surrounding spaces.
List<String> splitValues(String text, String sep) {
  final core = sep.trim();
  if (core.isEmpty) return text.trim().isEmpty ? const [] : [text.trim()];
  return text.split(core).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
}
