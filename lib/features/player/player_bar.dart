import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/l10n.dart';
import '../../app/scope.dart';
import '../../app/theme.dart';
import '../../core/model/track.dart';
import '../../core/playback/playback_controller.dart';
import '../library/cover.dart';

String sampleRateLabel(int hz) => hz % 1000 == 0 ? '${hz ~/ 1000} kHz' : '${hz / 1000} kHz';

String sourceQuality(TrackRow? track) => track == null
    ? ''
    : [
        track.ext.toUpperCase(),
        if (track.bitDepth > 0) '${track.bitDepth}-bit',
        if (track.sampleRate > 0) sampleRateLabel(track.sampleRate),
        if (track.bitDepth == 0 && track.bitrate > 0) '${track.bitrate} kbps',
      ].join(' · ');

String _repeatLabel(S s, PlaybackRepeat mode) => switch (mode) {
  PlaybackRepeat.off => s.repeatOff,
  PlaybackRepeat.all => s.repeatAll,
  PlaybackRepeat.one => s.repeatOne,
};

/// Persistent, flat transport. Its own listener keeps position ticks from
/// rebuilding the library or disturbing keyboard/selection state.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final player = AppScope.read(context).playback;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final s = S.of(context);
        final colors = Theme.of(context).colorScheme;
        return Material(
          color: colors.surfaceContainerLow,
          child: Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (player.error != null)
                    Container(
                      color: colors.errorContainer,
                      padding: const EdgeInsets.only(left: 16, right: 4),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline, size: 16, color: colors.onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Tooltip(
                              message: player.error!,
                              child: Text(
                                player.error!.contains('playback_path_unavailable')
                                    ? s.playbackPathUnavailable
                                    : s.playbackFailed,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: colors.onErrorContainer),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: s.close,
                            onPressed: player.dismissError,
                            icon: const Icon(Icons.close, size: 16),
                          ),
                        ],
                      ),
                    ),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth >= 1000) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                          child: Row(
                            children: [
                              Expanded(flex: 3, child: _TrackInfo(player: player)),
                              const SizedBox(width: 24),
                              Expanded(
                                flex: 4,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _Transport(player: player),
                                    _Timeline(player: player),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 24),
                              Expanded(
                                flex: 3,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        _OutputButton(player: player),
                                        IconButton(
                                          tooltip: s.queue,
                                          onPressed: () => showPlayQueue(context),
                                          icon: const Icon(Icons.queue_music_rounded, size: 22),
                                        ),
                                      ],
                                    ),
                                    SizedBox(width: 184, child: _Volume(player: player)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Expanded(child: _TrackInfo(player: player, small: true)),
                                if (constraints.maxWidth >= 600)
                                  _Transport(player: player)
                                else ...[
                                  _PlayButton(player: player),
                                  IconButton(
                                    tooltip: s.nextTrack,
                                    onPressed: player.hasNext && !player.busy ? player.next : null,
                                    icon: const Icon(Icons.skip_next_rounded),
                                  ),
                                ],
                                IconButton(
                                  tooltip: s.queue,
                                  onPressed: () => showPlayQueue(context),
                                  icon: const Icon(Icons.queue_music_rounded),
                                ),
                                IconButton(
                                  tooltip: s.outputSettings,
                                  onPressed: () => showAudioOutput(context),
                                  icon: const Icon(Icons.tune_rounded, size: 21),
                                ),
                              ],
                            ),
                            _Timeline(player: player),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TrackInfo extends StatelessWidget {
  final PlaybackController player;
  final bool small;
  const _TrackInfo({required this.player, this.small = false});
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final colors = Theme.of(context).colorScheme;
    final track = player.current;
    return Row(
      children: [
        CoverThumb(hash: track?.coverHash, size: small ? 42 : 56, radius: 8),
        SizedBox(width: small ? 10 : 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                track?.displayTitle ?? s.chooseToPlay,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: small ? 13 : 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 3),
              Text(
                track == null ? s.playHint : [track.artist, track.album].where((v) => v.isNotEmpty).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
              ),
              if (!small && track != null) ...[
                const SizedBox(height: 5),
                InkWell(
                  onTap: () => showAudioOutput(context),
                  borderRadius: BorderRadius.circular(4),
                  child: Text(
                    sourceQuality(track),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: colors.primary,
                      fontWeight: FontWeight.w600,
                      letterSpacing: .3,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PlayButton extends StatelessWidget {
  final PlaybackController player;
  const _PlayButton({required this.player});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    final s = S.of(context);
    return IconButton.filled(
      tooltip: player.playing ? s.pause : s.play,
      onPressed: player.busy || (player.current == null && app.view.isEmpty)
          ? null
          : () {
              if (player.current == null) {
                app.playTrack(app.focused ?? app.view.first);
              } else {
                player.toggle();
              }
            },
      style: IconButton.styleFrom(minimumSize: const Size(42, 42), maximumSize: const Size(42, 42)),
      icon: player.busy || player.audio.buffering
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 26),
    );
  }
}

class _Transport extends StatelessWidget {
  final PlaybackController player;
  const _Transport({required this.player});
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: s.shuffle,
          isSelected: player.shuffle,
          onPressed: player.toggleShuffle,
          selectedIcon: const Icon(Icons.shuffle_rounded, size: 19),
          icon: const Icon(Icons.shuffle_rounded, size: 19),
        ),
        IconButton(
          tooltip: s.previousTrack,
          onPressed: player.current != null && !player.busy ? player.previous : null,
          icon: const Icon(Icons.skip_previous_rounded, size: 26),
        ),
        const SizedBox(width: 6),
        _PlayButton(player: player),
        const SizedBox(width: 6),
        IconButton(
          tooltip: s.nextTrack,
          onPressed: player.hasNext && !player.busy ? player.next : null,
          icon: const Icon(Icons.skip_next_rounded, size: 26),
        ),
        IconButton(
          tooltip: _repeatLabel(s, player.repeat),
          isSelected: player.repeat != PlaybackRepeat.off,
          onPressed: player.cycleRepeat,
          icon: Icon(player.repeat == PlaybackRepeat.one ? Icons.repeat_one_rounded : Icons.repeat_rounded, size: 19),
        ),
      ],
    );
  }
}

