// Batch rename / reorganize: template preview with conflict detection, a
// two-phase executor (temporary names first, so chains and swaps such as
// A->B, B->A work), companion files, journal, undo and crash recovery.
import 'dart:convert';

import '../model/library_root.dart';
import '../model/track.dart';
import '../path/path_key.dart';
import '../path/sanitizer.dart';
import '../storage/backends.dart';
import '../storage/storage_backend.dart';
import '../template/template.dart';
import 'core_context.dart';
import 'events.dart';
import 'tag_writer.dart' show CancelToken;

enum ConflictPolicy { number, skip }

/// Issues shown in the preview.
abstract final class RenameFlag {
  static const unchanged = 'unchanged';
  static const sanitized = 'sanitized';
  static const conflict = 'conflict';
  static const numbered = 'numbered';
  static const longPath = 'longPath';
  static const missingFields = 'missingFields';
  static const extChanged = 'extChanged';
  static const manual = 'manual';
}

class RenameRequest {
  final List<int> trackIds;
  final String template;

  /// Where the template's sub-directories are created. Required when the
  /// template contains '/'; otherwise files are renamed in place.
  final int? targetRootId;
  final String targetRel;
  final ConflictPolicy policy;

  /// Manual edits from the preview: track id -> relative path (in the
  /// target root).
  final Map<int, String> overrides;
  final IllegalCharMode illegalChars;

  const RenameRequest({
    required this.trackIds,
    required this.template,
    this.targetRootId,
    this.targetRel = '',
    this.policy = ConflictPolicy.number,
    this.overrides = const {},
    this.illegalChars = IllegalCharMode.fullWidth,
  });
}

class RenamePreviewItem {
  final int trackId;
  final int fromRoot;
  final String fromRel;
  final int toRoot;
  final String toRel;
  final Set<String> flags;
  final List<String> missing;

  const RenamePreviewItem({
    required this.trackId,
    required this.fromRoot,
    required this.fromRel,
    required this.toRoot,
    required this.toRel,
    required this.flags,
    this.missing = const [],
  });

  bool get actionable => !flags.contains(RenameFlag.unchanged) && !flags.contains(RenameFlag.conflict);
  bool get hasProblem =>
      flags.contains(RenameFlag.conflict) ||
      flags.contains(RenameFlag.longPath) ||
      flags.contains(RenameFlag.missingFields) ||
      flags.contains(RenameFlag.extChanged);
}

class RenamePreview {
  final List<RenamePreviewItem> items;
  final String? templateError;
  final int elapsedMs;
  const RenamePreview(this.items, this.templateError, this.elapsedMs);
}

String _templateValue(TrackRow r, int trackTotal, int discTotal, String v) => switch (v) {
      'title' => r.title,
      'artist' => r.artist,
      'album' => r.album,
      'albumartist' => r.albumArtist,
      'track' => r.trackNo > 0 ? '${r.trackNo}' : '',
      'tracktotal' => trackTotal > 0 ? '$trackTotal' : '',
      'disc' => r.discNo > 0 ? '${r.discNo}' : '',
      'disctotal' => discTotal > 0 ? '$discTotal' : '',
      'year' => r.year,
      'genre' => r.genre,
      'composer' => r.composer,
      'ext' => r.ext,
      'filename' => stemOf(r.fileName),
      _ => '',
    };

class Renamer {
  final CoreContext ctx;
  Renamer(this.ctx);

  // --------------------------------------------------------------- preview

