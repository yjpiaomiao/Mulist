import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

import 'audio_engine.dart';

class MpvAudioEngine implements AudioEngine {
  final _states = StreamController<AudioState>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Player? _player;
  bool _closed = false;
  bool _exclusive = false;
  int _rate = 0;
  String _format = '', _channels = '', _driver = '';
  String? _error;

  @override
  Stream<AudioState> get states => _states.stream;

  void _emit() {
    final p = _player;
    if (_closed || p == null) return;
    final s = p.state;
    _states.add(
      AudioState(
        playing: s.playing,
        buffering: s.buffering,
        completed: s.completed,
        position: s.position,
        duration: s.duration,
        outputRate: _rate,
        outputFormat: _format,
        outputChannels: _channels,
        driver: _driver,
        error: _error,
        devices: [for (final d in s.audioDevices) AudioOutput(d.name, d.description)],
      ),
    );
  }

  @override
  Future<void> initialize({required bool exclusive, required String device}) async {
    _exclusive = exclusive;
    MediaKit.ensureInitialized();
    final p = _player = Player(configuration: const PlayerConfiguration(title: 'Mulist', pitch: false));
    final native = p.platform as NativePlayer;
    // No lossy intermediate encoding, EQ, normalization, fixed resampling,
    // time stretching, or forced stereo downmixing. Negotiate per file.
    final options = <String, String>{
      'vid': 'no',
      'audio-display': 'no',
      'replaygain': 'no',
      'audio-samplerate': '0',
      'audio-channels': 'auto',
      'gapless-audio': 'no',
      'speed': '1',
      'af': '',
      'audio-exclusive': exclusive ? 'yes' : 'no',
      if (Platform.isMacOS) 'ao': exclusive ? 'coreaudio_exclusive' : 'coreaudio',
      if (Platform.isWindows) 'ao': 'wasapi',
      'audio-device': Platform.isMacOS && exclusive && device.startsWith('coreaudio/')
          ? device.replaceFirst('coreaudio/', 'coreaudio_exclusive/')
          : device,
    };
    for (final e in options.entries) {
      await native.setProperty(e.key, e.value);
    }
    if (exclusive && await native.getProperty('audio-exclusive') != 'yes') {
      throw StateError('exclusive_output_unavailable');
    }
    for (final stream in <Stream<dynamic>>[
      p.stream.playing,
      p.stream.buffering,
      p.stream.completed,
      p.stream.position,
      p.stream.duration,
      p.stream.audioDevices,
    ]) {
      _subscriptions.add(stream.listen((_) => _emit()));
    }
    _subscriptions.add(
      p.stream.error.listen((e) {
        _error = e;
        _emit();
      }),
    );
    // Observe scalar sub-properties: node values are not reliably represented
    // as JSON by mpv_get_property_string across libmpv versions.
    await native.observeProperty('audio-out-params/samplerate', (value) async {
      _rate = int.tryParse(value) ?? 0;
      _emit();
    });
    await native.observeProperty('audio-out-params/format', (value) async {
      _format = value;
      _emit();
    });
    await native.observeProperty('audio-out-params/hr-channels', (value) async {
      _channels = value;
      _emit();
    });
    await native.observeProperty('current-ao', (value) async {
      _driver = value;
      _emit();
    });
    _emit();
  }

  @override
  Future<void> open(String path) async {
    if (!await File(path).exists()) throw FileSystemException('playback_file_missing', path);
    _error = null;
    _rate = 0;
    _format = '';
    _channels = '';
    _driver = '';
    await _player!.open(Media(Uri.file(path).toString()), play: false);
  }

  @override
  Future<void> play() async {
    // Opening an mpv file is asynchronous. A successful loadfile command is
    // insufficient evidence that a real output device was opened.
    final ready = Completer<AudioState>();
    final sub = states.listen((value) {
      if (!ready.isCompleted && (value.error != null || (value.outputRate > 0 && value.driver.isNotEmpty))) {
        ready.complete(value);
      }
    });
    try {
      await _player!.play();
      if (_error != null) throw StateError(_error!);
      if (_rate == 0 || _driver.isEmpty) {
        final result = await ready.future.timeout(const Duration(seconds: 10));
        if (result.error != null) throw StateError(result.error!);
      }
      if (_exclusive && Platform.isMacOS && _driver != 'coreaudio_exclusive') {
        throw StateError('exclusive_output_unavailable');
      }
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<void> pause() => _player!.pause();
  @override
  Future<void> stop() => _player!.stop();
  @override
  Future<void> seek(Duration position) => _player!.seek(position);
  @override
  Future<void> setVolume(double volume) => _player!.setVolume(volume);
  @override
  Future<void> dispose() async {
    _closed = true;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    await _player?.dispose();
    await _states.close();
  }
}
