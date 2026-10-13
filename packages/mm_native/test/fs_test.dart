import 'dart:io';

import 'package:mm_native/mm_native.dart';
import 'package:test/test.dart';

void main() {
  test('listDir and realPath', () {
    final tmp = Directory.systemTemp.createTempSync('mm_fs_');
    try {
      File('${tmp.path}/a.mp3').writeAsBytesSync([1, 2, 3]);
      File('${tmp.path}/.hidden').writeAsStringSync('x');
      Directory('${tmp.path}/子目录').createSync();
      final e = {for (final x in MmNative.listDir(tmp.path)) x['n']: x};
      expect(e.keys.toSet(), {'a.mp3', '.hidden', '子目录'});
      expect(e['a.mp3']!['s'], 3);
      expect(e['a.mp3']!['d'], isFalse);
      expect(e['子目录']!['d'], isTrue);
      expect(e['.hidden']!['h'], isTrue);
      expect((e['a.mp3']!['m'] as int) ~/ 1000, File('${tmp.path}/a.mp3').lastModifiedSync().microsecondsSinceEpoch);
      expect(MmNative.realPath('${tmp.path}/子目录'), isNotNull);
      expect(MmNative.stat('${tmp.path}/a.mp3'), {'ok': true, 'exists': true, 'd': false, 's': 3, 'm': e['a.mp3']!['m']});
      expect(MmNative.stat('${tmp.path}/nope')['exists'], isFalse);
      expect(MmNative.realPath('${tmp.path}/nope'), isNull);
      expect(() => MmNative.listDir('${tmp.path}/nope/x'), throwsA(isA<MmException>()));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