  RenamePreview preview(RenameRequest req) {
    final sw = Stopwatch()..start();
    RenameTemplate? tpl;
    String? tplError;
    try {
      tpl = RenameTemplate.parse(req.template);
    } on TemplateError catch (e) {
      tplError = '${e.message} @${e.offset}';
    }
    if (tpl != null && tpl.hasDirectories && req.targetRootId == null) tplError = 'target_required';
    if (tpl == null || tplError != null) return RenamePreview(const [], tplError, sw.elapsedMilliseconds);

    final rows = ctx.db.rowsByIds(req.trackIds);
    final byId = {for (final r in rows) r.id: r};
    final totals = <int, (int, int)>{};
    for (var i = 0; i < req.trackIds.length; i += 500) {
      final chunk = req.trackIds.sublist(i, i + 500 > req.trackIds.length ? req.trackIds.length : i + 500);
      for (final x in ctx.db.db.select(
          'SELECT id, track_total, disc_total FROM track WHERE id IN (${List.filled(chunk.length, '?').join(',')})', chunk)) {
        totals[x['id'] as int] = (x['track_total'] as int, x['disc_total'] as int);
      }
    }

    // Keys occupied by tracks that are not part of this batch.
    final moving = req.trackIds.toSet();
    final occupied = <String>{};
    final rootIds = {for (final r in rows) r.rootId, ?req.targetRootId};
    for (final rid in rootIds) {
      for (final x in ctx.db.db.select('SELECT id, rel_path_key FROM track WHERE root_id = ?', [rid])) {
        if (!moving.contains(x['id'] as int)) occupied.add('$rid|${x['rel_path_key']}');
      }
    }

    final items = <RenamePreviewItem>[];
    final claimed = <String>{};
    final targetBase = req.targetRel;
    for (final id in req.trackIds) {
      final r = byId[id];
      if (r == null) continue;
      final (tt, dt) = totals[id] ?? (0, 0);
      final flags = <String>{};
      final toRoot = tpl.hasDirectories ? req.targetRootId! : r.rootId;
      String toRel;
      var missing = <String>[];
      final manual = req.overrides[id];
      if (manual != null) {
        toRel = splitRel(manual).map((s) => sanitizeSegment(s, mode: req.illegalChars).value).join('/');
        flags.add(RenameFlag.manual);
      } else {
        final out = tpl.render((v) => _templateValue(r, tt, dt, v), fileExt: r.ext, mode: req.illegalChars);
        missing = out.missing.toList()..sort();
        if (missing.isNotEmpty) flags.add(RenameFlag.missingFields);
        if (out.issues.isNotEmpty) flags.add(RenameFlag.sanitized);
        toRel = tpl.hasDirectories ? relJoin(targetBase, out.path) : relJoin(relDir(r.relPath), out.path);
      }
      if (extOf(toRel) != r.ext) flags.add(RenameFlag.extChanged);
      if (toRoot == r.rootId && toRel == r.relPath) {
        flags.add(RenameFlag.unchanged);
        claimed.add('$toRoot|${pathKey(toRel)}');
        items.add(RenamePreviewItem(trackId: id, fromRoot: r.rootId, fromRel: r.relPath, toRoot: toRoot, toRel: toRel, flags: flags, missing: missing));
        continue;
      }
      var key = '$toRoot|${pathKey(toRel)}';
      final sameAsSelf = toRoot == r.rootId && pathKey(toRel) == pathKey(r.relPath); // case-only change
      if (!sameAsSelf && (occupied.contains(key) || claimed.contains(key))) {
        if (req.policy == ConflictPolicy.number) {
          final dir = relDir(toRel), name = relName(toRel);
          for (var n = 2; n < 10000; n++) {
            final cand = relJoin(dir, withCounter(name, n));
            final k = '$toRoot|${pathKey(cand)}';
            if (!occupied.contains(k) && !claimed.contains(k)) {
              toRel = cand;
              key = k;
              break;
            }
          }
          flags.add(RenameFlag.numbered);
        } else {
          flags.add(RenameFlag.conflict);
        }
      }
      if (!flags.contains(RenameFlag.conflict)) claimed.add(key);
      final root = ctx.root(toRoot);
      if (root.kind == RootKind.path && root.locator.length + 1 + toRel.length > windowsPathWarnLength) {
        flags.add(RenameFlag.longPath);
      }
      items.add(RenamePreviewItem(trackId: id, fromRoot: r.rootId, fromRel: r.relPath, toRoot: toRoot, toRel: toRel, flags: flags, missing: missing));
    }
    // Earlier items may have claimed a name that a later "unchanged" item
    // keeps; mark those as conflicts too.
    return RenamePreview(items, null, sw.elapsedMilliseconds);
  }

  // ------------------------------------------------------------- execution

