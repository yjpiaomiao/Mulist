// The core isolate: owns a database connection and the native worker pool,
// answers small queries and runs file-changing jobs one at a time. The UI
// isolate talks to it through [CoreClient].
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:mm_native/mm_native.dart';

import '../db/database.dart';
import '../jobs/native_pool.dart';
import '../model/library_root.dart';
import '../model/tag_fields.dart';
import '../path/path_key.dart';
import '../storage/storage_backend.dart';
import 'core_context.dart';
import 'events.dart';
import 'playlists.dart';
import 'renamer.dart';
import 'tag_writer.dart';

class CoreError implements Exception {
  final String code;
  final String? detail;
  CoreError(this.code, [this.detail]);
  @override
  String toString() => detail == null ? code : '$code: $detail';
}

class HistoryEntry {
  final int id;
  final String kind;
  final int? undoOf;
  final String state;
  final int createdAt;
  final Map<String, dynamic> summary;
  final bool undoable;
  const HistoryEntry(this.id, this.kind, this.undoOf, this.state, this.createdAt, this.summary, this.undoable);
}

class HistoryItem {
  final int seq;
  final int? trackId;
  final Map<String, dynamic> before;
  final Map<String, dynamic> after;
  final String state;
  final String? error;
  const HistoryItem(this.seq, this.trackId, this.before, this.after, this.state, this.error);
}

class CoreClient {
  final SendPort _send;
  final ReceivePort _recv;
  final _pending = <int, Completer<Object?>>{};
  final _events = StreamController<CoreEvent>.broadcast();
  int _next = 0;

  CoreClient._(this._send, this._recv) {
    _recv.listen((m) {
      if (m is CoreEvent) {
        _events.add(m);
        return;
      }
      final (id, ok, value) = m as (int, bool, Object?);
      final c = _pending.remove(id);
      if (c == null) return;
      if (ok) {
        c.complete(value);
      } else {
        final (code, detail) = value as (String, String?);
        c.completeError(CoreError(code, detail));
      }
    });
  }

  Stream<CoreEvent> get events => _events.stream;

  static Future<CoreClient> start(CorePaths paths, RootIsolateToken? token) async {
    final recv = ReceivePort();
    final ready = Completer<SendPort>();
    late final StreamSubscription<dynamic> sub;
    final first = ReceivePort();
    sub = first.listen((m) {
      ready.complete(m as SendPort);
      sub.cancel();
      first.close();
    });
    await Isolate.spawn(_coreMain, (first.sendPort, recv.sendPort, paths, token), debugName: 'core');
    final client = CoreClient._(await ready.future, recv);
    await client.call<void>('init');
    return client;
  }

  Future<T> call<T>(String method, [Object? args]) {
    final id = _next++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send.send((id, method, args));
    return c.future.then((v) => v as T);
  }
}

Future<void> _coreMain((SendPort, SendPort, CorePaths, RootIsolateToken?) init) async {
  final (ready, out, paths, token) = init;
  if (token != null) BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  final port = ReceivePort();
  ready.send(port.sendPort);
  final server = _CoreServer(paths, token, out.send);
  port.listen((m) async {
    final (id, method, args) = m as (int, String, Object?);
    try {
      final r = await server.handle(method, args);
      out.send((id, true, r));
    } on CoreError catch (e) {
      out.send((id, false, (e.code, e.detail)));
    } on MmException catch (e) {
      out.send((id, false, (e.code, e.detail)));
    } on StorageException catch (e) {
      out.send((id, false, (e.code, e.detail)));
    } catch (e, st) {
      out.send((id, false, ('exception', '$e\n$st')));
    }
  });
}

class _Job {
  final int id;
  final JobKind kind;
  final CancelToken cancel = CancelToken();
  final Future<JobFinished> Function(_Job job) run;
  _Job(this.id, this.kind, this.run);
}

class _CoreServer {
  final CorePaths paths;
  final RootIsolateToken? token;
  final void Function(Object?) send;
  late final CoreContext ctx;
  late final TagWriter writer;
  late final Renamer renamer;
  late final Playlists playlists;
  final _queue = <_Job>[];
  _Job? _running;
  int _nextJob = 1;

  _CoreServer(this.paths, this.token, this.send);

