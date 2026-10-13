// Library scan, run in its own isolate with its own database connection:
// enumerate -> diff by size+mtime -> parse in the native pool -> batched
// upserts -> rows streamed back to the UI isolate as they are stored.
import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../db/database.dart';
import '../jobs/native_pool.dart';
import '../model/library_root.dart';
import '../model/tag_fields.dart';
import '../model/track.dart';
import '../path/path_key.dart';
import '../storage/backends.dart';

class ScanRequest {
  final String dbPath;
  final LibraryRoot root;
  final String thumbDir;
  final String separator;
  final int workers;

  /// Re-parse every file, not only changed ones.
  final bool full;
  final RootIsolateToken? token;

  const ScanRequest({
    required this.dbPath,
    required this.root,
    required this.thumbDir,
    required this.separator,
    required this.workers,
    this.full = false,
    this.token,
  });
}

sealed class ScanEvent {
  const ScanEvent();
}

class ScanProgress extends ScanEvent {
  final int rootId;
  final int found;
  final int parsed;
  final int toParse;
  final bool enumerating;
  const ScanProgress(this.rootId, this.found, this.parsed, this.toParse, this.enumerating);
}

class ScanRows extends ScanEvent {
  final List<TrackRow> rows;
  const ScanRows(this.rows);
}

class ScanDone extends ScanEvent {
  final int rootId;
  final int found;
  final int added;
  final int updated;
  final int failed;
  final int missing;
  final bool cancelled;
  final List<String> warnings;
  final String? error;
  final int elapsedMs;
  const ScanDone({
    required this.rootId,
    required this.found,
    required this.added,
    required this.updated,
    required this.failed,
    required this.missing,
    required this.cancelled,
    required this.warnings,
    required this.elapsedMs,
    this.error,
  });
}

/// Handle of a running scan (UI isolate side).
class ScanHandle {
  final Stream<ScanEvent> events;
  final void Function() cancel;
  ScanHandle(this.events, this.cancel);
}

ScanHandle startScan(ScanRequest req) {
  final events = ReceivePort();
  final controller = StreamController<ScanEvent>();
  SendPort? control;
  var cancelled = false;
  events.listen((m) {
    if (m is SendPort) {
      control = m;
      if (cancelled) m.send('cancel');
      return;
    }
    if (m == null) {
      events.close();
      controller.close();
      return;
    }
    controller.add(m as ScanEvent);
  });
  Isolate.spawn(_scanMain, (req, events.sendPort), debugName: 'scan', onExit: events.sendPort).catchError((Object e) {
    controller.add(ScanDone(
        rootId: req.root.id,
        found: 0,
        added: 0,
        updated: 0,
        failed: 0,
        missing: 0,
        cancelled: false,
        warnings: const [],
        elapsedMs: 0,
        error: e.toString()));
    events.close();
    controller.close();
    return Isolate.current;
  });
  return ScanHandle(controller.stream, () {
    cancelled = true;
    control?.send('cancel');
  });
}

