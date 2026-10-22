import 'dart:async';

class AudioOutput {
  final String id;
  final String name;
  const AudioOutput(this.id, this.name);
}

/// Decoder and output parameters are deliberately separate: source metadata
/// alone cannot establish the format negotiated with the audio device.
class AudioState {
  final bool playing, buffering, completed;
  final Duration position, duration;
  final int outputRate;
  final String outputFormat, outputChannels, driver;
  final String? error;
  final List<AudioOutput> devices;
  const AudioState({
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.outputRate = 0,
    this.outputFormat = '',
    this.outputChannels = '',
    this.driver = '',
    this.error,
    this.devices = const [],
  });
}

abstract interface class AudioEngine {
  Stream<AudioState> get states;
  Future<void> initialize({required bool exclusive, required String device});
  Future<void> open(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> dispose();
}