  Future<Object?> handle(String method, Object? a) async {
    Map<String, Object?> m() => (a as Map).cast<String, Object?>();
    switch (method) {
      case 'init':
        for (final d in [paths.dataDir, paths.thumbDir, paths.backupDir, paths.stageDir]) {
          Directory(d).createSync(recursive: true);
        }
        final db = AppDatabase.open(paths.dbPath);
        final cores = Platform.numberOfProcessors;
        final pool = await NativePool.spawn(Platform.isAndroid ? 2 : (cores >= 8 ? 4 : 3), token);
        ctx = CoreContext(db, pool, paths, send);
        writer = TagWriter(ctx);
        renamer = Renamer(ctx);
        playlists = Playlists(ctx);
        // Finish what an earlier run left half done.
        await writer.recover();
        await renamer.recover();
        return null;

      // ------------------------------------------------------------ roots
      case 'roots':
        ctx.invalidateRoots();
        return ctx.roots();
      case 'addRoot':
        return _addRoot(m());
      case 'removeRoot':
        final id = a as int;
        final ids = [for (final x in ctx.db.db.select('SELECT id FROM track WHERE root_id = ?', [id])) x['id'] as int];
        ctx.db.db.execute('DELETE FROM library_root WHERE id = ?', [id]);
        ctx.invalidateRoots();
        ctx.emitRemoved(ids);
        send(const RootsChanged());
        return null;
      case 'setRootLocator':
        ctx.db.db.execute('UPDATE library_root SET locator = ? WHERE id = ?', [m()['locator'], m()['id']]);
        ctx.invalidateRoots();
        return null;
      case 'bookmarks':
        return {
          for (final x in ctx.db.db.select("SELECT id, bookmark FROM library_root WHERE kind = 'bookmark'"))
            x['id'] as int: x['bookmark'] as List<int>?,
        };
      case 'setBookmark':
        ctx.db.db.execute('UPDATE library_root SET bookmark = ? WHERE id = ?', [m()['bookmark'], m()['id']]);
        return null;
      case 'resolveTarget':
        return _resolveTarget(m());

      // ----------------------------------------------------------- tracks
      case 'detail':
        return ctx.db.detail(a as int);
      case 'editInfo':
        return _editInfo((a as List).cast<int>());
      case 'removeTracks':
        final ids = (a as List).cast<int>();
        ctx.db.transaction(() {
          for (final id in ids) {
            ctx.db.db.execute('DELETE FROM track WHERE id = ?', [id]);
          }
        });
        ctx.emitRemoved(ids);
        return null;
      case 'missingIds':
        return [for (final x in ctx.db.db.select('SELECT id FROM track WHERE status = 1')) x['id'] as int];
      case 'physicalPath':
        final f = ctx.fileOf(a as int);
        if (f == null) return null;
        final root = ctx.root(f.rootId);
        return root.isSaf ? null : '${root.locator}${Platform.pathSeparator}${f.rel.replaceAll('/', Platform.pathSeparator)}';
      case 'fileOf':
        final f = ctx.fileOf(a as int);
        return f == null ? null : {'rootId': f.rootId, 'rel': f.rel, 'docId': f.docId};

      // --------------------------------------------------------- settings
      case 'settings':
        return {...SettingKeys.defaults, ...ctx.db.allSettings()};
      case 'setSetting':
        final key = m()['key'] as String;
        final old = ctx.setting(key);
        ctx.db.setSetting(key, m()['value'] as String?);
        if (key == SettingKeys.multiSeparator && old != ctx.setting(key)) _rejoinDisplay();
        return null;

      // -------------------------------------------------------- playlists
      case 'playlists':
        return playlists.list();
      case 'playlistCreate':
        return playlists.create(m()['name'] as String, (m()['tracks'] as List).cast<int>());
      case 'playlistAdd':
        playlists.add(m()['id'] as int, (m()['tracks'] as List).cast<int>());
        return null;
      case 'playlistRename':
        playlists.rename(m()['id'] as int, m()['name'] as String);
        return null;
      case 'playlistDelete':
        playlists.delete(a as int);
        return null;
      case 'playlistItems':
        return playlists.items(a as int);
      case 'playlistTrackIds':
        return playlists.trackIdsOf(a as int);
      case 'playlistReorder':
        playlists.reorder(m()['id'] as int, (m()['positions'] as List).cast<int>());
        return null;
      case 'exportBuild':
        return playlists.build((m()['tracks'] as List).cast<int>(), ExportOptions.fromJson((m()['options'] as Map).cast()),
            targetPath: m()['target'] as String?);
      case 'exportToPath':
        return playlists.exportToPath((m()['tracks'] as List).cast<int>(), ExportOptions.fromJson((m()['options'] as Map).cast()),
            m()['path'] as String,
            playlistId: m()['playlist'] as int?);

      // ------------------------------------------------------------- jobs
      case 'tagWrite':
        final req = m();
        final ids = (req['tracks'] as List).cast<int>();
        final r = TagEditRequest.fromJson(ids, (req['request'] as Map).cast());
        return _enqueue(JobKind.tagWrite, (j) => writer.write(j.id, r, j.cancel));
      case 'retry':
        return _retry(a as int);
      case 'undo':
        final batch = a as int;
        final kind = ctx.db.db.select('SELECT kind FROM op_batch WHERE id = ?', [batch]).first['kind'];
        return _enqueue(JobKind.undo,
            (j) => kind == 'tag_write' ? writer.undo(j.id, batch, j.cancel) : renamer.undo(j.id, batch, j.cancel));
      case 'undoLast':
        final last = _history().where((h) => h.undoable).firstOrNull;
        if (last == null) throw CoreError('nothing_to_undo');
        return handle('undo', last.id);
      case 'renamePreview':
        return renamer.preview(a as RenameRequest);
      case 'rename':
        final items = (a as List).cast<RenamePreviewItem>();
        return _enqueue(JobKind.rename, (j) => renamer.execute(j.id, items, j.cancel));
      case 'cancel':
        final id = a as int;
        if (_running?.id == id) _running!.cancel.cancelled = true;
        _queue.removeWhere((j) => j.id == id);
        return null;
      case 'history':
        return _history();
      case 'historyItems':
        return [
          for (final x in ctx.db.db.select(
              'SELECT seq, track_id, before_json, after_json, state, error FROM op_item WHERE batch_id = ? ORDER BY seq LIMIT 2000', [a as int]))
            HistoryItem(x['seq'] as int, x['track_id'] as int?, jsonDecode(x['before_json'] as String) as Map<String, dynamic>,
                jsonDecode(x['after_json'] as String) as Map<String, dynamic>, x['state'] as String, x['error'] as String?),
        ];
      case 'clearHistory':
        // Keeps nothing that undo could still need, except running batches.
        ctx.db.db.execute("DELETE FROM op_batch WHERE state NOT IN ('running')");
        final dir = Directory(paths.backupDir);
        if (dir.existsSync()) {
          for (final e in dir.listSync()) {
            e.deleteSync(recursive: true);
          }
        }
        send(const HistoryChanged());
        return null;
      default:
        throw CoreError('unknown_method', method);
    }
  }

