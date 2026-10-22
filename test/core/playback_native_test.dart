// Opt-in, real CoreAudio smoke test with a bundled libmpv. Uses silence only.
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:music_manager/core/playback/audio_engine.dart';
import 'package:music_manager/core/playback/mpv_audio_engine.dart';

void main() {
  final library = Platform.environment['MULIST_MPV'];
  final fixture = Platform.environment['MULIST_PLAYBACK_FIXTURE'];
  test('real CoreAudio playback, pause and seek', () async {
    // A headless flutter_tester has no app Frameworks rpath. Preload the
    // bundled dependencies in link order, using the same binaries as the app.
    final frameworks = File(library!).parent.parent.path;
    for (final name in [
      'Avutil',
      'Swresample',
      'Swscale',
      'Mbedcrypto',
      'Mbedx509',
      'Mbedtls',
      'Avcodec',
      'Avformat',
      'Avfilter',
    ]) {
      ffi.DynamicLibrary.open('$frameworks/$name.framework/$name');
    }
    MediaKit.ensureInitialized(libmpv: library);
    final engine = MpvAudioEngine();
    final values = <AudioState>[];
    final sub = engine.states.listen(values.add);
    try {
      await engine.initialize(exclusive: false, device: 'auto');
      await engine.setVolume(0);
      await engine.open(fixture!);
      await engine.play();
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(values.any((s) => s.position > Duration.zero && s.playing), isTrue);
      expect(values.any((s) => s.outputRate > 0 && s.driver == 'coreaudio'), isTrue);
      expect(values.where((s) => s.error != null).map((s) => s.error), isEmpty);
      await engine.pause();
      await engine.seek(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(values.last.playing, isFalse);
      expect(values.last.position.inMilliseconds, closeTo(1000, 200));
      // Kept in the test output to distinguish negotiation from source tags.
      final out = values.lastWhere((s) => s.outputRate > 0);
      // ignore: avoid_print
      print('CoreAudio: ${out.outputRate} Hz, ${out.outputFormat}, ${out.outputChannels}');
    } finally {
      await sub.cancel();
      await engine.dispose();
    }
  }, skip: !Platform.isMacOS || library == null || fixture == null);

  test('real exclusive output negotiates without a shared-output fallback', () async {
    final engine = MpvAudioEngine();
    final values = <AudioState>[];
    final sub = engine.states.listen(values.add);
    try {
      await engine.initialize(exclusive: true, device: 'auto');
      await engine.setVolume(100);
      await engine.open(fixture!);
      await engine.play();
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(values.any((s) => s.playing && s.position > Duration.zero), isTrue);
      expect(values.any((s) => s.driver == 'coreaudio_exclusive' && s.outputRate > 0), isTrue);
      expect(values.where((s) => s.error != null).map((s) => s.error), isEmpty);
      final out = values.lastWhere((s) => s.outputRate > 0);
      // ignore: avoid_print
      print('Exclusive CoreAudio: ${out.outputRate} Hz, ${out.outputFormat}, ${out.outputChannels}');
    } finally {
      await sub.cancel();
      await engine.dispose();
    }
  }, skip: !Platform.isMacOS || library == null || fixture == null);
}
