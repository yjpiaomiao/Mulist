import 'package:flutter_test/flutter_test.dart';
import 'package:music_manager/core/path/sanitizer.dart';
import 'package:music_manager/core/template/template.dart';

void main() {
  final values = {
    'title': '晴天',
    'artist': '周杰伦',
    'album': '叶惠美',
    'albumartist': '',
    'track': '3',
    'disc': '',
    'year': '2003',
    'genre': 'Pop/Rock',
    'ext': 'flac',
    'filename': 'old name',
  };
  String r(String t, [Map<String, String>? v]) =>
      RenameTemplate.parse(t).render((k) => (v ?? values)[k] ?? '', fileExt: 'flac').path;

  test('variables, padding, fallbacks, optional sections', () {
    expect(r('{albumartist|artist}/{album}/[{disc}-]{track:2} {title}.{ext}'), '周杰伦/叶惠美/03 晴天.flac');
    expect(r('[{disc}-]{track:3}.{ext}', {...values, 'disc': '2'}), '2-003.flac');
    expect(r('{albumartist|未知艺术家} - {title}.{ext}'), '未知艺术家 - 晴天.flac');
    expect(r('{genre}/{title}.{ext}'), 'Pop／Rock/晴天.flac');
    expect(r('[{year} ]{title}.{ext}'), '2003 晴天.flac');
    expect(r(r'\{{title}\}.{ext}'), '{晴天}.flac');
    expect(r('{TITLE}.{EXT}'), '晴天.flac');
  });

  test('missing variables are reported, empty directories collapse', () {
    final t = RenameTemplate.parse('{albumartist}/{disc}/{title}.{ext}');
    final out = t.render((k) => values[k] ?? '', fileExt: 'flac');
    expect(out.path, '晴天.flac');
    expect(out.missing, {'albumartist', 'disc'});
    expect(t.hasDirectories, isTrue);
  });

  test('sanitizes each segment', () {
    final out = RenameTemplate.parse('{title}.{ext}')
        .render((k) => {'title': ' CON ', 'ext': 'mp3'}[k] ?? '', fileExt: 'mp3');
    expect(out.path, 'CON_.mp3');
    expect(out.issues, contains(SanitizeIssue.reservedName));
    final dots = RenameTemplate.parse('{title}').render((k) => 'Mr. Brown', fileExt: 'mp3');
    expect(dots.path, 'Mr. Brown');
  });

  test('syntax errors', () {
    for (final bad in ['{title', '{nope}', '[{title}', '{title}]', '}', r'abc\']) {
      expect(() => RenameTemplate.parse(bad), throwsA(isA<TemplateError>()), reason: bad);
    }
  });
}