  LibraryRoot _addRoot(Map<String, Object?> a) {
    final kind = a['kind'] as String;
    final locator = a['locator'] as String;
    final ex = ctx.db.db.select('SELECT id FROM library_root WHERE kind = ? AND locator = ?', [kind, locator]);
    if (ex.isNotEmpty) return ctx.root(ex.first['id'] as int);
    ctx.db.db.execute('INSERT INTO library_root(kind, locator, display_path, bookmark, added_at) VALUES(?, ?, ?, ?, ?)',
        [kind, locator, a['display'] ?? locator, a['bookmark'], DateTime.now().millisecondsSinceEpoch]);
    final id = ctx.db.db.lastInsertRowId;
    send(const RootsChanged());
    return ctx.root(id);
  }

  /// Maps a target directory chosen for reorganizing onto (root, rel); a
  /// directory outside every root becomes a new root.
  Map<String, Object?> _resolveTarget(Map<String, Object?> a) {
    final kind = a['kind'] as String;
    final locator = a['locator'] as String;
    for (final r in ctx.roots()) {
      if (r.kind.name != kind) continue;
      final rel = _relInside(r, locator, a['docId'] as String?);
      if (rel != null) return {'rootId': r.id, 'rel': rel, 'added': false};
    }
    final r = _addRoot(a);
    return {'rootId': r.id, 'rel': '', 'added': true};
  }