class _Timeline extends StatefulWidget {
  final PlaybackController player;
  const _Timeline({required this.player});
  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  double? _drag;
  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    final max = p.duration.inMilliseconds.toDouble();
    final value = (_drag ?? p.audio.position.inMilliseconds.toDouble()).clamp(0.0, max > 0 ? max : 1.0);
    final style = TextStyle(
      fontSize: 10,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          SizedBox(
            width: 38,
            child: Text(formatDuration(value.round()), style: style, textAlign: TextAlign.center),
          ),
          Expanded(
            child: Semantics(
              label: S.of(context).seekPlayback,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: value,
                  max: max > 0 ? max : 1,
                  onChanged: max > 0 && p.current != null && !p.busy ? (v) => setState(() => _drag = v) : null,
                  onChangeEnd: (v) async {
                    await p.seek(Duration(milliseconds: v.round()));
                    if (mounted) setState(() => _drag = null);
                  },
                ),
              ),
            ),
          ),
          SizedBox(
            width: 38,
            child: Text(formatDuration(max.round()), style: style, textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }
}

class _Volume extends StatelessWidget {
  final PlaybackController player;
  const _Volume({required this.player});
  @override
  Widget build(BuildContext context) => Tooltip(
    message: player.exclusive ? S.of(context).exclusiveVolume : S.of(context).volume,
    child: SizedBox(
      height: 30,
      child: Row(
        children: [
          Icon(player.exclusive ? Icons.lock_outline_rounded : Icons.volume_up_outlined, size: 17),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context)
                  .copyWith(trackHeight: 2, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4)),
              child: Slider(
                value: player.exclusive ? 100 : player.volume,
                max: 100,
                onChanged: player.exclusive ? null : player.setVolume,
              ),
            ),
          ),
          SizedBox(
            width: 28,
            child: Text('${player.exclusive ? 100 : player.volume.round()}', style: const TextStyle(fontSize: 10)),
          ),
        ],
      ),
    ),
  );
}

