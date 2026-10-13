import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_manager/core/path/path_key.dart';
import 'package:music_manager/core/path/sanitizer.dart';

void main() {
  String seg(String s, {String? ext}) => sanitizeSegment(s, ext: ext).value;

  test('illegal characters', () {
    expect(seg('AC/DC: Live?'), 'AC／DC： Live？');
    expect(sanitizeSegment(r'a<b>|"*\c', mode: IllegalCharMode.underscore).value, 'a_b_____c');
    expect(seg('tab\there\nnew'), 'tab here new');
    expect(seg('nul\u0000x\u007f'), 'nul_x_');
  });

  test('dots and spaces', () {
    expect(seg('  .hidden. . '), 'hidden');
    expect(seg('a   b'), 'a b');
    expect(seg('...'), '_');
    expect(seg('.'), '_');
    expect(seg('..'), '_');
    expect(seg(''), '_');
    expect(seg('name.', ext: 'mp3'), 'name.mp3');
  });

  test('windows reserved names', () {
    for (final n in ['CON', 'con', 'Aux', 'NUL', 'COM1', 'lpt9', 'COM¹', 'LPT³', 'COM0']) {
      expect(isReservedWindowsName(n), isTrue, reason: n);
      expect(seg(n), '${n}_');
    }
    expect(seg('CON', ext: 'mp3'), 'CON_.mp3');
    expect(seg('con.backup', ext: 'flac'), 'con.backup_.flac');
    expect(seg('CONSOLE'), 'CONSOLE');
    expect(seg('COM10'), 'COM10');
  });

  test('NFC', () {
    const nfd = 'Café';
    expect(seg(nfd), 'Café');
    expect(pathKey('A/Café.MP3'), pathKey(r'a\Café.mp3'));
  });

  test('length is limited to 255 UTF-8 bytes at grapheme boundaries', () {
    final long = '晴' * 200; // 600 bytes
    final r = sanitizeSegment(long, ext: 'flac', reserveBytes: 6);
    expect(r.issues, contains(SanitizeIssue.truncated));
    expect(utf8Length(r.value), lessThanOrEqualTo(255 - 6));
    expect(r.value, endsWith('.flac'));
    // Emoji with ZWJ sequences / skin tones are never split.
    const family = '👨‍👩‍👧‍👦';
    final emo = sanitizeSegment(family * 30).value;
    expect(emo.length % family.length, 0);
    expect(utf8Length(emo), lessThanOrEqualTo(255));
  });

  test('random unicode names are always valid', () {
    final rnd = Random(7);
    const pool = 'aZ09 .-_/\:*?"<>|\t\u0000\u007f晴天音乐é́😀👨‍👩‍👧 ¹²³CONPRNAUXNULCOMLPT';
    final chars = pool.runes.toList();
    for (var i = 0; i < 3000; i++) {
      final len = rnd.nextInt(120);
      final s = String.fromCharCodes(List.generate(len, (_) => chars[rnd.nextInt(chars.length)]));
      final v = sanitizeSegment(s, ext: rnd.nextBool() ? 'mp3' : null).value;
      expect(v, isNotEmpty);
      expect(RegExp(r'[\/:*?"<>|\x00-\x1f\x7f]').hasMatch(v), isFalse, reason: v);
      expect(v.startsWith('.') || v.startsWith(' '), isFalse, reason: v);
      final stem = v.endsWith('.mp3') ? v.substring(0, v.length - 4) : v;
      expect(stem.endsWith('.') || stem.endsWith(' '), isFalse, reason: v);
      expect(isReservedWindowsName(v), isFalse, reason: v);
      expect(utf8Length(v), lessThanOrEqualTo(255));
      expect(v, nfc(v));
      expect(v == '.' || v == '..', isFalse);
    }
  });

  test('counter suffix', () {
    expect(withCounter('晴天.flac', 2), '晴天 (2).flac');
    expect(withCounter('noext', 3), 'noext (3)');
  });
}
