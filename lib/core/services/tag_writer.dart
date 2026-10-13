// Batch tag writing with the operation journal, undo and crash recovery.
//
// Every file goes through prepare (verified, nothing written) -> journal ->
// commit. The journal row of an item holds the plan between the two steps,
// so an interrupted commit can be rolled forward on the next start.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mm_native/mm_native.dart';

import '../model/tag_fields.dart';
import '../path/path_key.dart';
import 'core_context.dart';
import 'events.dart';

class TagEditRequest {
  final List<int> trackIds;

  /// Property key -> values; an empty list removes the key. Only the keys
  /// the user actually changed are present.
  final Map<String, List<String>> set;

  /// 'keep' | 'remove' | 'set'
  final String coverAction;
  final String? coverPath;

  const TagEditRequest({required this.trackIds, this.set = const {}, this.coverAction = 'keep', this.coverPath});

  Map<String, Object?> toJson() => {'set': set, 'cover': {'action': coverAction, 'path': coverPath}};

  factory TagEditRequest.fromJson(List<int> ids, Map<String, dynamic> j) => TagEditRequest(
        trackIds: ids,
        set: (j['set'] as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as List).cast<String>())),
        coverAction: (j['cover'] as Map?)?['action'] as String? ?? 'keep',
        coverPath: (j['cover'] as Map?)?['path'] as String?,
      );
}

/// Cancellation flag of the running job.
class CancelToken {
  bool cancelled = false;
}

String _sep = Platform.pathSeparator;

class TagWriter {
  final CoreContext ctx;
  TagWriter(this.ctx);

  int get _concurrency => (int.tryParse(ctx.setting(SettingKeys.ioConcurrency)) ?? 3).clamp(1, 4);

  /// Runs a tag write batch. Returns the batch id.
  Future<JobFinished> write(int jobId, TagEditRequest req, CancelToken cancel, {JobKind kind = JobKind.tagWrite}) async {
    final db = ctx.db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final options = {
      'request': req.toJson(),
      'wholeFileBackup': ctx.flag(SettingKeys.wholeFileBackup),
      'keepMtime': ctx.flag(SettingKeys.keepMtime),
      'separator': ctx.separator,
    };
    db.db.execute("INSERT INTO op_batch(kind, state, created_at, options_json, summary) VALUES('tag_write', 'running', ?, ?, ?)",
        [now, jsonEncode(options), jsonEncode({'count': req.trackIds.length, 'keys': req.set.keys.toList(), 'cover': req.coverAction})]);
    final batch = db.db.lastInsertRowId;
    db.transaction(() {
      final st = db.db.prepare("INSERT INTO op_item(batch_id, seq, track_id, before_json, after_json, state) VALUES(?, ?, ?, '{}', ?, 'pending')");
      for (var i = 0; i < req.trackIds.length; i++) {
        st.execute([batch, i, req.trackIds[i], jsonEncode(req.toJson())]);
      }
      st.close();
    });
    Directory(ctx.paths.batchDir(batch)).createSync(recursive: true);
    Directory(ctx.paths.stageDir).createSync(recursive: true);
    ctx.emit(const HistoryChanged());

    final failed = <ItemResult>[];
    final skipped = <ItemResult>[];
    var ok = 0, done = 0;
    final changed = <int>[];
    var lastEmit = DateTime.now();

    Future<void> one(int seq, int trackId) async {
      final f = ctx.fileOf(trackId);
      final label = f?.rel ?? '#$trackId';
      try {
        if (f == null) throw MmException('track_not_found');
        final r = await _writeItem(batch, seq, f, req.toJson(), options);
        if (r == null) {
          skipped.add(ItemResult(trackId, label, skipped: true, error: 'no_change'));
          _setItem(batch, seq, state: 'skipped', error: 'no_change');
        } else {
          ok++;
          changed.add(trackId);
        }
      } on MmException catch (e) {
        failed.add(ItemResult(trackId, label, error: e.detail == null ? e.code : '${e.code}: ${e.detail}'));
        _setItem(batch, seq, state: 'failed', error: e.code);
      } catch (e) {
        failed.add(ItemResult(trackId, label, error: e.toString()));
        _setItem(batch, seq, state: 'failed', error: e.toString());
      }
      done++;
      if (DateTime.now().difference(lastEmit).inMilliseconds > 100 || done == req.trackIds.length) {
        ctx.emit(JobProgress(jobId, kind, done, req.trackIds.length, label));
        ctx.emitRows(changed);
        changed.clear();
        lastEmit = DateTime.now();
      }
    }

    await _runPool(req.trackIds.length, _concurrency, cancel, (i) => one(i, req.trackIds[i]));
    ctx.emitRows(changed);
    if (cancel.cancelled) {
      db.db.execute("UPDATE op_item SET state = 'skipped', error = 'cancelled' WHERE batch_id = ? AND state = 'pending'", [batch]);
    }
    _finishBatch(batch, ok, skipped.length, failed.length);
    _trimWholeFileBackups();
    return JobFinished(
        jobId: jobId, kind: kind, batchId: batch, succeeded: ok, skipped: skipped, failed: failed, cancelled: cancel.cancelled);
  }

