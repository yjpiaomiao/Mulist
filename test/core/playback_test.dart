import 'package:flutter_test/flutter_test.dart';
import 'package:music_manager/core/model/track.dart';
import 'package:music_manager/core/playback/playback_controller.dart';

import '../support/fake_audio_engine.dart';

const tracks = [
  TrackRow(id: 1, rootId: 1, relPath: '中文 #1.flac', sampleRate: 96000, bitDepth: 24),
  TrackRow(id: 2, rootId: 1, relPath: 'two.flac'),
  TrackRow(id: 3, rootId: 1, relPath: 'three.flac'),
];

void main() {
  late PlaybackController player;
  late List<FakeAudioEngine> engines;
  late Set<int> unavailable;
  setUp(() {
    engines = [];
    unavailable = {};
    player = PlaybackController(
      createEngine: () {
        final engine = FakeAudioEngine();
        engines.add(engine);
        return engine;
      },
      resolvePath: (id) async => unavailable.contains(id) ? null : '/music/${tracks[id - 1].relPath}',
    );
  });
  tearDown(() async {
    player.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  test('queue is a snapshot; rapid next commands execute in order', () async {
    final library = [...tracks];
    await player.playTracks(library);
    library.clear();
    await Future.wait([player.next(), player.next()]);
    expect(player.current?.id, 3);
    expect(engines.single.opened, tracks.map((t) => '/music/${t.relPath}'));
    expect(player.queue.length, 3);
    expect(player.playing, isTrue);
  });

  test('EOF advances once; final track ends without wrapping', () async {
    await player.playTracks(tracks);
    engines.single.emit(completed: true);
    engines.single.emit(completed: true);
    await Future<void>.delayed(Duration.zero);
    expect(player.current?.id, 2);
    await player.next();
    final count = engines.single.opened.length;
    engines.single.isPlaying = false;
    engines.single.emit(completed: true);
    await Future<void>.delayed(Duration.zero);
    expect(engines.single.opened.length, count);
    expect(player.current?.id, 3);
    expect(player.playing, isFalse);
  });

  test('single repeat applies to EOF, manual next still advances', () async {
    await player.playTracks(tracks);
    player.cycleRepeat();
    player.cycleRepeat();
    engines.single.emit(completed: true);
    await Future<void>.delayed(Duration.zero);
    expect(player.current?.id, 1);
    expect(engines.single.opened.length, 2);
    await player.next();
    expect(player.current?.id, 2);
  });

  test('missing path stops old audio; errors do not poison later commands', () async {
    await player.playTracks(tracks);
    unavailable.add(2);
    await player.next();
    expect(player.error, contains('playback_path_unavailable'));
    expect(player.playing, isFalse);
    await player.next();
    expect(player.current?.id, 3);
    expect(player.error, isNull);
    expect(player.playing, isTrue);
  });

  test('output changes preserve pause/position and fix exclusive gain to unity', () async {
    await player.playTracks(tracks);
    await player.seek(const Duration(seconds: 42));
    await player.toggle();
    await player.setOutput(exclusiveMode: true);
    expect(engines.length, 2);
    expect(engines.first.commands, contains('dispose'));
    expect(engines.last.commands, contains('init:true:auto'));
    expect(engines.last.commands, contains('volume:100.0'));
    expect(player.audio.position.inSeconds, 42);
    expect(player.playing, isFalse);
    await player.setVolume(25);
    expect(engines.last.commands, isNot(contains('volume:25.0')));
  });

  test('rejected exclusive mode restores working output and reports failure', () async {
    player.dispose();
    engines.clear();
    player = PlaybackController(
      createEngine: () {
        final e = FakeAudioEngine()..failExclusive = true;
        engines.add(e);
        return e;
      },
      resolvePath: (id) async => '/music/test.flac',
    );
    await player.playTracks(tracks);
    await player.seek(const Duration(seconds: 12));
    await player.setOutput(exclusiveMode: true);
    expect(player.exclusive, isFalse);
    expect(player.error, contains('device_rejected'));
    expect(player.playing, isTrue);
    expect(player.audio.position.inSeconds, 12);
  });

  test('seek clamps bounds; previous restarts after three seconds', () async {
    await player.playTracks(tracks, start: 1);
    await player.seek(const Duration(minutes: 8));
    expect(player.audio.position, const Duration(minutes: 4));
    await player.previous();
    expect(player.current?.id, 2);
    expect(player.audio.position, Duration.zero);
    await player.previous();
    expect(player.current?.id, 1);
  });

  test('failure opening the output during play restores the previous mode', () async {
    player.dispose();
    engines.clear();
    player = PlaybackController(
      createEngine: () {
        final e = FakeAudioEngine()..failPlay = engines.length == 1;
        engines.add(e);
        return e;
      },
      resolvePath: (id) async => '/music/test.flac',
    );
    await player.playTracks(tracks);
    await player.seek(const Duration(seconds: 9));
    await player.setOutput(exclusiveMode: true);
    expect(player.exclusive, isFalse);
    expect(player.error, contains('output_open_failed'));
    expect(player.playing, isTrue);
    expect(player.audio.position.inSeconds, 9);
    expect(engines[1].commands, containsAllInOrder(['stop', 'stop', 'dispose']));
  });
}