  String? _relInside(LibraryRoot r, String locator, String? docId) {
    if (r.isSaf) {
      // Same provider and volume: compare tree document ids.
      String treeDoc(String uri) => Uri.decodeComponent(uri.split('/tree/').last.split('/').first);
      if (r.locator.split('/tree/').first != locator.split('/tree/').first) return null;
      final rootDoc = treeDoc(r.locator);
      final target = docId ?? treeDoc(locator);
      if (target == rootDoc) return '';
      final prefix = rootDoc.endsWith(':') ? rootDoc : '$rootDoc/';
      return target.startsWith(prefix) ? target.substring(prefix.length) : null;
    }
    final rootN = r.locator.replaceAll(r'\', '/').replaceAll(RegExp(r'/+$'), '');
    final tgtN = locator.replaceAll(r'\', '/').replaceAll(RegExp(r'/+$'), '');
    if (pathKey(rootN) == pathKey(tgtN)) return '';
    if (!pathKey(tgtN).startsWith('${pathKey(rootN)}/')) return null;
    return tgtN.substring(rootN.length + 1);
  }

  /// Values shown in the tag editor for [ids]: per field the common value
  /// (joined with the separator) or null when the tracks differ.
  Map<String, Object?> _editInfo(List<int> ids) {
    final sep = ctx.separator;
    final common = <String, String?>{};
    String? cover;
    var coverSame = true;
    var first = true;
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      for (final x in ctx.db.db.select(
          'SELECT props_json, cover_hash FROM track WHERE id IN (${List.filled(chunk.length, '?').join(',')})', chunk)) {
        final props = (jsonDecode(x['props_json'] as String? ?? '{}') as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, joinValues((v as List).cast<String>(), sep)));
        for (final f in TagField.values) {
          final v = props[f.key] ?? '';
          if (first) {
            common[f.key] = v;
          } else if (common[f.key] != null && common[f.key] != v) {
            common[f.key] = null;
          }
        }
        final h = x['cover_hash'] as String?;
        if (first) {
          cover = h;
        } else if (cover != h) {
          coverSame = false;
        }
        first = false;
      }
    }
    return {'fields': common, 'cover': coverSame ? cover : null, 'coverSame': coverSame};
  }

  List<HistoryEntry> _history() {
    final undone = <int>{};
    final rows = ctx.db.db.select('SELECT id, kind, undo_of, state, created_at, summary FROM op_batch ORDER BY id DESC LIMIT 500');
    for (final x in rows) {
      if (x['state'] == 'undone') undone.add(x['id'] as int);
    }
    return [
      for (final x in rows)
        HistoryEntry(
          x['id'] as int,
          x['kind'] as String,
          x['undo_of'] as int?,
          x['state'] as String,
          x['created_at'] as int,
          jsonDecode(x['summary'] as String? ?? '{}') as Map<String, dynamic>,
          (x['kind'] == 'tag_write' || x['kind'] == 'rename') &&
              (x['state'] == 'done' || x['state'] == 'partial') &&
              !undone.contains(x['id'] as int),
        ),
    ];
  }

  int _retry(int batch) {
    final b = ctx.db.db.select('SELECT kind, options_json FROM op_batch WHERE id = ?', [batch]);
    if (b.isEmpty || b.first['kind'] != 'tag_write') throw CoreError('not_retryable');
    final ids = [
      for (final x in ctx.db.db.select("SELECT track_id FROM op_item WHERE batch_id = ? AND state = 'failed'", [batch])) x['track_id'] as int,
    ];
    final opts = jsonDecode(b.first['options_json'] as String) as Map<String, dynamic>;
    final req = TagEditRequest.fromJson(ids, (opts['request'] as Map).cast());
    return _enqueue(JobKind.tagWrite, (j) => writer.write(j.id, req, j.cancel));
  }

  int _enqueue(JobKind kind, Future<JobFinished> Function(_Job) run) {
    final job = _Job(_nextJob++, kind, run);
    _queue.add(job);
    _pump();
    return job.id;
  }

  void _pump() {
    if (_running != null || _queue.isEmpty) return;
    final job = _running = _queue.removeAt(0);
    send(JobProgress(job.id, job.kind, 0, 0));
    job.run(job).then(send, onError: (Object e) {
      send(JobFinished(jobId: job.id, kind: job.kind, succeeded: 0, error: e is MmException ? e.code : e.toString()));
    }).whenComplete(() {
      _running = null;
      _pump();
    });
  }

  /// Display columns join multi-values with the separator: rebuild them
  /// from the stored properties when the separator changes.
  void _rejoinDisplay() {
    final sep = ctx.separator;
    final changed = <int>[];
    ctx.db.transaction(() {
      for (final x in ctx.db.db.select('SELECT id, props_json FROM track WHERE props_json IS NOT NULL')) {
        final props = (jsonDecode(x['props_json'] as String) as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as List).cast<String>()));
        ctx.db.db.execute('UPDATE track SET artist = ?, album_artist = ?, genre = ?, composer = ?, title = ?, album = ?, comment = ? WHERE id = ?', [
          joinValues(props['ARTIST'], sep),
          joinValues(props['ALBUMARTIST'], sep),
          joinValues(props['GENRE'], sep),
          joinValues(props['COMPOSER'], sep),
          joinValues(props['TITLE'], sep),
          joinValues(props['ALBUM'], sep),
          joinValues(props['COMMENT'], sep),
          x['id'],
        ]);
        changed.add(x['id'] as int);
      }
    });
    for (var i = 0; i < changed.length; i += 1000) {
      ctx.emitRows(changed.sublist(i, i + 1000 > changed.length ? changed.length : i + 1000));
    }
  }
}