  void _finishBatch(int batch, int ok, int skipped, int failed) {
    final state = failed == 0 ? (ok == 0 ? 'skipped' : 'done') : (ok == 0 ? 'failed' : 'partial');
    final s = jsonDecode(ctx.db.db.select('SELECT summary FROM op_batch WHERE id = ?', [batch]).first['summary'] as String? ?? '{}')
        as Map<String, dynamic>;
    s.addAll({'ok': ok, 'skipped': skipped, 'failed': failed});
    ctx.db.db.execute('UPDATE op_batch SET state = ?, finished_at = ?, summary = ? WHERE id = ?',
        [state, DateTime.now().millisecondsSinceEpoch, jsonEncode(s), batch]);
    ctx.emit(const HistoryChanged());
  }

  void _setItem(int batch, int seq, {String? state, String? error, String? step, String? before, String? after, String? plan, String? backup}) {
    final sets = <String>[];
    final args = <Object?>[];
    void add(String col, Object? v) {
      sets.add('$col = ?');
      args.add(v);
    }

    if (state != null) add('state', state);
    if (error != null) add('error', error);
    if (step != null) add('step', step);
    if (before != null) add('before_json', before);
    if (after != null) add('after_json', after);
    if (plan != null) add('plan_json', plan);
    if (backup != null) add('backup_ref', backup);
    ctx.db.db.execute('UPDATE op_item SET ${sets.join(', ')} WHERE batch_id = ? AND seq = ?', [...args, batch, seq]);
  }

  /// Writes one file. Returns null if nothing had to change.
  Future<Map<String, dynamic>?> _writeItem(int batch, int seq,
      ({int id, int rootId, String rel, String? docId, int size, int mtime}) f, Map<String, Object?> request, Map<String, Object?> options) async {
    final root = ctx.root(f.rootId);
    final dir = ctx.paths.batchDir(batch);
    final set = (request['set'] as Map).cast<String, List>();
    final cover = (request['cover'] as Map).cast<String, Object?>();
    return ctx.pool.withFile(root, f.rel, f.docId, true, (w, h) async {
      final cur = (await w.call<Map>('read', {'handle': h})).cast<String, dynamic>();
      if (cur['ok'] != true) throw MmException(cur['error'] as String? ?? 'read_failed', cur['detail'] as String?);
      final props = (cur['props'] as Map).cast<String, dynamic>();
      final pictures = cur['pictures'] as List;
      final before = <String, Object?>{
        'rootId': f.rootId,
        'rel': f.rel,
        'props': {for (final k in set.keys) k.toUpperCase(): props[k.toUpperCase()]},
        'coverHash': cur['coverHash'],
      };
      if (cover['action'] != 'keep' && cur['coverHash'] != null) {
        // Keep the old front cover so that undo can put it back even when
        // the byte-level backup cannot be used any more.
        final idx = pictures.indexWhere((p) => (p as Map)['hash'] == cur['coverHash']);
        final out = '$dir$_sep$seq.cover';
        await w.call<Map>('extractPicture', {'handle': h, 'index': idx, 'out': out});
        before['coverBackup'] = out;
      }
      String? full;
      if (options['wholeFileBackup'] == true) {
        full = '$dir$_sep$seq.full';
        await w.call<Map>('copyOut', {'handle': h, 'out': full});
      }
      final backup = '$dir$_sep$seq.bak';
      final stage = '${ctx.paths.stageDir}$_sep$batch-$seq.stage';
      final plan = (await w.call<Map>('prepare', {
        'handle': h,
        'request': {
          'set': set,
          'cover': cover,
          'backupPath': backup,
          'stagePath': stage,
          'keepMtime': options['keepMtime'] == true,
          'multiSeparator': options['separator'],
          'expectSize': cur['size'],
          'expectMtimeNs': cur['mtimeNs'],
        },
      }))
          .cast<String, dynamic>();
      _setItem(batch, seq, before: jsonEncode(before));
      if (plan['mode'] == 'noop') return null;
      // Journal before touching the file.
      final slimPlan = Map.of(plan)..removeWhere((k, _) => k == 'props' || k == 'unsupported' || k == 'pictures' || k == 'tagFormats' || k == 'audio');
      _setItem(batch, seq,
          step: 'prepared', state: 'running', plan: jsonEncode(slimPlan), backup: jsonEncode({'bytes': backup, 'full': full}));
      await w.call<Map>('commit', {'handle': h, 'plan': slimPlan});
      final after = {
        'request': request,
        'result': {'props': plan['props'], 'pictures': (plan['pictures'] as List).map((p) => (p as Map)['hash']).toList()},
      };
      _setItem(batch, seq, step: 'committed', state: 'done', after: jsonEncode(after));
      final st = plan['stagePath'] as String?;
      if (st != null) _deleteQuiet(st);
      await _refresh(w, h, f.id, root.isSaf);
      return plan;
    });
  }

