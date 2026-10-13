import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

String fixturePath(String name) => 'test/fixtures/$name';

File copyFixture(String name, Directory dir, {String? as}) =>
    File(fixturePath(name)).copySync('${dir.path}/${as ?? name}');

bool? _ffmpeg;

/// MD5 of the demuxed audio packets (stream copy, no decoding), computed by
/// ffmpeg as an independent check that audio data is unchanged. Returns null
/// when ffmpeg is unavailable or cannot demux the file.
String? ffmpegPacketMd5(String path) {
  _ffmpeg ??= () {
    try {
      return Process.runSync('ffmpeg', ['-version']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }();
  if (!_ffmpeg!) return null;
  final r = Process.runSync(
      'ffmpeg', ['-v', 'error', '-i', path, '-map', '0:a', '-c', 'copy', '-f', 'md5', '-'],
      stdoutEncoding: utf8);
  if (r.exitCode != 0) return null;
  final out = (r.stdout as String).trim();
  return out.startsWith('MD5=') ? out : null;
}

/// Fails if temporary stage files were left next to the audio files.
void expectNoStrayFiles(Directory dir, {required Set<String> keep}) {
  final names = dir.listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last);
  expect(names.where((n) => !keep.contains(n)).toList(), isEmpty);
}
