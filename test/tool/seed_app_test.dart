// Dev helper: adds MM_SEED_LIB as a library root of the installed app's
// database and scans it (the app does not scan on startup).
//   MM_SEED_LIB=<dir> MM_APP_DATA=<support dir> flutter test test/tool/seed_app_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_manager/core/model/library_root.dart';
import 'package:music_manager/core/scan/scanner.dart';
import 'package:music_manager/core/services/core_context.dart';
import 'package:music_manager/core/services/core_isolate.dart';

void main() {
  final lib = Platform.environment['MM_SEED_LIB'];
  final data = Platform.environment['MM_APP_DATA'];
  test('seed', () async {
    final paths = CorePaths(data!, '${Platform.environment['LOCALAPPDATA']}/io.github.musicmanager/music_manager');
    final core = await CoreClient.start(paths, null);
    final root = await core.call<LibraryRoot>('addRoot', {'kind': 'path', 'locator': lib, 'display': lib});
    final done = await startScan(ScanRequest(dbPath: paths.dbPath, root: root, thumbDir: paths.thumbDir, separator: '; ', workers: 8)).events.last;
    // ignore: avoid_print
    print(done);
  }, skip: lib == null || data == null ? 'dev helper' : null);
}