  /// Re-reads a written file and updates its database record.
  Future<void> _refresh(dynamic w, int h, int trackId, bool saf) async {
    final r = (await w.call<Map>('read', {'handle': h, 'thumbDir': ctx.paths.thumbDir, 'detail': true}) as Map).cast<String, dynamic>();
    if (r['ok'] != true) return;
    final cols = columnsFromRead(r, ctx.separator);
    var mtime = (r['mtimeNs'] as num).toInt();
    if (saf) mtime = mtime ~/ 1000000 * 1000000; // SAF reports milliseconds
    cols['size'] = r['size'];
    cols['mtime'] = mtime;
    final keys = cols.keys.toList();
    ctx.db.db.execute('UPDATE track SET ${keys.map((k) => '$k = ?').join(', ')} WHERE id = ?', [...cols.values, trackId]);
    final hash = r['coverHash'] as String?;
    if (hash != null) {
      ctx.db.db.execute('INSERT INTO cover(hash, thumb) VALUES(?, ?) ON CONFLICT(hash) DO UPDATE SET thumb = max(thumb, excluded.thumb)',
          [hash, r['thumb'] == true ? 1 : 0]);
    }
  }

  // ------------------------------------------------------------------ undo

  /// Undoes a tag write batch: byte-level restore when the file still has
  /// exactly the written state, otherwise the old values are written back.
  Future<JobFinished> undo(int jobId, int batchId, CancelToken cancel) async {
    final db = ctx.db;
    final b = db.db.select('SELECT kind, state FROM op_batch WHERE id = ?', [batchId]);
    if (b.isEmpty || b.first['kind'] != 'tag_write') throw MmException('not_undoable');
    if (b.first['state'] == 'undone') throw MmException('already_undone');
    final items = db.db.select(
        "SELECT seq, track_id, before_json, after_json, backup_ref FROM op_item WHERE batch_id = ? AND state = 'done' ORDER BY seq",
        [batchId]);
    db.db.execute("INSERT INTO op_batch(kind, undo_of, state, created_at, summary) VALUES('undo', ?, 'running', ?, ?)",
        [batchId, DateTime.now().millisecondsSinceEpoch, jsonEncode({'count': items.length, 'of': 'tag_write'})]);
    final undoBatch = db.db.lastInsertRowId;
    ctx.emit(const HistoryChanged());
    final failed = <ItemResult>[];
    final skipped = <ItemResult>[];
    var ok = 0, done = 0;
    final changed = <int>[];

    Future<void> one(int i) async {
      final it = items[i];
      final trackId = it['track_id'] as int;
      final seq = it['seq'] as int;
      final f = ctx.fileOf(trackId);
      final label = f?.rel ?? '#$trackId';
      db.db.execute("INSERT INTO op_item(batch_id, seq, track_id, before_json, after_json, state) VALUES(?, ?, ?, '{}', '{}', 'running')",
          [undoBatch, i, trackId]);
      try {
        if (f == null) throw MmException('track_not_found');
        final before = jsonDecode(it['before_json'] as String) as Map<String, dynamic>;
        final after = jsonDecode(it['after_json'] as String) as Map<String, dynamic>;
        final backup = jsonDecode(it['backup_ref'] as String? ?? '{}') as Map<String, dynamic>;
        final how = await _undoItem(f, before, after, backup, undoBatch, i);
        ok++;
        changed.add(trackId);
        db.db.execute("UPDATE op_item SET state = 'done', step = ? WHERE batch_id = ? AND seq = ?", [how, undoBatch, i]);
        db.db.execute("UPDATE op_item SET state = 'undone' WHERE batch_id = ? AND seq = ?", [batchId, seq]);
      } on MmException catch (e) {
        final err = e.detail == null ? e.code : '${e.code}: ${e.detail}';
        failed.add(ItemResult(trackId, label, error: err));
        db.db.execute("UPDATE op_item SET state = 'failed', error = ? WHERE batch_id = ? AND seq = ?", [err, undoBatch, i]);
      }
      done++;
      ctx.emit(JobProgress(jobId, JobKind.undo, done, items.length, label));
    }

    await _runPool(items.length, _concurrency, cancel, one);
    ctx.emitRows(changed);
    final remaining = db.db.select("SELECT count(*) AS n FROM op_item WHERE batch_id = ? AND state = 'done'", [batchId]).first['n'] as int;
    if (remaining == 0) db.db.execute("UPDATE op_batch SET state = 'undone' WHERE id = ?", [batchId]);
    final state = failed.isEmpty ? 'done' : (ok == 0 ? 'failed' : 'partial');
    db.db.execute('UPDATE op_batch SET state = ?, finished_at = ?, summary = ? WHERE id = ?', [
      state,
      DateTime.now().millisecondsSinceEpoch,
      jsonEncode({'count': items.length, 'of': 'tag_write', 'ok': ok, 'failed': failed.length}),
      undoBatch,
    ]);
    ctx.emit(const HistoryChanged());
    return JobFinished(jobId: jobId, kind: JobKind.undo, batchId: undoBatch, succeeded: ok, skipped: skipped, failed: failed);
  }