  Future<JobFinished> execute(int jobId, List<RenamePreviewItem> plan, CancelToken cancel,
      {String kind = 'rename', int? undoOf, JobKind jobKind = JobKind.rename}) async {
    final items = plan.where((i) => i.actionable).toList();
    final db = ctx.db;
    db.db.execute('INSERT INTO op_batch(kind, undo_of, state, created_at, summary, options_json) VALUES(?, ?, ?, ?, ?, ?)', [
      kind,
      undoOf,
      'running',
      DateTime.now().millisecondsSinceEpoch,
      jsonEncode({'count': items.length}),
      jsonEncode({'removeEmptyDirs': ctx.flag(SettingKeys.removeEmptyDirs)}),
    ]);
    final batch = db.db.lastInsertRowId;
    ctx.emit(const HistoryChanged());

    // Companion files: same stem, different (non-audio) extension.
    final dirCache = <String, List<String>>{};
    final records = <_Item>[];
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      final f = ctx.fileOf(it.trackId);
      if (f == null) continue;
      final root = ctx.root(it.fromRoot);
      final dir = relDir(it.fromRel);
      final names = dirCache['${root.id}|$dir'] ??= await backendFor(root).list(root, dir);
      final stem = pathKey(stemOf(relName(it.fromRel)));
      final comps = [
        for (final n in names)
          if (n != relName(it.fromRel) &&
              pathKey(stemOf(n)) == stem &&
              extOf(n).isNotEmpty &&
              !audioExtensions.contains(extOf(n)) &&
              !n.startsWith('.'))
            n,
      ];
      records.add(_Item(i, it, f.docId, comps));
    }
    db.transaction(() {
      final st = db.db.prepare('INSERT INTO op_item(batch_id, seq, track_id, root_id, before_json, after_json, step, state) '
          "VALUES(?, ?, ?, ?, ?, ?, 'pending', 'pending')");
      for (final r in records) {
        st.execute([
          batch,
          r.seq,
          r.item.trackId,
          r.item.fromRoot,
          jsonEncode({'root': r.item.fromRoot, 'rel': r.item.fromRel, 'doc': r.docId, 'companions': r.companions}),
          jsonEncode({'root': r.item.toRoot, 'rel': r.item.toRel}),
        ]);
      }
      st.close();
    });

    final failed = <ItemResult>[];
    final skipped = <ItemResult>[];
    var ok = 0, done = 0;
    final total = records.length * 2;

    // Phase 1: every source gets a unique temporary name in its directory.
    for (final r in records) {
      if (cancel.cancelled) break;
      final root = ctx.root(r.item.fromRoot);
      final be = backendFor(root);
      final dir = relDir(r.item.fromRel);
      final tmpName = '.mm-$batch-${r.seq}.${extOf(r.item.fromRel)}';
      try {
        final moved = await be.move(root, r.item.fromRel, relJoin(dir, tmpName), docId: r.docId);
        r.tempRel = moved.relPath;
        r.docId = moved.docId ?? r.docId;
        for (var c = 0; c < r.companions.length; c++) {
          final name = r.companions[c];
          try {
            final m = await be.move(root, relJoin(dir, name), relJoin(dir, '.mm-$batch-${r.seq}-c$c.${_rawExt(name)}'));
            r.companionTemps[c] = m.relPath;
          } on StorageException catch (e) {
            r.warnings.add('companion $name: ${e.code}');
          }
        }
        db.db.execute("UPDATE op_item SET step = 'temp', temp_name = ?, state = 'running', after_json = json_set(after_json, '\$.companionTemps', json(?)) "
            'WHERE batch_id = ? AND seq = ?', [r.tempRel, jsonEncode(r.companionTemps.map((k, v) => MapEntry('$k', v))), batch, r.seq]);
      } on StorageException catch (e) {
        r.error = e.code;
        failed.add(ItemResult(r.item.trackId, r.item.fromRel, error: '${e.code}${e.detail == null ? '' : ': ${e.detail}'}'));
        db.db.execute("UPDATE op_item SET state = 'failed', error = ? WHERE batch_id = ? AND seq = ?", [e.code, batch, r.seq]);
      }
      done++;
      ctx.emit(JobProgress(jobId, jobKind, done, total, r.item.fromRel));
    }

