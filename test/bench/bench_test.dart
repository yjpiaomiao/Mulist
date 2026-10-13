// Performance benchmarks on a synthetic 10k library (tool/gen_library.dart).
//
//   MM_BENCH_LIB=<dir> flutter test test/bench/bench_test.dart
//
// Skipped unless MM_BENCH_LIB is set. Prints timings next to the targets.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_manager/core/db/database.dart';
import 'package:music_manager/core/model/library_root.dart';
import 'package:music_manager/core/scan/scanner.dart';
import 'package:music_manager/core/search/search_index.dart';
import 'package:music_manager/core/services/core_context.dart';
import 'package:music_manager/core/services/core_isolate.dart';
import 'package:music_manager/core/services/events.dart';
import 'package:music_manager/core/services/renamer.dart';

void main() {
  final lib = Platform.environment['MM_BENCH_LIB'];
  final skip = lib == null ? 'set MM_BENCH_LIB' : null;

  void report(String what, num value, String unit, num target) {
    final ok = value <= target ? 'OK  ' : 'SLOW';
    // ignore: avoid_print
    print('$ok $what: ${value is double ? value.toStringAsFixed(1) : value} $unit (target <= $target)');
  }

  test('10k library', () async {
    final tmp = Directory.systemTemp.createTempSync('mm_bench_');
    final paths = CorePaths('${tmp.path}/data', '${tmp.path}/cache');
    final core = await CoreClient.start(paths, null);
    final root = await core.call<LibraryRoot>('addRoot', {'kind': 'path', 'locator': lib, 'display': lib});

    // ---- first full scan
    final sw = Stopwatch()..start();
    int? firstRows;
    late ScanDone done;
    await for (final e in startScan(ScanRequest(
      dbPath: paths.dbPath,
      root: root,
      thumbDir: paths.thumbDir,
      separator: '; ',
      workers: Platform.numberOfProcessors.clamp(2, 8),
    )).events) {
      if (e is ScanRows && firstRows == null && e.rows.isNotEmpty) firstRows = sw.elapsedMilliseconds;
      if (e is ScanDone) done = e;
    }
    report('first scan (${done.found} files)', sw.elapsedMilliseconds / 1000, 's', 20);
    report('first results', firstRows ?? -1, 'ms', 1000);
    expect(done.failed, 0);

    // ---- rescan without changes
    sw.reset();
    await startScan(ScanRequest(dbPath: paths.dbPath, root: root, thumbDir: paths.thumbDir, separator: '; ', workers: 4))
        .events
        .last;
    report('rescan (no changes)', sw.elapsedMilliseconds / 1000, 's', 3);

    // ---- load + index (cold start work of the search isolate)
    sw.reset();
    final db = AppDatabase.open(paths.dbPath);
    final rows = db.allRows();
    final idx = SearchIndex()..upsertAll(rows);
    idx.sorted(SortField.artist);
    report('load rows + build index + sort', sw.elapsedMilliseconds, 'ms', 1000);

    // ---- search
    final times = <int>[];
    for (final q in ['a', 'ar', 'art', 'artist', 'l', 'lo', 'lov', 'love', '的', '中国', 'zh', 'zhong', 'de', 'yl', 'xyz', 'mp3', 'flac', '1', 'rock', '流行']) {
      sw.reset();
      idx.search(q, SortField.artist);
      times.add(sw.elapsedMicroseconds);
    }
    times.sort();
    report('search p95 (${times.length} queries, JIT)', times[(times.length * 0.95).floor() - 1] / 1000, 'ms', 30);

    // ---- rename preview 10k
    final ids = [for (final r in rows) r.id];
    sw.reset();
    final p = await core.call<RenamePreview>('renamePreview', RenameRequest(trackIds: ids, template: '[{disc}-]{track:2} {artist} - {title}.{ext}'));
    report('rename preview (${p.items.length})', sw.elapsedMilliseconds, 'ms', 500);

    // ---- batch write 1000 MP3 (on copies)
    final copyDir = Directory('${tmp.path}/w')..createSync();
    final mp3s = rows.where((r) => r.ext == 'mp3').take(1000).toList();
    for (final r in mp3s) {
      final dst = File('${copyDir.path}/${r.id}.mp3');
      File('$lib/${r.relPath}').copySync(dst.path);
    }
    final wroot = await core.call<LibraryRoot>('addRoot', {'kind': 'path', 'locator': copyDir.path, 'display': copyDir.path});
    await startScan(ScanRequest(dbPath: paths.dbPath, root: wroot, thumbDir: paths.thumbDir, separator: '; ', workers: 4)).events.last;
    final wids = [for (final r in db.allRows()) if (r.rootId == wroot.id) r.id];
    sw.reset();
    final job = await core.call<int>('tagWrite', {
      'tracks': wids,
      'request': {
        'set': {
          'ALBUM': ['基准测试专辑'],
          'COMMENT': ['bench'],
        },
        'cover': {'action': 'keep'},
      },
    });
    final f = await core.events.firstWhere((e) => e is JobFinished && e.jobId == job) as JobFinished;
    report('batch write ${f.succeeded} MP3 (failed ${f.failed.length})', sw.elapsedMilliseconds / 1000, 's', 15);
    db.close();
    // ignore: avoid_print
    print('RSS ${(ProcessInfo.currentRss / 1024 / 1024).toStringAsFixed(0)} MB (test process, all isolates)');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));
}