  Future<String> _undoItem(({int id, int rootId, String rel, String? docId, int size, int mtime}) f, Map<String, dynamic> before,
      Map<String, dynamic> after, Map<String, dynamic> backup, int undoBatch, int seq) async {
    final root = ctx.root(f.rootId);
    final stage = '${ctx.paths.stageDir}$_sep$undoBatch-$seq.stage';
    Directory(ctx.paths.stageDir).createSync(recursive: true);
    return ctx.pool.withFile(root, f.rel, f.docId, true, (w, h) async {
      final cur = (await w.call<Map>('read', {'handle': h})).cast<String, dynamic>();
      if (cur['ok'] != true) throw MmException(cur['error'] as String? ?? 'read_failed');
      final result = after['result'] as Map<String, dynamic>?;
      final same = result != null &&
          _sameProps(cur['props'] as Map, result['props'] as Map) &&
          _sameList((cur['pictures'] as List).map((p) => (p as Map)['hash']).toList(), result['pictures'] as List);
      final bytes = backup['bytes'] as String?;
      if (same && bytes != null && File(bytes).existsSync()) {
        try {
          final plan = (await w.call<Map>('prepareRestore', {
            'handle': h,
            'request': {'backupPath': bytes, 'stagePath': stage, 'keepMtime': true},
          }))
              .cast<String, dynamic>();
          await w.call<Map>('commit', {'handle': h, 'plan': plan});
          final st = plan['stagePath'] as String?;
          if (st != null) _deleteQuiet(st);
          await _refresh(w, h, f.id, root.isSaf);
          return 'bytes';
        } on MmException catch (e) {
          if (e.code != 'file_changed_since_write') rethrow;
        }
      }
      // Write the previous values back (only the keys that were edited).
      final props = (before['props'] as Map).cast<String, dynamic>();
      final set = {for (final e in props.entries) e.key: e.value == null ? <String>[] : (e.value as List).cast<String>()};
      final request = (after['request'] as Map?)?.cast<String, dynamic>() ?? const {};
      final coverAction = (request['cover'] as Map?)?['action'] as String? ?? 'keep';
      Map<String, Object?> cover = {'action': 'keep'};
      if (coverAction != 'keep') {
        final old = before['coverBackup'] as String?;
        cover = old != null && File(old).existsSync() ? {'action': 'set', 'path': old} : {'action': 'remove'};
      }
      final plan = (await w.call<Map>('prepare', {
        'handle': h,
        'request': {
          'set': set,
          'cover': cover,
          'stagePath': stage,
          'keepMtime': ctx.flag(SettingKeys.keepMtime),
          'multiSeparator': ctx.separator,
          'expectSize': cur['size'],
          'expectMtimeNs': cur['mtimeNs'],
        },
      }))
          .cast<String, dynamic>();
      if (plan['mode'] != 'noop') {
        final slim = Map.of(plan)..removeWhere((k, _) => k == 'props' || k == 'unsupported' || k == 'pictures' || k == 'tagFormats' || k == 'audio');
        await w.call<Map>('commit', {'handle': h, 'plan': slim});
        final st = plan['stagePath'] as String?;
        if (st != null) _deleteQuiet(st);
      }
      await _refresh(w, h, f.id, root.isSaf);
      return 'values';
    });
  }