class _OutputButton extends StatelessWidget {
  final PlaybackController player;
  const _OutputButton({required this.player});
  @override
  Widget build(BuildContext context) => Flexible(
    child: TextButton.icon(
      onPressed: () => showAudioOutput(context),
      icon: const Icon(Icons.speaker_outlined, size: 17),
      label: Text(
        player.exclusive ? S.of(context).exclusiveOutput : S.of(context).sharedOutput,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
    ),
  );
}

Future<void> showAudioOutput(BuildContext context) async {
  final player = AppScope.read(context).playback;
  await showDialog<void>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: player,
      builder: (ctx, _) {
        final s = S.of(ctx);
        final colors = Theme.of(ctx).colorScheme;
        final devices = {for (final d in player.audio.devices) d.id: d.name};
        devices.putIfAbsent('auto', () => s.systemDefault);
        devices.putIfAbsent(player.device, () => player.device);
        final output = player.audio;
        final mismatch =
            (player.current?.sampleRate ?? 0) > 0 &&
            output.outputRate > 0 &&
            player.current!.sampleRate != output.outputRate;
        return AlertDialog(
          title: Text(s.outputSettings),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.sourceAudio, style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
                        const SizedBox(height: 5),
                        Text(
                          player.current == null ? '—' : sourceQuality(player.current),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 16),
                        Text(s.actualOutput, style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
                        const SizedBox(height: 5),
                        Text(
                          output.outputRate == 0
                              ? s.waitingOutput
                              : [
                                  sampleRateLabel(output.outputRate),
                                  output.outputFormat,
                                  output.outputChannels,
                                  output.driver,
                                ].where((x) => x.isNotEmpty).join(' · '),
                        ),
                        if (mismatch)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(s.outputMismatch, style: TextStyle(fontSize: 12, color: colors.error)),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  DropdownButtonFormField<String>(
                    key: ValueKey(player.device),
                    initialValue: player.device,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: s.outputDevice),
                    items: [
                      for (final e in devices.entries)
                        DropdownMenuItem(
                          value: e.key,
                          child: Text(e.key == 'auto' ? s.systemDefault : e.value, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: player.busy
                        ? null
                        : (v) {
                            if (v != null) player.setOutput(deviceId: v);
                          },
                  ),
                  if (Platform.isMacOS || Platform.isWindows) ...[
                    const SizedBox(height: 16),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(s.exclusiveOutput, style: const TextStyle(fontSize: 14)),
                      value: player.exclusive,
                      onChanged: player.busy ? null : (v) => player.setOutput(exclusiveMode: v),
                    ),
                    Text(s.exclusiveHint, style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
                  ],
                  const SizedBox(height: 16),
                  _Volume(player: player),
                  const SizedBox(height: 16),
                  Text(s.qualityHint, style: TextStyle(fontSize: 12, height: 1.6, color: colors.onSurfaceVariant)),
                  if (player.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(s.playbackFailed, style: TextStyle(color: colors.error)),
                    ),
                ],
              ),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.close))],
        );
      },
    ),
  );
}

Future<void> showPlayQueue(BuildContext context) async {
  final player = AppScope.read(context).playback;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (ctx) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(ctx).height * .65,
        child: ListenableBuilder(
          listenable: player,
          builder: (ctx, _) {
            final s = S.of(ctx);
            final colors = Theme.of(ctx).colorScheme;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('${s.queue} · ${player.queue.length}', style: Theme.of(ctx).textTheme.titleMedium),
                      ),
                      IconButton(
                        tooltip: s.shuffle,
                        isSelected: player.shuffle,
                        onPressed: player.toggleShuffle,
                        icon: const Icon(Icons.shuffle_rounded),
                      ),
                      IconButton(
                        tooltip: _repeatLabel(s, player.repeat),
                        isSelected: player.repeat != PlaybackRepeat.off,
                        onPressed: player.cycleRepeat,
                        icon: Icon(
                          player.repeat == PlaybackRepeat.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                        ),
                      ),
                      IconButton(
                        tooltip: s.stopPlayback,
                        onPressed: player.current == null ? null : player.stop,
                        icon: const Icon(Icons.stop_rounded),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(),
                Expanded(
                  child: player.queue.isEmpty
                      ? Center(child: Text(s.chooseToPlay))
                      : ListView.builder(
                          itemCount: player.queue.length,
                          itemBuilder: (ctx, i) {
                            final t = player.queue[i];
                            return ListTile(
                              selected: player.index == i,
                              selectedTileColor: colors.secondaryContainer,
                              leading: SizedBox(
                                width: 32,
                                child: Center(
                                  child: player.index == i
                                      ? Icon(player.playing ? Icons.graphic_eq_rounded : Icons.pause_rounded, size: 20)
                                      : Text('${i + 1}', style: const TextStyle(fontSize: 12)),
                                ),
                              ),
                              title: Text(t.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                [t.artist, sourceQuality(t)].where((v) => v.isNotEmpty).join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Text(formatDuration(t.durationMs), style: const TextStyle(fontSize: 12)),
                              onTap: player.busy ? null : () => player.jump(i),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
