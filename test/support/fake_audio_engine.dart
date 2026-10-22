import 'dart:async';

import 'package:music_manager/core/playback/audio_engine.dart';

class FakeAudioEngine implements AudioEngine {
  final events = StreamController<AudioState>.broadcast(sync: true);
  final opened = <String>[];
  final commands = <String>[];
  bool isPlaying = false;
  bool failExclusive = false;
  bool failPlay = false;
  Duration position = Duration.zero;
  @override
  Stream<AudioState> get states => events.stream;
  void emit({bool completed = false, String? error}) => events.add(
    AudioState(
      playing: isPlaying,
      position: position,
      duration: const Duration(minutes: 4),
      completed: completed,
      error: error,
      outputRate: 96000,
      outputFormat: 'float',
      driver: 'coreaudio',
    ),
  );
  @override
  Future<void> initialize({required bool exclusive, required String device}) async {
    if (exclusive && failExclusive) throw StateError('device_rejected');
    commands.add('init:$exclusive:$device');
  }

  @override
  Future<void> open(String path) async {
    opened.add(path);
    position = Duration.zero;
    emit();
  }

  @override
  Future<void> play() async {
    if (failPlay) throw StateError('output_open_failed');
    isPlaying = true;
    commands.add('play');
    emit();
  }

  @override
  Future<void> pause() async {
    isPlaying = false;
    commands.add('pause');
    emit();
  }

  @override
  Future<void> stop() async {
    isPlaying = false;
    commands.add('stop');
    emit();
  }

  @override
  Future<void> seek(Duration target) async {
    position = target;
    commands.add('seek:${target.inSeconds}');
    emit();
  }

  @override
  Future<void> setVolume(double volume) async {
    commands.add('volume:$volume');
  }

  @override
  Future<void> dispose() async {
    commands.add('dispose');
    await events.close();
  }
}
