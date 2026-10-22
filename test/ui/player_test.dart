import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_manager/app/app_state.dart';
import 'package:music_manager/core/model/track.dart';
import 'package:music_manager/core/playback/playback_controller.dart';
import 'package:music_manager/features/player/player_bar.dart';
import 'package:music_manager/main.dart';

import '../support/fake_audio_engine.dart';

void main() {
  testWidgets('player controls and responsive screens', (tester) async {
    final boundary = GlobalKey();
    final engine = FakeAudioEngine();
    final player = PlaybackController(createEngine: () => engine, resolvePath: (id) async => '/test/$id.flac');
    final state = AppState(playback: player);
    const tracks = [
      TrackRow(
        id: 1,
        rootId: 1,
        relPath: '01.flac',
        title: '夜曲 · Nocturne',
        artist: '周杰伦',
        album: '十一月的萧邦',
        ext: 'flac',
        sampleRate: 96000,
        bitDepth: 24,
        durationMs: 240000,
      ),
      TrackRow(
        id: 2,
        rootId: 1,
        relPath: '02.m4a',
        title: 'A long title that should stay on a single line in narrow windows',
        artist: 'Various artists',
        album: 'Evening Sessions',
        ext: 'm4a',
        sampleRate: 44100,
        bitDepth: 16,
        durationMs: 180000,
      ),
      TrackRow(
        id: 3,
        rootId: 1,
        relPath: '03.wav',
        title: 'River flows in you',
        artist: 'Yiruma',
        album: 'First Love',
        ext: 'wav',
        sampleRate: 48000,
        bitDepth: 24,
        durationMs: 200000,
      ),
    ];
    state.rows.addEntries(tracks.map((t) => MapEntry(t.id, t)));
    state.view = Int32List.fromList([1, 2, 3]);
    state.settings = {'language': 'zh', 'detailPanel': 'false'};
    state.ready = true;
    addTearDown(() {
      state.dispose();
      tester.view.reset();
    });

    // Flush the controller's initial command future in the test clock before
    // crossing into runAsync for real font/image work.
    await tester.pump();
    await tester.runAsync(() async {
      final flutterRoot = Platform.environment['FLUTTER_ROOT']!;
      for (final entry in {
        'MaterialIcons': '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        'PingFang SC': '/System/Library/Fonts/STHeiti Light.ttc',
        '.AppleSystemUIFont': '/Library/Fonts/Arial Unicode.ttf',
        'Roboto': '/Library/Fonts/Arial Unicode.ttf',
      }.entries) {
        final file = File(entry.value);
        if (!file.existsSync()) continue;
        final loader = FontLoader(entry.key)..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
        await loader.load();
      }
    });
    final start = player.playTracks(tracks);
    await tester.pump();
    await start;
    final seek = player.seek(const Duration(seconds: 48));
    await tester.pump();
    await seek;

    Future<void> capture(String name, double width, {bool dark = false}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MusicManagerApp(state: state),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await render.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('build/screens/player_$name.png')..parent.createSync(recursive: true);
        output.writeAsBytesSync(data!.buffer.asUint8List());
      });
    }

    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await capture('desktop', 1440);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    expect(player.playing, isFalse);
    await tester.tap(find.byTooltip('下一首'));
    await tester.pumpAndSettle();
    expect(player.current?.id, 2);
    await capture('desktop_dark', 1440, dark: true);
    await capture('medium', 820);
    await capture('phone', 390);
    await capture('narrow', 320);
    final ctx = tester.element(find.byType(PlayerBar));
    showAudioOutput(ctx);
    await tester.pumpAndSettle();
    expect(find.text('音频输出'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    showPlayQueue(ctx);
    await tester.pumpAndSettle();
    expect(find.text('播放队列 · 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
