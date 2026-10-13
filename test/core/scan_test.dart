import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_manager/core/db/database.dart';
import 'package:music_manager/core/model/library_root.dart';
import 'package:music_manager/core/model/track.dart';
import 'package:music_manager/core/scan/scanner.dart';

const fixtures = 'packages/mm_native/test/fixtures';

Future<List<ScanEvent>> runScan(ScanRequest req) => startScan(req).events.toList();

void main() {
  late Directory tmp;
  late String dbPath;
  late Directory lib;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mm_scan_');
    dbPath = '${tmp.path}/lib.db';
    lib = Directory('${tmp.path}/音乐库')..createSync();
    Directory('${lib.path}/周杰伦/叶惠美').createSync(recursive: true);
    Directory('${lib.path}/.hidden').createSync();
    File('$fixtures/rich.flac').copySync('${lib.path}/周杰伦/叶惠美/03 晴天.flac');
    File('$fixtures/id3v23_rich.mp3').copySync('${lib.path}/周杰伦/a.mp3');
    File('$fixtures/id3.dsf').copySync('${lib.path}/dsd.dsf');
    File('$fixtures/rich.flac').copySync('${lib.path}/.hidden/x.flac');
    File('$fixtures/rich.flac').copySync('${lib.path}/.dot.flac');
    File('${lib.path}/notes.txt').writeAsStringSync('x');
    File('${lib.path}/broken.mp3').writeAsStringSync('not audio');
  });
  tearDown(() {
    if (Platform.isWindows) Process.runSync('cmd', ['/c', 'rmdir', '${lib.path}${Platform.pathSeparator}loop']);
    tmp.deleteSync(recursive: true);
  });

  LibraryRoot addRoot(AppDatabase db, String path) {
    db.db.execute("INSERT INTO library_root(kind, locator, display_path, added_at) VALUES('path', ?, ?, 0)", [path, path]);
    return LibraryRoot(id: db.db.lastInsertRowId, kind: RootKind.path, locator: path, displayPath: path);
  }

  test('scan, incremental rescan, missing files, links', () async {
    final db = AppDatabase.open(dbPath);
    addTearDown(db.close);
    final root = addRoot(db, lib.path);
    if (Platform.isWindows) {
      // A junction back to the library (loop) and a folder shortcut (.lnk).
      final win = lib.path.replaceAll('/', '\\');
      final r = Process.runSync('powershell', [
        '-NoProfile',
        '-Command',
        "New-Item -ItemType Junction -Path '$win\\loop' -Target '$win' | Out-Null",
      ]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      final ext = Directory('${tmp.path}/外部')..createSync();
      File('$fixtures/opus.opus').copySync('${ext.path}/linked.opus');
      final ps = '\$s=(New-Object -ComObject WScript.Shell).CreateShortcut("${lib.path}\\快捷方式.lnk");'
          '\$s.TargetPath="${ext.path}";\$s.Save()';
      Process.runSync('powershell', ['-NoProfile', '-Command', ps]);
    }
    final req = ScanRequest(dbPath: dbPath, root: root, thumbDir: tmp.path, separator: '; ', workers: 2);
    var events = await runScan(req);
    final done = events.whereType<ScanDone>().single;
    expect(done.error, isNull);
    final rows = {for (final r in db.allRows()) r.relPath: r};
    final expected = {'周杰伦/叶惠美/03 晴天.flac', '周杰伦/a.mp3', 'dsd.dsf', 'broken.mp3'};
    if (Platform.isWindows) expected.add('快捷方式/linked.opus');
    expect(rows.keys.toSet(), expected);
    expect(rows['周杰伦/叶惠美/03 晴天.flac']!.artist, '周杰伦; Jay Chou');
    expect(rows['周杰伦/叶惠美/03 晴天.flac']!.trackNo, 3);
    expect(rows['dsd.dsf']!.codec, 'DSD');
    expect(rows['broken.mp3']!.status, TrackStatus.parseFailed);
    expect(events.whereType<ScanRows>().expand((e) => e.rows).length, greaterThanOrEqualTo(4));
    final cover = rows['周杰伦/a.mp3']!.coverHash!;
    expect(File('${tmp.path}/$cover.jpg').existsSync(), isTrue);
    if (Platform.isWindows) expect(done.warnings.any((w) => w.contains('link_loop')), isTrue, reason: '${done.warnings} ${Directory(lib.path).listSync()}');
    final detail = db.detail(rows['周杰伦/a.mp3']!.id)!;
    expect(detail.props['REPLAYGAIN_TRACK_GAIN'], ['-6.50 dB']);
    expect(detail.tagFormats, ['ID3v2.3']);

    // Rescan without changes parses nothing.
    events = await runScan(req);
    expect(events.whereType<ScanDone>().single.updated, 0);
    expect(events.whereType<ScanDone>().single.added, 0);

    // Touch one file, delete another.
    final f = File('${lib.path}/dsd.dsf');
    f.setLastModifiedSync(DateTime(2020));
    File('${lib.path}/周杰伦/a.mp3').deleteSync();
    events = await runScan(req);
    final d3 = events.whereType<ScanDone>().single;
    expect(d3.updated, 1);
    expect(d3.missing, 1);
    expect(db.allRows().firstWhere((r) => r.relPath == '周杰伦/a.mp3').status, TrackStatus.missing);
  });
}