Future<void> _scanMain((ScanRequest, SendPort) init) async {
  final (req, out) = init;
  if (req.token != null) BackgroundIsolateBinaryMessenger.ensureInitialized(req.token!);
  final control = ReceivePort();
  out.send(control.sendPort);
  var cancelled = false;
  control.listen((m) {
    if (m == 'cancel') cancelled = true;
  });
  final sw = Stopwatch()..start();
  final warnings = <String>[];
  final root = req.root;
  final db = AppDatabase.open(req.dbPath);
  NativePool? pool;
  var found = 0, parsed = 0, toParse = 0, added = 0, updated = 0, failed = 0, missing = 0;
  String? error;
  try {
    // Existing records of this root.
    final existing = <String, ({int id, String rel, int size, int mtime, int status})>{};
    for (final r in db.db.select('SELECT id, rel_path, rel_path_key, size, mtime, status FROM track WHERE root_id = ?', [root.id])) {
      existing[r['rel_path_key'] as String] = (
        id: r['id'] as int,
        rel: r['rel_path'] as String,
        size: r['size'] as int,
        mtime: r['mtime'] as int,
        status: r['status'] as int,
      );
    }
    pool = await NativePool.spawn(req.workers, req.token);
    final seen = <int>{};
    final pendingWrites = <(Map<String, Object?>, bool)>[];
    final revived = <int>[];
    var lastFlush = DateTime.now();

    void flush() {
      if (pendingWrites.isEmpty && revived.isEmpty) return;
      final ids = <int>[];
      db.transaction(() {
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final (w, thumb) in pendingWrites) {
          final cols = w.keys.toList();
          final sql = 'INSERT INTO track (${cols.join(',')}) VALUES (${List.filled(cols.length, '?').join(',')}) '
              'ON CONFLICT(root_id, rel_path_key) DO UPDATE SET '
              '${cols.where((c) => c != 'root_id' && c != 'rel_path_key').map((c) => '$c = excluded.$c').join(', ')} '
              'RETURNING id';
          final r = db.db.select(sql, w.values.toList());
          ids.add(r.first.columnAt(0) as int);
          final hash = w['cover_hash'] as String?;
          if (hash != null) {
            db.db.execute('INSERT INTO cover(hash, thumb) VALUES(?, ?) ON CONFLICT(hash) DO UPDATE SET thumb = max(thumb, excluded.thumb)',
                [hash, thumb ? 1 : 0]);
          }
        }
        for (final id in revived) {
          db.db.execute('UPDATE track SET status = 0, scanned_at = ? WHERE id = ?', [now, id]);
          ids.add(id);
        }
      });
      pendingWrites.clear();
      revived.clear();
      out.send(ScanRows(db.rowsByIds(ids)));
      lastFlush = DateTime.now();
    }

    void progress(bool enumerating) => out.send(ScanProgress(root.id, found, parsed, toParse, enumerating));

    final inflight = <Future<void>>{};
    final maxInflight = req.workers * 3;

    Future<void> parse(String rel, int size, int mtime, String? docId, int? existingId) async {
      Map<String, dynamic> r;
      try {
        r = await pool!.withFile(root, rel, docId, false, (w, h) => w.call<Map>('read', {
              'handle': h,
              'thumbDir': req.thumbDir,
              'detail': true,
            }).then((m) => m.cast<String, dynamic>()));
      } catch (e) {
        r = {'ok': false, 'error': e.toString()};
      }
      final name = relName(rel);
      final row = <String, Object?>{
        'root_id': root.id,
        'rel_path': rel,
        'rel_path_key': pathKey(rel),
        'file_name': name,
        'ext': extOf(name),
        'saf_doc_id': docId,
        'size': size,
        'mtime': mtime,
        'scanned_at': DateTime.now().millisecondsSinceEpoch,
      };
      if (r['ok'] == true) {
        row.addAll(columnsFromRead(r, req.separator));
        // TagLib accepts e.g. any bytes named *.mp3; without an audio stream
        // the file is reported as unreadable.
        final noAudio = row['sample_rate'] == 0 && row['duration_ms'] == 0;
        row['status'] = noAudio ? TrackStatus.parseFailed.index : TrackStatus.ok.index;
        row['error'] = noAudio ? 'no_audio_stream' : null;
        if (noAudio) failed++;
      } else {
        row['status'] = TrackStatus.parseFailed.index;
        row['error'] = r['error']?.toString() ?? 'unknown';
        failed++;
      }
      if (existingId == null) {
        added++;
      } else {
        updated++;
      }
      pendingWrites.add((row, r['thumb'] == true));
      parsed++;
    }

    await for (final batch in backendFor(root).enumerate(root, warnings: warnings.add)) {
      for (final e in batch) {
        if (cancelled) break;
        found++;
        final key = pathKey(e.relPath);
        final ex = existing[key];
        if (ex != null) {
          seen.add(ex.id);
          final unchanged = ex.size == e.size && ex.mtime == e.mtimeNs && ex.rel == e.relPath;
          if (unchanged && !req.full) {
            if (ex.status == TrackStatus.missing.index) revived.add(ex.id);
            continue;
          }
        }
        toParse++;
        late final Future<void> f;
        f = parse(e.relPath, e.size, e.mtimeNs, e.docId, ex?.id).whenComplete(() => inflight.remove(f));
        inflight.add(f);
        while (inflight.length >= maxInflight) {
          await Future.any(inflight);
          if (pendingWrites.length >= 200 || DateTime.now().difference(lastFlush).inMilliseconds > 150) flush();
        }
      }
      if (cancelled) break;
      if (pendingWrites.length >= 200 || DateTime.now().difference(lastFlush).inMilliseconds > 150) flush();
      progress(true);
    }
    while (inflight.isNotEmpty) {
      await Future.any(inflight);
      if (pendingWrites.length >= 200 || DateTime.now().difference(lastFlush).inMilliseconds > 150) {
        flush();
        progress(false);
      }
    }
    flush();
    if (!cancelled) {
      // Files that disappeared are only marked: playlists keep referring to
      // them and the user decides whether to remove them.
      final gone = [for (final e in existing.values) if (!seen.contains(e.id) && e.status != TrackStatus.missing.index) e.id];
      if (gone.isNotEmpty) {
        db.transaction(() {
          for (final id in gone) {
            db.db.execute('UPDATE track SET status = ? WHERE id = ?', [TrackStatus.missing.index, id]);
          }
        });
        missing = gone.length;
        out.send(ScanRows(db.rowsByIds(gone)));
      }
      db.db.execute('UPDATE library_root SET last_scan_at = ? WHERE id = ?', [DateTime.now().millisecondsSinceEpoch, root.id]);
    }
  } catch (e, st) {
    error = '$e\n$st';
  } finally {
    pool?.dispose();
    db.close();
    control.close();
  }
  out.send(ScanDone(
    rootId: root.id,
    found: found,
    added: added,
    updated: updated,
    failed: failed,
    missing: missing,
    cancelled: cancelled,
    warnings: warnings.take(200).toList(),
    elapsedMs: sw.elapsedMilliseconds,
    error: error,
  ));
}
