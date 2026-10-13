// State shared by the services that run in the core isolate.
import 'dart:io';

import '../db/database.dart';
import '../jobs/native_pool.dart';
import '../model/library_root.dart';
import '../model/track.dart';
import 'events.dart';

class CorePaths {
  final String dataDir;
  final String cacheDir;
  const CorePaths(this.dataDir, this.cacheDir);

  String get dbPath => '$dataDir${Platform.pathSeparator}library.db';
  String get thumbDir => '$cacheDir${Platform.pathSeparator}thumbs';
  String get backupDir => '$dataDir${Platform.pathSeparator}backups';
  String get stageDir => '$dataDir${Platform.pathSeparator}stage';

  String batchDir(int batch) => '$backupDir${Platform.pathSeparator}$batch';
}

/// Setting keys and defaults.
abstract final class SettingKeys {
  static const multiSeparator = 'multiSeparator';
  static const keepMtime = 'keepMtime';
  static const wholeFileBackup = 'wholeFileBackup';
  static const wholeFileBackupLimitMb = 'wholeFileBackupLimitMb';
  static const ioConcurrency = 'ioConcurrency';
  static const illegalChars = 'illegalChars';
  static const language = 'language';
  static const viewMode = 'viewMode';
  static const sort = 'sort';
  static const sortDesc = 'sortDesc';
  static const renameTemplate = 'renameTemplate';
  static const removeEmptyDirs = 'removeEmptyDirs';
  static const exportOptions = 'exportOptions';
  static const detailPanel = 'detailPanel';

  static const defaults = <String, String>{
    multiSeparator: '; ',
    keepMtime: 'true',
    wholeFileBackup: 'false',
    wholeFileBackupLimitMb: '5120',
    ioConcurrency: '3',
    illegalChars: 'fullWidth',
    language: 'system',
    viewMode: 'list',
    sort: 'artist',
    sortDesc: 'false',
    renameTemplate: '{albumartist|artist}/{album}/[{disc}-]{track:2} {title}.{ext}',
    removeEmptyDirs: 'true',
    detailPanel: 'true',
  };
}

class CoreContext {
  final AppDatabase db;
  final NativePool pool;
  final CorePaths paths;
  final void Function(CoreEvent e) emit;

  CoreContext(this.db, this.pool, this.paths, this.emit);

  String setting(String key) => db.getSetting(key) ?? SettingKeys.defaults[key] ?? '';
  bool flag(String key) => setting(key) == 'true';
  String get separator => setting(SettingKeys.multiSeparator);

  final _roots = <int, LibraryRoot>{};

  LibraryRoot root(int id) {
    final cached = _roots[id];
    if (cached != null) return cached;
    final r = db.db.select('SELECT id, kind, locator, display_path, last_scan_at FROM library_root WHERE id = ?', [id]);
    if (r.isEmpty) throw StateError('no root $id');
    final x = r.first;
    return _roots[id] = LibraryRoot(
      id: x['id'] as int,
      kind: RootKind.parse(x['kind'] as String),
      locator: x['locator'] as String,
      displayPath: x['display_path'] as String,
      lastScanAt: x['last_scan_at'] as int?,
    );
  }

  void invalidateRoots() => _roots.clear();

  List<LibraryRoot> roots() => [
        for (final x in db.db.select('SELECT id FROM library_root ORDER BY id')) root(x['id'] as int),
      ];

  /// File identity of a track for IO.
  ({int id, int rootId, String rel, String? docId, int size, int mtime})? fileOf(int trackId) {
    final r = db.db.select('SELECT id, root_id, rel_path, saf_doc_id, size, mtime FROM track WHERE id = ?', [trackId]);
    if (r.isEmpty) return null;
    final x = r.first;
    return (
      id: x['id'] as int,
      rootId: x['root_id'] as int,
      rel: x['rel_path'] as String,
      docId: x['saf_doc_id'] as String?,
      size: x['size'] as int,
      mtime: x['mtime'] as int,
    );
  }

  void emitRows(Iterable<int> ids) {
    final list = ids.toList();
    if (list.isEmpty) return;
    emit(RowsChanged(db.rowsByIds(list), const []));
  }

  void emitRemoved(List<int> ids) {
    if (ids.isNotEmpty) emit(RowsChanged(const <TrackRow>[], ids));
  }
}
