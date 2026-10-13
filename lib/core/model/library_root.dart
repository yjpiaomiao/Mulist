enum RootKind {
  /// Plain absolute path (Windows, Linux).
  path,

  /// macOS security-scoped bookmark; [LibraryRoot.locator] is the path the
  /// bookmark resolved to.
  bookmark,

  /// Android SAF tree URI.
  saf;

  static RootKind parse(String s) => values.firstWhere((k) => k.name == s, orElse: () => path);
}

class LibraryRoot {
  final int id;
  final RootKind kind;
  final String locator;
  final String displayPath;
  final int? lastScanAt;

  const LibraryRoot({
    required this.id,
    required this.kind,
    required this.locator,
    required this.displayPath,
    this.lastScanAt,
  });

  bool get isSaf => kind == RootKind.saf;

  Map<String, Object?> toMap() => {
        'id': id,
        'kind': kind.name,
        'locator': locator,
        'displayPath': displayPath,
        'lastScanAt': lastScanAt,
      };

  factory LibraryRoot.fromMap(Map m) => LibraryRoot(
        id: m['id'] as int,
        kind: RootKind.parse(m['kind'] as String),
        locator: m['locator'] as String,
        displayPath: m['displayPath'] as String,
        lastScanAt: m['lastScanAt'] as int?,
      );
}

/// Extensions recognised as audio files.
const audioExtensions = {
  'mp3', 'mp2', 'flac', 'm4a', 'm4b', 'mp4', 'aac', 'alac', //
  'ogg', 'oga', 'opus', 'spx', 'wav', 'aif', 'aiff', 'aifc',
  'ape', 'wv', 'mpc', 'tta', 'wma', 'asf', 'dsf', 'dff',
};

/// Companion files that follow an audio file when it is renamed or moved
/// (same stem, different extension).
const companionExtensions = {
  'lrc', 'cue', 'jpg', 'jpeg', 'png', 'webp', 'txt', 'log', 'nfo', 'srt', 'ass', 'krc', 'qrc', 'xml',
};
