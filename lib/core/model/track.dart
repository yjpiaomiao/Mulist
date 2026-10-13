// Track data. [TrackRow] is the light record kept in memory for every track
// (list/grid rendering, search, sort); [TrackDetail] is loaded on demand.
import 'dart:convert';

enum TrackStatus {
  ok,
  missing,
  parseFailed;

  static TrackStatus of(int v) => v >= 0 && v < values.length ? values[v] : ok;
}

class TrackRow {
  final int id;
  final int rootId;

  /// Path relative to the library root, '/' separated, as on disk.
  final String relPath;
  final String title;
  final String artist;
  final String album;
  final String albumArtist;
  final int trackNo;
  final int discNo;
  final String year;
  final String genre;
  final String composer;
  final int durationMs;
  final String ext;
  final String codec;
  final int bitrate;
  final int sampleRate;
  final int bitDepth;
  final int size;
  final String? coverHash;
  final TrackStatus status;

  const TrackRow({
    required this.id,
    required this.rootId,
    required this.relPath,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.albumArtist = '',
    this.trackNo = 0,
    this.discNo = 0,
    this.year = '',
    this.genre = '',
    this.composer = '',
    this.durationMs = 0,
    this.ext = '',
    this.codec = '',
    this.bitrate = 0,
    this.sampleRate = 0,
    this.bitDepth = 0,
    this.size = 0,
    this.coverHash,
    this.status = TrackStatus.ok,
  });

  String get fileName {
    final i = relPath.lastIndexOf('/');
    return i < 0 ? relPath : relPath.substring(i + 1);
  }

  /// Title for display: the tag, else the file name without extension.
  String get displayTitle {
    if (title.isNotEmpty) return title;
    final n = fileName;
    final dot = n.lastIndexOf('.');
    return dot > 0 ? n.substring(0, dot) : n;
  }

  /// Album artist, else artist.
  String get effectiveAlbumArtist => albumArtist.isNotEmpty ? albumArtist : artist;
}

/// Everything stored about one track (detail panel, editor).
class TrackDetail {
  final TrackRow row;

  /// All tag properties as read (multi-valued), e.g. {"ARTIST": ["A","B"]}.
  final Map<String, List<String>> props;

  /// Each tag present in the file with its own properties (when known).
  final List<({String format, Map<String, List<String>> props})> tags;
  final List<String> tagFormats;
  final List<PictureInfo> pictures;
  final String container;
  final int channels;
  final int trackTotal;
  final int discTotal;
  final String comment;
  final int mtimeNs;
  final String? error;

  const TrackDetail({
    required this.row,
    this.props = const {},
    this.tags = const [],
    this.tagFormats = const [],
    this.pictures = const [],
    this.container = '',
    this.channels = 0,
    this.trackTotal = 0,
    this.discTotal = 0,
    this.comment = '',
    this.mtimeNs = 0,
    this.error,
  });
}

class PictureInfo {
  final String mime;
  final String type;
  final String description;
  final int size;
  final String hash;
  const PictureInfo({
    required this.mime,
    required this.type,
    required this.description,
    required this.size,
    required this.hash,
  });

  factory PictureInfo.fromJson(Map<String, dynamic> j) => PictureInfo(
        mime: j['mime'] as String? ?? '',
        type: j['type'] as String? ?? '',
        description: j['desc'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        hash: j['hash'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'mime': mime, 'type': type, 'desc': description, 'size': size, 'hash': hash};
}

Map<String, List<String>> decodeProps(String? json) {
  if (json == null || json.isEmpty) return {};
  final m = jsonDecode(json) as Map<String, dynamic>;
  return m.map((k, v) => MapEntry(k, (v as List).cast<String>()));
}
