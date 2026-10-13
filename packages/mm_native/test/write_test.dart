// End-to-end tests of the safe write protocol on every supported format:
// prepare -> commit -> re-read, byte-level restore, crash roll-forward.
import 'dart:io';
import 'dart:typed_data';

import 'package:mm_native/mm_native.dart';
import 'package:test/test.dart';

import 'util.dart';

const audioFixtures = [
  'aac.m4a',
  'alac.m4a',
  'ape_tag.wv',
  'asf.wma',
  'diin.dff',
  'id3.aiff',
  'id3.dff',
  'id3.dsf',
  'id3.tta',
  'id3.wav',
  'id3v23_nopad.mp3',
  'id3v23_rich.mp3',
  'id3v24_multi.mp3',
  'info.wav',
  'monkey.ape',
  'musepack.mpc',
  'nopad.flac',
  'notag.dsf',
  'notag.mp3',
  'opus.opus',
  'rich.flac',
  'speex.spx',
  'three_tags.mp3',
  'v1_only.mp3',
  'vorbis.ogg',
];

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('mm_write_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('write + verify + restore', () {
    for (final name in audioFixtures) {
      test(name, () {
        final file = copyFixture(name, tmp);
        final original = file.readAsBytesSync();
        final before = MmNative.read(MmTarget.path(file.path), detail: true);
        // The APE / Musepack fixtures carry random payloads that ffmpeg
        // cannot demux reliably; their audio is checked natively.
        final synthetic = name.endsWith('.ape') || name.endsWith('.mpc');
        final beforeMd5 = synthetic ? null : ffmpegPacketMd5(file.path);
        final origMtime = file.lastModifiedSync();

        final edits = <String, List<String>>{
          'TITLE': ['新标题 · New ✓'],
          'ALBUM': ['新专辑'],
        };
        edits['ARTIST'] = ['甲', 'Bee'];
        if ((before['props'] as Map).containsKey('COMMENT')) edits['COMMENT'] = [];

        final backup = '${tmp.path}/backup.bin';
        final plan = MmNative.prepareWrite(MmTarget.path(file.path), {
          'set': edits,
          'backupPath': backup,
          'stagePath': '${tmp.path}/stage.bin',
          'keepMtime': true,
        });
        expect(plan['mode'], anyOf('patch', 'rewrite'));
        // Nothing touched before commit.
        expect(file.readAsBytesSync(), original);

        MmNative.commit(MmTarget.path(file.path), plan);
        final after = MmNative.read(MmTarget.path(file.path), detail: true);
        final rejected = (plan['rejected'] as List).cast<String>().toSet();
        final props = after['props'] as Map<String, dynamic>;
        final joined = (plan['joined'] as List).cast<String>().toSet();
        for (final e in edits.entries) {
          if (rejected.contains(e.key)) continue;
          if (joined.contains(e.key)) {
            expect(props[e.key], [e.value.join('; ')], reason: 'joined ${e.key}');
          } else if (e.value.isEmpty) {
            expect(props.containsKey(e.key), isFalse, reason: 'removed ${e.key}');
          } else {
            expect(props[e.key], e.value, reason: e.key);
          }
        }
        // Untouched keys, pictures and audio are identical.
        final beforeProps = before['props'] as Map<String, dynamic>;
        for (final k in beforeProps.keys) {
          if (edits.containsKey(k)) continue;
          if (name.endsWith('.wma')) {
            // ASF value order is not stable across saves (see tagio.cpp).
            expect(props[k], unorderedEquals(beforeProps[k] as List), reason: 'other key $k');
          } else {
            expect(props[k], beforeProps[k], reason: 'other key $k');
          }
        }
        expect(after['pictures'], before['pictures']);
        // Bitrate may be derived from the file size, so it is not compared.
        Map<String, dynamic> audio(Map r) => Map.of(r['audio'] as Map<String, dynamic>)..remove('bitrate');
        expect(audio(after), audio(before));
        expect(after['tagFormats'], isNotEmpty);
        // Existing tag types are kept; secondary tags are synced, not added.
        final formatsBefore = (before['tagFormats'] as List).toSet();
        expect((after['tagFormats'] as List).toSet().containsAll(formatsBefore), isTrue);
        expect(file.lastModifiedSync(), origMtime, reason: 'mtime kept');
        if (beforeMd5 != null) expect(ffmpegPacketMd5(file.path), beforeMd5, reason: 'ffmpeg packets');
        expect(plan['audioCheck'], anyOf('bytes', 'packets'), reason: 'audio region located');

        // Byte-level undo restores the exact original file.
        final restore = MmNative.prepareRestore(MmTarget.path(file.path), {
          'backupPath': backup,
          'stagePath': '${tmp.path}/stage2.bin',
        });
        MmNative.commit(MmTarget.path(file.path), restore);
        expect(file.readAsBytesSync(), original, reason: 'restored bytes');
        expect(file.lastModifiedSync(), origMtime, reason: 'restored mtime');
        expectNoStrayFiles(tmp, keep: {name, 'backup.bin', 'stage.bin', 'stage2.bin'});
      });
    }
  });

  test('ID3v2 + APEv2 + ID3v1 are all updated, versions kept', () {
    final file = copyFixture('three_tags.mp3', tmp);
    final plan = MmNative.prepareWrite(MmTarget.path(file.path), {
      'set': {
        'TITLE': ['Synced'],
      },
    });
    MmNative.commit(MmTarget.path(file.path), plan);
    final r = MmNative.read(MmTarget.path(file.path), detail: true);
    final tags = {for (final t in r['tags'] as List) t['format']: t['props']};
    expect(tags.keys, ['ID3v2.3', 'APEv2', 'ID3v1']);
    for (final t in tags.values) {
      expect(t['TITLE'], ['Synced']);
    }
    expect(tags['APEv2']['CUSTOM'], ['keep me']);
    expect(tags['APEv2']['ARTIST'], ['APE Artist']);
  });

  test('new ID3v2 is v2.3, v2.4 stays v2.4', () {
    final a = copyFixture('notag.mp3', tmp);
    MmNative.commit(
        MmTarget.path(a.path),
        MmNative.prepareWrite(MmTarget.path(a.path), {
          'set': {
            'TITLE': ['x'],
          },
        }));
    expect(MmNative.read(MmTarget.path(a.path))['tagFormats'], ['ID3v2.3']);
    final b = copyFixture('id3v24_multi.mp3', tmp);
    MmNative.commit(
        MmTarget.path(b.path),
        MmNative.prepareWrite(MmTarget.path(b.path), {
          'set': {
            'TITLE': ['x'],
          },
        }));
    expect(MmNative.read(MmTarget.path(b.path))['tagFormats'], ['ID3v2.4']);
    final c = copyFixture('notag.dsf', tmp);
    MmNative.commit(
        MmTarget.path(c.path),
        MmNative.prepareWrite(MmTarget.path(c.path), {
          'set': {
            'TITLE': ['DSD 标题'],
          },
        }));
    final rc = MmNative.read(MmTarget.path(c.path));
    expect(rc['tagFormats'], ['ID3v2.3']);
    expect(rc['props']['TITLE'], ['DSD 标题']);
  });

  test('custom fields (TXXX / freeform) survive and can be edited', () {
    for (final name in ['id3v23_rich.mp3', 'rich.flac', 'aac.m4a']) {
      final f = copyFixture(name, tmp);
      final key = name == 'aac.m4a' ? 'MOOD' : 'REPLAYGAIN_TRACK_GAIN';
      final plan = MmNative.prepareWrite(MmTarget.path(f.path), {
        'set': {
          key: ['-1.00 dB'],
        },
      });
      MmNative.commit(MmTarget.path(f.path), plan);
      expect(MmNative.read(MmTarget.path(f.path))['props'][key], ['-1.00 dB'], reason: name);
    }
  });

  group('cover', () {
    for (final name in ['id3v23_rich.mp3', 'rich.flac', 'aac.m4a', 'vorbis.ogg', 'notag.mp3', 'asf.wma']) {
      test('set/remove $name', () {
        final f = copyFixture(name, tmp);
        final before = MmNative.read(MmTarget.path(f.path));
        final pics = before['pictures'] as List;
        final plan = MmNative.prepareWrite(MmTarget.path(f.path), {
          'cover': {'action': 'set', 'path': fixturePath('cover.png')},
          'backupPath': '${tmp.path}/b.bin',
        });
        MmNative.commit(MmTarget.path(f.path), plan);
        final r = MmNative.read(MmTarget.path(f.path), thumbDir: tmp.path);
        final newHash = r['coverHash'] as String;
        expect(newHash, endsWith('-${File(fixturePath('cover.png')).lengthSync()}'));
        expect(File('${tmp.path}/$newHash.jpg').existsSync(), isTrue, reason: 'thumbnail');
        // Other pictures (e.g. back cover) are kept.
        final backCovers = pics.where((p) => p['type'] == 'Back Cover').toList();
        for (final b in backCovers) {
          expect((r['pictures'] as List).any((p) => p['hash'] == b['hash']), isTrue);
        }
        final rm = MmNative.prepareWrite(MmTarget.path(f.path), {
          'cover': {'action': 'remove'},
        });
        MmNative.commit(MmTarget.path(f.path), rm);
        expect(MmNative.read(MmTarget.path(f.path))['pictures'], isEmpty);
        // Undo only the first write is refused now (bytes changed since).
        expect(
            () => MmNative.prepareRestore(MmTarget.path(f.path), {'backupPath': '${tmp.path}/b.bin'}),
            throwsA(isA<MmException>()
                .having((e) => e.code, 'code', 'file_changed_since_write')));
      });
    }
  });

  test('copyOut makes a whole-file copy', () {
    final f = copyFixture('rich.flac', tmp);
    final r = MmNative.copyOut(MmTarget.path(f.path), '${tmp.path}/full.bak');
    expect(r['size'], f.lengthSync());
    expect(File('${tmp.path}/full.bak').readAsBytesSync(), f.readAsBytesSync());
  });

  test('writing the current values is a noop', () {
    final f = copyFixture('id3v23_rich.mp3', tmp);
    final plan = MmNative.prepareWrite(MmTarget.path(f.path), {
      'set': {
        'TITLE': ['晴天'],
      },
    });
    expect(plan['mode'], 'noop');
  });

  test('commit refuses when the file changed after prepare', () {
    final f = copyFixture('id3v23_rich.mp3', tmp);
    final plan = MmNative.prepareWrite(MmTarget.path(f.path), {
      'set': {
        'TITLE': ['A'],
      },
    });
    f.setLastModifiedSync(DateTime(2001));
    expect(() => MmNative.commit(MmTarget.path(f.path), plan),
        throwsA(isA<MmException>().having((e) => e.code, 'code', 'file_changed_since_prepare')));
    expect(MmNative.read(MmTarget.path(f.path))['props']['TITLE'], ['晴天']);
  });

  test('prepare refuses when expectSize/mtime do not match', () {
    final f = copyFixture('rich.flac', tmp);
    expect(
        () => MmNative.prepareWrite(MmTarget.path(f.path), {
              'set': {
                'TITLE': ['A'],
              },
              'expectSize': 1,
            }),
        throwsA(isA<MmException>().having((e) => e.code, 'code', 'file_changed_since_read')));
  });

  group('crash roll-forward', () {
    test('patch interrupted half way', () {
      final f = copyFixture('id3v23_rich.mp3', tmp);
      final ref = copyFixture('id3v23_rich.mp3', tmp, as: 'ref.mp3');
      final req = {
        'set': {
          'TITLE': ['Crash test 崩溃'],
        },
        'stagePath': '${tmp.path}/stage.bin',
      };
      final plan = MmNative.prepareWrite(MmTarget.path(f.path), req);
      expect(plan['mode'], 'patch');
      final refPlan = MmNative.prepareWrite(MmTarget.path(ref.path), {...req, 'stagePath': '${tmp.path}/s2.bin'});
      MmNative.commit(MmTarget.path(ref.path), refPlan);

      // Simulate a crash: only the first half of the first patch landed and
      // the mtime moved.
      final patches = plan['patches'] as List;
      final stage = File(plan['stagePath'] as String).readAsBytesSync();
      final p0 = patches.first as List;
      final raf = f.openSync(mode: FileMode.append);
      raf.setPositionSync(p0[0] as int);
      final half = (p0[1] as int) ~/ 2;
      raf.writeFromSync(Uint8List.sublistView(stage, p0[2] as int, (p0[2] as int) + half));
      raf.closeSync();
      f.setLastModifiedSync(DateTime.now());

      expect(() => MmNative.commit(MmTarget.path(f.path), plan), throwsA(isA<MmException>()));
      MmNative.commit(MmTarget.path(f.path), {...plan, 'force': true});
      expect(f.readAsBytesSync(), ref.readAsBytesSync());
      // Running it again is harmless.
      MmNative.commit(MmTarget.path(f.path), {...plan, 'force': true});
      expect(f.readAsBytesSync(), ref.readAsBytesSync());
    });

    test('rewrite: before and after the atomic replace', () {
      final f = copyFixture('id3v23_nopad.mp3', tmp);
      final plan = MmNative.prepareWrite(MmTarget.path(f.path), {
        'set': {
          'TITLE': ['这个标题比原来的长很多很多很多所以必须重写整个文件'],
        },
      });
      expect(plan['mode'], 'rewrite');
      final stage = File(plan['stagePath'] as String);
      expect(stage.parent.path, f.parent.path, reason: 'stage next to target');
      final expected = stage.readAsBytesSync();
      // Crash before replace: commit again.
      MmNative.commit(MmTarget.path(f.path), {...plan, 'force': true});
      expect(f.readAsBytesSync(), expected);
      expect(stage.existsSync(), isFalse);
      // Crash after replace (stage gone, journal still says running).
      final again = MmNative.commit(MmTarget.path(f.path), {...plan, 'force': true});
      expect(again['already'], isTrue);
      expect(f.readAsBytesSync(), expected);
    });
  });

  test('descriptor mode (Android SAF path): patch, rewrite, restore', () {
    for (final name in ['id3v23_rich.mp3', 'id3v23_nopad.mp3', 'opus.opus', 'id3.dsf']) {
      final f = copyFixture(name, tmp);
      final original = f.readAsBytesSync();
      final fd = MmNative.openFd(f.path, writable: true);
      expect(fd, greaterThanOrEqualTo(0));
      try {
        final t = MmTarget.fd(fd, name);
        expect(MmNative.read(t)['props'], isNotEmpty);
        final title = name.contains('nopad') ? '很长的标题' * 20 : 'FD 写入';
        final plan = MmNative.prepareWrite(t, {
          'set': {
            'TITLE': [title],
          },
          'backupPath': '${tmp.path}/fd.bak',
          'stagePath': '${tmp.path}/fd.stage',
        });
        expect(plan['stagePath'], '${tmp.path}/fd.stage');
        MmNative.commit(t, plan);
        expect(MmNative.read(t)['props']['TITLE'], [title]);
        final restore = MmNative.prepareRestore(t, {
          'backupPath': '${tmp.path}/fd.bak',
          'stagePath': '${tmp.path}/fd.stage2',
        });
        MmNative.commit(t, restore);
      } finally {
        // The native side never closes caller descriptors.
        expect(MmNative.closeFd(fd), 0);
      }
      expect(f.readAsBytesSync(), original, reason: name);
    }
  });

  test('long and unicode paths', () {
    var dir = tmp;
    while (dir.path.length < 300) {
      dir = Directory('${dir.path}/很长的目录名称_${'x' * 20}')..createSync();
    }
    final f = copyFixture('rich.flac', dir, as: '周杰伦 - 晴天 🎵.flac');
    expect(f.path.length, greaterThan(300));
    final plan = MmNative.prepareWrite(MmTarget.path(f.path), {
      'set': {
        'TITLE': ['长路径'],
      },
    });
    MmNative.commit(MmTarget.path(f.path), plan);
    expect(MmNative.read(MmTarget.path(f.path))['props']['TITLE'], ['长路径']);
  });
}