    // Phase 2: temporary -> final names.
    final changed = <int>[];
    final sourceDirs = <(int, String)>{};
    for (final r in records) {
      if (r.tempRel == null) continue;
      final from = ctx.root(r.item.fromRoot);
      final to = ctx.root(r.item.toRoot);
      final be = backendFor(to);
      var target = r.item.toRel;
      try {
        if (cancel.cancelled) throw StorageException('cancelled');
        await be.mkdirs(to, relDir(target));
        MovedFile moved;
        for (var attempt = 2;; attempt++) {
          try {
            moved = from.id == to.id
                ? await be.move(from, r.tempRel!, target, docId: r.docId)
                : await be.moveAcross(from, r.tempRel!, to, target, docId: r.docId);
            break;
          } on StorageException catch (e) {
            // A non-track file is in the way (not visible in the preview).
            if (e.code != 'target_exists' || attempt > 50) rethrow;
            target = relJoin(relDir(r.item.toRel), withCounter(relName(r.item.toRel), attempt));
          }
        }
        final finalRel = moved.relPath;
        if (finalRel != r.item.toRel) r.warnings.add('renamed_to: ${relName(finalRel)}');
        // Companions follow under the new stem.
        final newStem = stemOf(relName(finalRel));
        final compFinal = <String>[];
        for (final e in r.companionTemps.entries) {
          final name = r.companions[e.key];
          final want = relJoin(relDir(finalRel), '$newStem.${_rawExt(name)}');
          try {
            final m = from.id == to.id ? await be.move(from, e.value, want) : await be.moveAcross(from, e.value, to, want);
            compFinal.add(m.relPath);
          } on StorageException catch (x) {
            // Put it back under its old name.
            r.warnings.add('companion $name: ${x.code}');
            try {
              await backendFor(from).move(from, e.value, relJoin(relDir(r.item.fromRel), name));
            } on StorageException {
              r.warnings.add('companion $name left as ${relName(e.value)}');
            }
          }
        }
        db.transaction(() {
          db.db.execute(
              'UPDATE track SET root_id = ?, rel_path = ?, rel_path_key = ?, file_name = ?, ext = ?, saf_doc_id = ? WHERE id = ?',
              [to.id, finalRel, pathKey(finalRel), relName(finalRel), extOf(finalRel), moved.docId ?? (to.isSaf ? null : r.docId), r.item.trackId]);
          db.db.execute(
              "UPDATE op_item SET step = 'final', state = 'done', error = ?, after_json = json_set(after_json, '\$.rel', ?, '\$.companions', json(?)) "
              'WHERE batch_id = ? AND seq = ?',
              [r.warnings.isEmpty ? null : r.warnings.join('; '), finalRel, jsonEncode(compFinal), batch, r.seq]);
        });
        ok++;
        changed.add(r.item.trackId);
        sourceDirs.add((from.id, relDir(r.item.fromRel)));
      } on Exception catch (e) {
        final code = e is StorageException ? e.code : e.toString();
        // Roll this item back to its original name.
        await _restoreFromTemp(r, from);
        if (code == 'cancelled') {
          skipped.add(ItemResult(r.item.trackId, r.item.fromRel, skipped: true, error: code));
          db.db.execute("UPDATE op_item SET state = 'skipped', step = 'pending', error = ? WHERE batch_id = ? AND seq = ?", [code, batch, r.seq]);
        } else {
          failed.add(ItemResult(r.item.trackId, r.item.fromRel, error: code));
          db.db.execute("UPDATE op_item SET state = 'failed', step = 'pending', error = ? WHERE batch_id = ? AND seq = ?", [code, batch, r.seq]);
        }
      }
      done++;
      if (done % 20 == 0) {
        ctx.emit(JobProgress(jobId, jobKind, done, total, r.item.toRel));
        ctx.emitRows(changed);
        changed.clear();
      }
    }
    ctx.emitRows(changed);
    if (ctx.flag(SettingKeys.removeEmptyDirs)) {
      for (final (rid, dir) in sourceDirs) {
        await _removeEmptyChain(ctx.root(rid), dir);
      }
    }
    for (final r in records) {
      if (r.error == null && r.warnings.isNotEmpty && r.tempRel != null) {
        // Succeeded with remarks: listed among skipped details for the user.
        skipped.add(ItemResult(r.item.trackId, r.item.toRel, error: r.warnings.join('; '), skipped: false));
      }
    }
    final state = failed.isEmpty ? 'done' : (ok == 0 ? 'failed' : 'partial');
    db.db.execute('UPDATE op_batch SET state = ?, finished_at = ?, summary = ? WHERE id = ?', [
      state,
      DateTime.now().millisecondsSinceEpoch,
      jsonEncode({'count': records.length, 'ok': ok, 'failed': failed.length}),
      batch,
    ]);
    ctx.emit(const HistoryChanged());
    return JobFinished(jobId: jobId, kind: jobKind, batchId: batch, succeeded: ok, skipped: skipped, failed: failed, cancelled: cancel.cancelled);
  }

  static String _rawExt(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1);
  }

  Future<void> _restoreFromTemp(_Item r, LibraryRoot from) async {
    final be = backendFor(from);
    final dir = relDir(r.item.fromRel);
    if (r.tempRel != null) {
      try {
        await be.move(from, r.tempRel!, r.item.fromRel, docId: r.docId);
      } on StorageException {
        // left under the temporary name; recovery reports it
      }
    }
    for (final e in r.companionTemps.entries) {
      try {
        await be.move(from, e.value, relJoin(dir, r.companions[e.key]));
      } on StorageException {
        // ignore
      }
    }
  }

  Future<void> _removeEmptyChain(LibraryRoot root, String dir) async {
    var d = dir;
    while (d.isNotEmpty) {
      final names = await backendFor(root).list(root, d);
      if (names.isNotEmpty) return;
      await backendFor(root).removeEmptyDir(root, d);
      d = relDir(d);
    }
  }

  // ------------------------------------------------------------------ undo

  /// Plan that moves the files of [batchId] back. Items whose original
  /// place is now taken are reported as conflicts.
  List<RenamePreviewItem> undoPlan(int batchId) {
    final rows = ctx.db.db.select("SELECT track_id, before_json, after_json FROM op_item WHERE batch_id = ? AND state = 'done'", [batchId]);
    final moving = {for (final x in rows) x['track_id'] as int};
    final out = <RenamePreviewItem>[];
    for (final x in rows) {
      final before = jsonDecode(x['before_json'] as String) as Map<String, dynamic>;
      final f = ctx.fileOf(x['track_id'] as int);
      if (f == null) continue;
      final toRoot = before['root'] as int, toRel = before['rel'] as String;
      final taken = ctx.db.db.select('SELECT id FROM track WHERE root_id = ? AND rel_path_key = ?', [toRoot, pathKey(toRel)]);
      final conflict = taken.isNotEmpty && !moving.contains(taken.first['id'] as int);
      out.add(RenamePreviewItem(
        trackId: f.id,
        fromRoot: f.rootId,
        fromRel: f.rel,
        toRoot: toRoot,
        toRel: toRel,
        flags: {
          if (conflict) RenameFlag.conflict,
          if (f.rootId == toRoot && f.rel == toRel) RenameFlag.unchanged,
        },
      ));
    }
    return out;
  }

  Future<JobFinished> undo(int jobId, int batchId, CancelToken cancel) async {
    final r = await execute(jobId, undoPlan(batchId), cancel, kind: 'undo', undoOf: batchId, jobKind: JobKind.undo);
    final left = ctx.db.db.select("SELECT count(*) AS n FROM op_item WHERE batch_id = ? AND state = 'done'", [batchId]).first['n'] as int;
    if (r.failed.isEmpty && left > 0) ctx.db.db.execute("UPDATE op_batch SET state = 'undone' WHERE id = ?", [batchId]);
    return r;
  }

  // -------------------------------------------------------------- recovery

  /// Moves files left under temporary names (crash during phase 2) back.
  Future<int> recover() async {
    final rows = ctx.db.db.select("SELECT i.batch_id, i.seq, i.before_json, i.after_json, i.temp_name FROM op_item i "
        "JOIN op_batch b ON b.id = i.batch_id WHERE i.step = 'temp' AND b.kind IN ('rename', 'undo')");
    var n = 0;
    for (final x in rows) {
      final before = jsonDecode(x['before_json'] as String) as Map<String, dynamic>;
      final after = jsonDecode(x['after_json'] as String) as Map<String, dynamic>;
      final root = ctx.root(before['root'] as int);
      final be = backendFor(root);
      final dir = relDir(before['rel'] as String);
      try {
        await be.move(root, x['temp_name'] as String, before['rel'] as String);
        final temps = (after['companionTemps'] as Map?)?.cast<String, String>() ?? const {};
        final comps = (before['companions'] as List).cast<String>();
        for (final e in temps.entries) {
          await be.move(root, e.value, relJoin(dir, comps[int.parse(e.key)]));
        }
        ctx.db.db.execute("UPDATE op_item SET step = 'pending', state = 'failed', error = 'interrupted' WHERE batch_id = ? AND seq = ?",
            [x['batch_id'], x['seq']]);
        n++;
      } on StorageException catch (e) {
        ctx.db.db.execute('UPDATE op_item SET error = ? WHERE batch_id = ? AND seq = ?', ['recovery_failed: ${e.code}', x['batch_id'], x['seq']]);
      }
    }
    ctx.db.db.execute("UPDATE op_batch SET state = 'partial' WHERE state = 'running' AND kind IN ('rename', 'undo')");
    return n;
  }
}

class _Item {
  final int seq;
  final RenamePreviewItem item;
  String? docId;
  final List<String> companions;
  final companionTemps = <int, String>{};
  String? tempRel;
  String? error;
  final warnings = <String>[];
  _Item(this.seq, this.item, this.docId, this.companions);
}