  static bool _sameProps(Map a, Map b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_sameList(a[k] as List, b[k] as List)) return false;
    }
    return true;
  }

  static bool _sameList(List a, List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // -------------------------------------------------------------- recovery

  /// Rolls interrupted commits forward (called at startup).
  Future<int> recover() async {
    final items = ctx.db.db.select(
        "SELECT i.batch_id, i.seq, i.track_id, i.plan_json FROM op_item i JOIN op_batch b ON b.id = i.batch_id "
        "WHERE i.step = 'prepared' AND i.state = 'running'");
    var n = 0;
    for (final it in items) {
      final f = ctx.fileOf(it['track_id'] as int);
      final batch = it['batch_id'] as int, seq = it['seq'] as int;
      if (f == null) {
        _setItem(batch, seq, state: 'failed', error: 'track_not_found');
        continue;
      }
      final plan = (jsonDecode(it['plan_json'] as String) as Map<String, dynamic>)..['force'] = true;
      try {
        await ctx.pool.withFile(ctx.root(f.rootId), f.rel, f.docId, true, (w, h) async {
          await w.call<Map>('commit', {'handle': h, 'plan': plan});
          await _refresh(w, h, f.id, ctx.root(f.rootId).isSaf);
        });
        _setItem(batch, seq, step: 'committed', state: 'done');
        n++;
      } on MmException catch (e) {
        _setItem(batch, seq, state: 'failed', error: 'recovery_failed: ${e.code}');
      }
    }
    ctx.db.db.execute("UPDATE op_batch SET state = 'partial' WHERE state = 'running' AND kind IN ('tag_write', 'undo')");
    // Stage files of finished items are garbage.
    final stage = Directory(ctx.paths.stageDir);
    if (stage.existsSync()) {
      for (final e in stage.listSync()) {
        _deleteQuiet(e.path);
      }
    }
    return n;
  }

  /// Removes the oldest whole-file backups above the configured limit.
  void _trimWholeFileBackups() {
    final limit = (int.tryParse(ctx.setting(SettingKeys.wholeFileBackupLimitMb)) ?? 5120) * 1024 * 1024;
    final dir = Directory(ctx.paths.backupDir);
    if (!dir.existsSync()) return;
    final files = dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.full')).toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    var total = 0;
    for (final f in files) {
      total += f.lengthSync();
      if (total > limit) _deleteQuiet(f.path);
    }
  }

  static void _deleteQuiet(String path) {
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // ignore
    }
  }
}

/// Runs [count] tasks with at most [parallel] in flight.
Future<void> _runPool(int count, int parallel, CancelToken cancel, Future<void> Function(int i) task) async {
  var next = 0;
  Future<void> lane() async {
    while (!cancel.cancelled) {
      final i = next++;
      if (i >= count) return;
      await task(i);
    }
  }

  await Future.wait(List.generate(parallel, (_) => lane()));
}

/// Display name of a path for summaries.
String labelOf(String rel) => relName(rel);
