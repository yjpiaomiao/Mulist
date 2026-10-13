import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mm_native/mm_native.dart';
import 'package:music_manager/core/db/database.dart';
import 'package:music_manager/core/model/library_root.dart';
import 'package:music_manager/core/model/track.dart';
import 'package:music_manager/core/scan/scanner.dart';
import 'package:music_manager/core/services/core_context.dart';
import 'package:music_manager/core/services/core_isolate.dart';
import 'package:music_manager/core/services/events.dart';
import 'package:music_manager/core/services/playlists.dart';
import 'package:music_manager/core/services/renamer.dart';

const fixtures = 'packages/mm_native/test/fixtures';

void main() {
  late Directory tmp;
  late Directory lib;
  late CorePaths paths;
  late CoreClient core;
  late LibraryRoot root;

  Future<JobFinished> waitJob(int id) =>
      core.events.where((e) => e is JobFinished && e.jobId == id).cast<JobFinished>().first;

  Future<Map<String, TrackRow>> rows() async {
    final db = AppDatabase.open(paths.dbPath);
    try {
      return {for (final r in db.allRows()) r.relPath: r};
    } finally {
      db.close();
    }
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mm_svc_');
    lib = Directory('${tmp.path}/lib')..createSync();
    Directory('${lib.path}/A').createSync();
    File('$fixtures/id3v23_rich.mp3').copySync('${lib.path}/A/one.mp3');
    File('$fixtures/rich.flac').copySync('${lib.path}/A/two.flac');
    File('$fixtures/three_tags.mp3').copySync('${lib.path}/A/three.mp3');
    File('${lib.path}/A/one.lrc').writeAsStringSync('[00:00]歌词');
    File('${lib.path}/A/one.jpg').writeAsBytesSync([1, 2, 3]);
    paths = CorePaths('${tmp.path}/data', '${tmp.path}/cache');
    core = await CoreClient.start(paths, null);
    root = await core.call<LibraryRoot>('addRoot', {'kind': 'path', 'locator': lib.path, 'display': lib.path});
    final done = await startScan(ScanRequest(
            dbPath: paths.dbPath, root: root, thumbDir: paths.thumbDir, separator: '; ', workers: 2))
        .events
        .firstWhere((e) => e is ScanDone) as ScanDone;
    expect(done.added, 3);
  });

  tearDown(() async {
    // Let isolates close their database handles.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // The core isolate may still hold the database open on Windows.
    }
  });

  test('batch tag write, history, byte-level undo, retry', () async {
    final r = await rows();
    final ids = [r['A/one.mp3']!.id, r['A/two.flac']!.id, r['A/three.mp3']!.id];
    final originals = {for (final n in ['one.mp3', 'two.flac', 'three.mp3']) n: File('${lib.path}/A/$n').readAsBytesSync()};
    final mtime = File('${lib.path}/A/one.mp3').lastModifiedSync();
    final job = await core.call<int>('tagWrite', {
      'tracks': ids,
      'request': {
        'set': {
          'ALBUM': ['批量专辑'],
          'GENRE': ['摇滚', 'Rock'],
        },
        'cover': {'action': 'keep'},
      },
    });
    final f = await waitJob(job);
    expect(f.failed.map((e) => e.error), isEmpty);
    expect(f.succeeded, 3);
    final after = await rows();
    expect(after['A/one.mp3']!.album, '批量专辑');
    expect(after['A/two.flac']!.genre, '摇滚; Rock');
    expect(File('${lib.path}/A/one.mp3').lastModifiedSync(), mtime);
    final d = await core.call<TrackDetail>('detail', ids[2]);
    // ID3v1 is Latin-1 only and cannot hold the Chinese album name.
    for (final t in d.tags.where((t) => t.format != 'ID3v1')) {
      expect(t.props['ALBUM'], ['批量专辑'], reason: t.format);
    }
    final history = await core.call<List<HistoryEntry>>('history');
    expect(history.first.kind, 'tag_write');
    expect(history.first.undoable, isTrue);

    final u = await core.call<int>('undoLast');
    final uf = await waitJob(u);
    expect(uf.failed, isEmpty);
    for (final e in originals.entries) {
      expect(File('${lib.path}/A/${e.key}').readAsBytesSync(), e.value, reason: e.key);
    }
    final items = await core.call<List<HistoryItem>>('historyItems', uf.batchId);
    expect(items.every((i) => i.state == 'done'), isTrue);
    final h2 = await core.call<List<HistoryEntry>>('history');
    expect(h2.firstWhere((h) => h.id == history.first.id).undoable, isFalse);
    expect((await rows())['A/one.mp3']!.album, '叶惠美');
  });

  test('undo falls back to old values when the file changed afterwards', () async {
    final id = (await rows())['A/two.flac']!.id;
    final f = await waitJob(await core.call<int>('tagWrite', {
      'tracks': [id],
      'request': {
        'set': {
          'TITLE': ['新标题'],
        },
        'cover': {'action': 'remove'},
      },
    }));
    expect(f.succeeded, 1);
    // Someone else edits another tag.
    final path = '${lib.path}/A/two.flac';
    MmNative.commit(
        MmTarget.path(path),
        MmNative.prepareWrite(MmTarget.path(path), {
          'set': {
            'COMPOSER': ['外部修改'],
          },
        }));
    final u = await waitJob(await core.call<int>('undoLast'));
    expect(u.failed, isEmpty);
    final r = MmNative.read(MmTarget.path(path));
    expect(r['props']['TITLE'], ['晴天']);
    expect(r['props']['COMPOSER'], ['外部修改']);
    expect((r['pictures'] as List).length, 1, reason: 'front cover put back');
  });

  test('rename with template, swap, companions, undo', () async {
    final r = await rows();
    final ids = [r['A/one.mp3']!.id, r['A/two.flac']!.id];
    // Swap names through the manual override: one <-> two (stems).
    final preview = await core.call<RenamePreview>(
        'renamePreview',
        RenameRequest(trackIds: ids, template: '{title}.{ext}', overrides: {
          ids[0]: 'A/two.mp3',
          ids[1]: 'A/one.flac',
        }));
    expect(preview.items.map((i) => i.toRel), ['A/two.mp3', 'A/one.flac']);
    final f = await waitJob(await core.call<int>('rename', preview.items));
    expect(f.failed, isEmpty);
    expect(File('${lib.path}/A/two.mp3').existsSync(), isTrue);
    expect(File('${lib.path}/A/one.flac').existsSync(), isTrue);
    expect(File('${lib.path}/A/two.lrc').readAsStringSync(), '[00:00]歌词');
    expect(File('${lib.path}/A/two.jpg').existsSync(), isTrue);
    expect(File('${lib.path}/A/one.mp3').existsSync(), isFalse);

    // Organize into folders under a target directory outside the root.
    final target = Directory('${tmp.path}/整理后')..createSync();
    final t = await core.call<Map>('resolveTarget', {'kind': 'path', 'locator': target.path, 'display': target.path});
    expect(t['added'], isTrue);
    final p2 = await core.call<RenamePreview>(
        'renamePreview',
        RenameRequest(
          trackIds: ids,
          template: '{albumartist|artist}/{album}/{track:2} {title}.{ext}',
          targetRootId: t['rootId'] as int,
        ));
    expect(p2.items.map((i) => i.toRel).toSet(), {'周杰伦/叶惠美/03 晴天.mp3', '周杰伦/叶惠美/03 晴天.flac'});
    final f2 = await waitJob(await core.call<int>('rename', p2.items));
    expect(f2.failed, isEmpty);
    expect(File('${target.path}/周杰伦/叶惠美/03 晴天.flac').existsSync(), isTrue);
    expect(File('${target.path}/周杰伦/叶惠美/03 晴天.lrc').existsSync(), isTrue);
    // Undo the move, then the swap.
    expect((await waitJob(await core.call<int>('undoLast'))).failed, isEmpty);
    expect(File('${lib.path}/A/two.mp3').existsSync(), isTrue);
    expect(File('${lib.path}/A/two.lrc').existsSync(), isTrue);
    expect((await waitJob(await core.call<int>('undoLast'))).failed, isEmpty);
    expect(File('${lib.path}/A/one.mp3').existsSync(), isTrue);
    expect(File('${lib.path}/A/one.lrc').existsSync(), isTrue);
    expect(File('${lib.path}/A/two.flac').existsSync(), isTrue);
    final names = Directory('${lib.path}/A').listSync().map((e) => e.uri.pathSegments.last).toSet();
    expect(names, {'one.mp3', 'two.flac', 'three.mp3', 'one.lrc', 'one.jpg'});
  });

  test('rename conflicts are numbered or reported', () async {
    final r = await rows();
    final ids = [r['A/one.mp3']!.id, r['A/three.mp3']!.id];
    final p = await core.call<RenamePreview>('renamePreview', RenameRequest(trackIds: ids, template: 'same.{ext}'));
    expect(p.items.map((i) => i.toRel), ['A/same.mp3', 'A/same (2).mp3']);
    expect(p.items[1].flags, contains(RenameFlag.numbered));
    final s = await core.call<RenamePreview>(
        'renamePreview', RenameRequest(trackIds: ids, template: 'SAME.{ext}', policy: ConflictPolicy.skip));
    expect(s.items[1].flags, contains(RenameFlag.conflict));
    final bad = await core.call<RenamePreview>('renamePreview', RenameRequest(trackIds: ids, template: '{nope}'));
    expect(bad.templateError, isNotNull);
    final dirs = await core.call<RenamePreview>('renamePreview', RenameRequest(trackIds: ids, template: '{artist}/{title}'));
    expect(dirs.templateError, 'target_required');
  });

  test('playlists and export', () async {
    final r = await rows();
    final ids = [r['A/one.mp3']!.id, r['A/two.flac']!.id];
    final pid = await core.call<int>('playlistCreate', {'name': '我的歌单', 'tracks': ids});
    final list = await core.call<List<PlaylistInfo>>('playlists');
    expect(list.single.count, 2);
    final out = '${lib.path}/lists/x.m3u8';
    Directory('${lib.path}/lists').createSync();
    final sep = Platform.pathSeparator;
    final res = await core.call<ExportResult>('exportToPath', {
      'tracks': await core.call<List<int>>('playlistTrackIds', pid),
      'options': ExportOptions.platformDefault(ExportFormat.m3u8).toJson(),
      'path': out,
      'playlist': pid,
    });
    expect(res.problems, isEmpty);
    final text = utf8.decode(File(out).readAsBytesSync());
    expect(text.startsWith('#EXTM3U'), isTrue);
    expect(text, contains('#EXTINF:1,周杰伦 - 晴天'));
    expect(text, contains('..${sep}A${sep}one.mp3'));
    final abs = await core.call<ExportResult>('exportBuild', {
      'tracks': ids,
      'options': {...ExportOptions.platformDefault(ExportFormat.m3u).toJson(), 'relative': false, 'separator': '/'},
    });
    final m3u = abs.bytes;
    expect(m3u.sublist(0, 3), [0xEF, 0xBB, 0xBF], reason: 'm3u has a BOM');
    expect(utf8.decode(m3u.sublist(3)), contains('${lib.path.replaceAll(r'\', '/')}/A/two.flac'));
    final txt = await core.call<ExportResult>('exportBuild', {
      'tracks': ids,
      'options': {...ExportOptions.platformDefault(ExportFormat.txt).toJson(), 'crlf': false},
    });
    expect(utf8.decode(txt.bytes.sublist(3)), '周杰伦 - 晴天\n周杰伦; Jay Chou - 晴天\n');
    // Playlists follow renamed tracks.
    final p = await core.call<RenamePreview>('renamePreview', RenameRequest(trackIds: [ids[0]], template: 'renamed.{ext}'));
    await waitJob(await core.call<int>('rename', p.items));
    final again = await core.call<ExportResult>('exportBuild', {
      'tracks': await core.call<List<int>>('playlistTrackIds', pid),
      'options': {...ExportOptions.platformDefault(ExportFormat.m3u8).toJson(), 'relative': false},
    });
    expect(utf8.decode(again.bytes), contains('renamed.mp3'));
  });
}
