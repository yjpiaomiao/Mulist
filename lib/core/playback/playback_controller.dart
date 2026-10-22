import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../model/track.dart';
import 'audio_engine.dart';

enum PlaybackRepeat { off, all, one }

/// Owns an immutable queue snapshot. Searching, selecting or sorting the
/// library never replaces the active playback queue.
class PlaybackController extends ChangeNotifier {
  final AudioEngine Function() createEngine;
  final Future<String?> Function(int id) resolvePath;
  final Random _random;
  PlaybackController({required this.createEngine, required this.resolvePath, Random? random})
    : _random = random ?? Random();

  AudioEngine? _engine;
  StreamSubscription<AudioState>? _subscription;
  Future<void> _pending = Future.value();
  bool _disposed = false;
  bool _opened = false;
  bool busy = false;
  bool exclusive = false;
  bool shuffle = false;
  PlaybackRepeat repeat = PlaybackRepeat.off;
  double volume = 100;
  String device = 'auto';
  String? error;
  AudioState audio = const AudioState();
  List<TrackRow> _queue = const [];
  List<TrackRow> get queue => _queue;
  int index = -1;
  TrackRow? get current => index >= 0 && index < _queue.length ? _queue[index] : null;
  bool get playing => audio.playing;
  Duration get duration =>
      audio.duration > Duration.zero ? audio.duration : Duration(milliseconds: current?.durationMs ?? 0);
  bool get hasNext => _queue.isNotEmpty && (index < _queue.length - 1 || repeat == PlaybackRepeat.all || shuffle);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Serialize commands (including EOF) so rapid next/seek/output changes
  /// cannot open two files concurrently or leave an old stream playing.
  Future<void> _run(Future<void> Function() action) {
    if (_disposed) return Future.value();
    _pending = _pending.then((_) async {
      if (_disposed) return;
      busy = true;
      error = null;
      _notify();
      try {
        await action();
      } catch (e) {
        error = e.toString();
      } finally {
        busy = false;
        _notify();
      }
    });
    return _pending;
  }

  Future<AudioEngine> _ready() async {
    if (_engine != null) return _engine!;
    final engine = createEngine();
    try {
      await engine.initialize(exclusive: exclusive, device: device);
      await engine.setVolume(exclusive ? 100 : volume);
    } catch (_) {
      await engine.dispose();
      rethrow;
    }
    _engine = engine;
    _subscription = engine.states.listen((value) {
      final ended = value.completed && !audio.completed && !busy && _opened;
      audio = value;
      if (value.error != null) error = value.error;
      _notify();
      if (ended) unawaited(_run(() => _next(automatic: true)));
    });
    return engine;
  }

  Future<void> playTracks(Iterable<TrackRow> tracks, {int start = 0}) {
    final snapshot = List<TrackRow>.unmodifiable(tracks.where((t) => t.status != TrackStatus.missing));
    return _run(() async {
      if (snapshot.isEmpty) return;
      _queue = snapshot;
      index = start.clamp(0, snapshot.length - 1);
      await _load();
    });
  }

  Future<void> _load({Duration position = Duration.zero, bool play = true}) async {
    _opened = false;
    if (_engine != null) await _engine!.stop();
    audio = AudioState(devices: audio.devices);
    _notify();
    final track = current;
    if (track == null) return;
    final path = await resolvePath(track.id);
    if (path == null) throw StateError('playback_path_unavailable');
    final engine = await _ready();
    try {
      await engine.open(path);
      if (position > Duration.zero) await engine.seek(position);
      _opened = true;
      if (play) await engine.play();
    } catch (_) {
      _opened = false;
      await engine.stop();
      rethrow;
    }
  }

  Future<void> toggle() => _run(() async {
    if (current == null) return;
    if (!_opened) {
      await _load();
      return;
    }
    if (playing) {
      await _engine!.pause();
    } else {
      if (audio.completed) await _engine!.seek(Duration.zero);
      await _engine!.play();
    }
  });

  Future<void> next() => _run(() => _next(automatic: false));
  Future<void> _next({required bool automatic}) async {
    if (_queue.isEmpty) return;
    if (automatic && repeat == PlaybackRepeat.one) {
      await _load();
      return;
    }
    if (shuffle && _queue.length > 1) {
      index = (index + 1 + _random.nextInt(_queue.length - 1)) % _queue.length;
    } else if (index < _queue.length - 1) {
      index++;
    } else if (repeat == PlaybackRepeat.all) {
      index = 0;
    } else {
      return;
    }
    await _load();
  }

  Future<void> previous() => _run(() async {
    if (current == null) return;
    if (audio.position > const Duration(seconds: 3) && _opened) {
      await _engine!.seek(Duration.zero);
    } else {
      index = index > 0 ? index - 1 : (repeat == PlaybackRepeat.all ? _queue.length - 1 : 0);
      await _load();
    }
  });

  Future<void> jump(int target) => _run(() async {
    if (target < 0 || target >= _queue.length) return;
    index = target;
    await _load();
  });

  Future<void> seek(Duration target) => _run(() async {
    if (!_opened) return;
    final ms = target.inMilliseconds.clamp(0, duration.inMilliseconds);
    await _engine!.seek(Duration(milliseconds: ms));
  });

  Future<void> setVolume(double value) => _run(() async {
    if (exclusive) return;
    volume = value.clamp(0, 100);
    await _engine?.setVolume(volume);
  });

  void toggleShuffle() {
    shuffle = !shuffle;
    _notify();
  }

  void cycleRepeat() {
    repeat = PlaybackRepeat.values[(repeat.index + 1) % PlaybackRepeat.values.length];
    _notify();
  }

  Future<void> setOutput({bool? exclusiveMode, String? deviceId}) => _run(() async {
    final oldExclusive = exclusive;
    final oldDevice = device;
    final position = audio.position;
    final resume = playing;
    exclusive = exclusiveMode ?? exclusive;
    device = deviceId ?? device;
    if (_engine == null) return;
    await _release();
    try {
      await _ready();
      if (current != null) await _load(position: position, play: resume);
    } catch (e) {
      await _release();
      exclusive = oldExclusive;
      device = oldDevice;
      // Restore the last working output rather than silently claiming that
      // exclusive playback succeeded when the device rejected it.
      await _ready();
      if (current != null) await _load(position: position, play: resume);
      rethrow;
    }
  });

  Future<void> stop() => _run(() async {
    await _engine?.stop();
    _opened = false;
    audio = AudioState(devices: audio.devices);
  });

  void dismissError() {
    error = null;
    _notify();
  }

  Future<void> _release() async {
    await _subscription?.cancel();
    _subscription = null;
    final engine = _engine;
    _engine = null;
    _opened = false;
    await engine?.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_pending.then((_) => _release()));
    super.dispose();
  }
}
