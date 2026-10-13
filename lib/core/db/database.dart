// SQLite storage. Every isolate that needs the database opens its own
// connection (WAL mode allows concurrent readers and one writer). Never
// used on the UI isolate.
import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../model/track.dart';

const int schemaVersion = 1;

const _schema = '''
CREATE TABLE library_root (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,              -- 'path' | 'bookmark' | 'saf'
  locator TEXT NOT NULL,           -- absolute path / SAF tree URI
  bookmark BLOB,                   -- macOS security-scoped bookmark
  display_path TEXT NOT NULL,
  added_at INTEGER NOT NULL,
  last_scan_at INTEGER,
  UNIQUE(kind, locator)
);

CREATE TABLE track (
  id INTEGER PRIMARY KEY,
  root_id INTEGER NOT NULL REFERENCES library_root(id) ON DELETE CASCADE,
  rel_path TEXT NOT NULL,          -- as on disk, '/' separated
  rel_path_key TEXT NOT NULL,      -- NFC + lower case
  file_name TEXT NOT NULL,
  ext TEXT NOT NULL,
  saf_doc_id TEXT,
  size INTEGER NOT NULL,
  mtime INTEGER NOT NULL,          -- ns since epoch
  status INTEGER NOT NULL DEFAULT 0,  -- TrackStatus
  error TEXT,
  title TEXT NOT NULL DEFAULT '', artist TEXT NOT NULL DEFAULT '',
  album TEXT NOT NULL DEFAULT '', album_artist TEXT NOT NULL DEFAULT '',
  track_no INTEGER NOT NULL DEFAULT 0, track_total INTEGER NOT NULL DEFAULT 0,
  disc_no INTEGER NOT NULL DEFAULT 0, disc_total INTEGER NOT NULL DEFAULT 0,
  year TEXT NOT NULL DEFAULT '', genre TEXT NOT NULL DEFAULT '',
  composer TEXT NOT NULL DEFAULT '', comment TEXT NOT NULL DEFAULT '',
  container TEXT NOT NULL DEFAULT '', codec TEXT NOT NULL DEFAULT '',
  bitrate INTEGER NOT NULL DEFAULT 0, sample_rate INTEGER NOT NULL DEFAULT 0,
  channels INTEGER NOT NULL DEFAULT 0, bit_depth INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  tag_formats TEXT NOT NULL DEFAULT '',
  props_json TEXT,                 -- all properties, multi-valued
  tags_json TEXT,                  -- per-tag properties
  pictures_json TEXT,
  cover_hash TEXT,
  scanned_at INTEGER,
  -- phase 2 (not written in v1)
  fingerprint TEXT, mb_recording_id TEXT, play_count INTEGER, last_played_at INTEGER,
  UNIQUE(root_id, rel_path_key)
);
CREATE INDEX track_cover ON track(cover_hash);

CREATE TABLE cover (
  hash TEXT PRIMARY KEY,
  mime TEXT, width INTEGER, height INTEGER,
  thumb INTEGER NOT NULL DEFAULT 0     -- 1 = <cache>/thumbs/<hash>.jpg exists
);

CREATE TABLE playlist (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_export_json TEXT
);
CREATE TABLE playlist_item (
  playlist_id INTEGER NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
  pos INTEGER NOT NULL,
  track_id INTEGER REFERENCES track(id) ON DELETE SET NULL,
  fallback_path TEXT,
  PRIMARY KEY (playlist_id, pos)
);
CREATE INDEX playlist_item_track ON playlist_item(track_id);

CREATE TABLE op_batch (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,              -- 'tag_write' | 'rename' | 'undo'
  undo_of INTEGER,
  state TEXT NOT NULL,             -- planned | running | done | partial | failed | undone
  created_at INTEGER NOT NULL,
  finished_at INTEGER,
  summary TEXT,                    -- JSON: counts, description
  options_json TEXT
);
CREATE TABLE op_item (
  batch_id INTEGER NOT NULL REFERENCES op_batch(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  track_id INTEGER,
  root_id INTEGER,
  before_json TEXT NOT NULL,
  after_json TEXT NOT NULL,
  step TEXT,                       -- rename: pending | temp | final; write: prepared | committed
  temp_name TEXT,
  plan_json TEXT,                  -- tag write plan (for roll-forward)
  backup_ref TEXT,                 -- byte backup file / whole-file backup
  state TEXT NOT NULL,             -- pending | running | done | skipped | failed | undone
  error TEXT,
  PRIMARY KEY (batch_id, seq)
);

CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT);
''';

class AppDatabase {
  final Database db;
  AppDatabase._(this.db);

  static AppDatabase open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA synchronous=NORMAL');
    db.execute('PRAGMA busy_timeout=10000');
    db.execute('PRAGMA foreign_keys=ON');
    db.execute('PRAGMA temp_store=MEMORY');
    final a = AppDatabase._(db);
    a._migrate();
    return a;
  }

  static AppDatabase memory() {
    final db = sqlite3.openInMemory();
    db.execute('PRAGMA foreign_keys=ON');
    final a = AppDatabase._(db);
    a._migrate();
    return a;
  }

  void _migrate() {
    final v = db.userVersion;
    if (v == schemaVersion) return;
    if (v == 0) {
      transaction(() {
        db.execute(_schema);
        db.userVersion = schemaVersion;
      });
      return;
    }
    throw StateError('Unknown database version $v');
  }

  void close() => db.close();

  T transaction<T>(T Function() body) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final r = body();
      db.execute('COMMIT');
      return r;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ------------------------------------------------------------ settings

  String? getSetting(String key) {
    final r = db.select('SELECT value FROM setting WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  void setSetting(String key, String? value) {
    if (value == null) {
      db.execute('DELETE FROM setting WHERE key = ?', [key]);
    } else {
      db.execute('INSERT INTO setting(key, value) VALUES(?, ?) '
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value', [key, value]);
    }
  }

  Map<String, String> allSettings() => {
        for (final r in db.select('SELECT key, value FROM setting')) r['key'] as String: r['value'] as String,
      };

  // ------------------------------------------------------------ tracks

  static const rowColumns = 'id, root_id, rel_path, title, artist, album, album_artist, track_no, '
      'disc_no, year, genre, composer, duration_ms, ext, codec, bitrate, sample_rate, bit_depth, '
      'size, cover_hash, status';

  static TrackRow rowFrom(Row r) => TrackRow(
        id: r.columnAt(0) as int,
        rootId: r.columnAt(1) as int,
        relPath: r.columnAt(2) as String,
        title: r.columnAt(3) as String,
        artist: r.columnAt(4) as String,
        album: r.columnAt(5) as String,
        albumArtist: r.columnAt(6) as String,
        trackNo: r.columnAt(7) as int,
        discNo: r.columnAt(8) as int,
        year: r.columnAt(9) as String,
        genre: r.columnAt(10) as String,
        composer: r.columnAt(11) as String,
        durationMs: r.columnAt(12) as int,
        ext: r.columnAt(13) as String,
        codec: r.columnAt(14) as String,
        bitrate: r.columnAt(15) as int,
        sampleRate: r.columnAt(16) as int,
        bitDepth: r.columnAt(17) as int,
        size: r.columnAt(18) as int,
        coverHash: r.columnAt(19) as String?,
        status: TrackStatus.of(r.columnAt(20) as int),
      );

  List<TrackRow> allRows() =>
      [for (final r in db.select('SELECT $rowColumns FROM track')) rowFrom(r)];

  List<TrackRow> rowsByIds(Iterable<int> ids) {
    final list = ids.toList();
    final out = <TrackRow>[];
    for (var i = 0; i < list.length; i += 500) {
      final chunk = list.sublist(i, i + 500 > list.length ? list.length : i + 500);
      final q = List.filled(chunk.length, '?').join(',');
      out.addAll(db.select('SELECT $rowColumns FROM track WHERE id IN ($q)', chunk).map(rowFrom));
    }
    return out;
  }

  TrackDetail? detail(int id) {
    final r = db.select('SELECT $rowColumns, props_json, tags_json, tag_formats, pictures_json, '
        'container, channels, track_total, disc_total, comment, mtime, error FROM track WHERE id = ?', [id]);
    if (r.isEmpty) return null;
    final x = r.first;
    final tags = <({String format, Map<String, List<String>> props})>[];
    final tj = x['tags_json'] as String?;
    if (tj != null && tj.isNotEmpty) {
      for (final t in jsonDecode(tj) as List) {
        final m = t as Map<String, dynamic>;
        tags.add((
          format: m['format'] as String,
          props: (m['props'] as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as List).cast<String>())),
        ));
      }
    }
    final pj = x['pictures_json'] as String?;
    return TrackDetail(
      row: rowFrom(x),
      props: decodeProps(x['props_json'] as String?),
      tags: tags,
      tagFormats: (x['tag_formats'] as String).split(',').where((s) => s.isNotEmpty).toList(),
      pictures: pj == null || pj.isEmpty
          ? const []
          : [for (final p in jsonDecode(pj) as List) PictureInfo.fromJson(p as Map<String, dynamic>)],
      container: x['container'] as String,
      channels: x['channels'] as int,
      trackTotal: x['track_total'] as int,
      discTotal: x['disc_total'] as int,
      comment: x['comment'] as String,
      mtimeNs: x['mtime'] as int,
      error: x['error'] as String?,
    );
  }
}
