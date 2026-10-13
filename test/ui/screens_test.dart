// Renders the main screens with a real library and writes PNG screenshots
// to build/screens (visual check of the desktop / medium / phone layouts).
// Also a smoke test: every screen builds without errors.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_manager/app/app_state.dart';
import 'package:music_manager/core/model/library_root.dart';
import 'package:music_manager/core/scan/scanner.dart';
import 'package:music_manager/core/services/core_context.dart';
import 'package:music_manager/features/actions.dart';
import 'package:music_manager/features/history/history_page.dart';
import 'package:music_manager/features/settings/settings_page.dart';
import 'package:music_manager/main.dart';

const fixtures = 'packages/mm_native/test/fixtures';

Future<void> loadFonts() async {
  Future<void> load(String family, String path) async {
    final f = File(path);
    if (!f.existsSync()) return;
    final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    await loader.load();
  }

  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  await load('MaterialIcons', '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  await load('Noto Sans SC', r'C:\Windows\Fonts\NotoSansSC-VF.ttf');
  await load('Microsoft YaHei UI', r'C:\Windows\Fonts\msyh.ttc');
  await load('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc');
  await load('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf');
  await load('monospace', r'C:\Windows\Fonts\consola.ttf');
}

void main() {
  final key = GlobalKey();
  late Directory tmp;
  late AppState state;
  final outDir = Directory('build/screens');

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      // Let file images (thumbnails) and isolate replies arrive.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${outDir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('screens', (tester) async {
    await tester.runAsync(() async {
      await loadFonts();
      outDir.createSync(recursive: true);
      tmp = Directory.systemTemp.createTempSync('mm_ui_');
      final lib = Platform.environment['MM_BENCH_LIB'] ?? '${tmp.path}/lib';
      if (!Directory(lib).existsSync()) {
        Directory('$lib/周杰伦/叶惠美').createSync(recursive: true);
        for (final (i, n) in ['id3v23_rich.mp3', 'rich.flac', 'aac.m4a', 'vorbis.ogg', 'id3.dsf', 'three_tags.mp3', 'opus.opus'].indexed) {
          File('$fixtures/$n').copySync('$lib/周杰伦/叶惠美/0${i + 1} $n');
        }
      }
      state = AppState();
      await state.init(testPaths: CorePaths('${tmp.path}/data', '${tmp.path}/cache'));
      await state.setSetting(SettingKeys.language, 'zh');
      final root = await state.core.call<LibraryRoot>('addRoot', {'kind': 'path', 'locator': lib, 'display': lib});
      state.roots = [root];
      final done = state.finished.stream.firstWhere((e) => e is ScanDone);
      state.rescan(root);
      await done;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await state.refreshView();
      await state.core.call<int>('playlistCreate', {'name': '我喜欢的', 'tracks': state.view.take(20).toList()});
      await state.core.call<int>('playlistCreate', {'name': 'Road trip', 'tracks': state.view.skip(30).take(12).toList()});
    });
    expect(state.view, isNotEmpty);

    Future<void> size(double w, double h) async {
      tester.view.physicalSize = Size(w, h);
      tester.view.devicePixelRatio = 1;
      await tester.pump();
    }

    addTearDown(tester.view.reset);
    await size(1440, 900);
    await tester.pumpWidget(RepaintBoundary(key: key, child: MusicManagerApp(state: state)));
    await tester.pump(const Duration(milliseconds: 300));
    await shot(tester, '01_desktop_list');

    final firstId = state.view[2];
    state.selection.only(firstId);
    state.focus(firstId);
    state.selection.range(state.view, state.view[6]);
    await shot(tester, '02_desktop_selection_detail');

    await tester.runAsync(() => state.setQuery('zh'));
    await shot(tester, '03_desktop_search_pinyin');
    await tester.runAsync(() => state.setQuery(''));

    state.setViewMode(ViewMode.grid);
    await shot(tester, '04_desktop_grid');
    state.setViewMode(ViewMode.list);

    // Tag editor (batch) dialog.
    final ctx = tester.element(find.byType(Scaffold).first);
    editTags(ctx, state.selectedInOrder());
    await tester.pump();
    await shot(tester, '05_desktop_tag_editor_batch');
    Navigator.of(ctx, rootNavigator: true).pop();
    await tester.pump(const Duration(milliseconds: 400));

    // Rename page with preview.
    renameFiles(ctx, state.view.take(200).toList());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '06_desktop_rename_preview');
    Navigator.of(ctx, rootNavigator: true).pop();
    await tester.pump(const Duration(milliseconds: 400));

    // Export dialog.
    exportTracks(ctx, state.view.take(20).toList(), name: '我喜欢的');
    await tester.pump();
    await shot(tester, '07_desktop_export');
    Navigator.of(ctx, rootNavigator: true).pop();
    await tester.pump(const Duration(milliseconds: 400));

    // Settings and history as pages.
    Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '08_settings');
    Navigator.of(ctx).pop();
    await tester.pump(const Duration(milliseconds: 400));
    Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => const HistoryPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '09_history');
    Navigator.of(ctx).pop();
    await tester.pump(const Duration(milliseconds: 400));

    // Medium and phone layouts.
    await size(820, 1000);
    await shot(tester, '10_medium');
    await size(390, 844);
    state.selection.clear();
    await shot(tester, '11_phone_list');
    await tester.longPress(find.byType(InkWell).at(6));
    await tester.pump();
    state.selection.addAll(state.view.take(3));
    await shot(tester, '12_phone_selection');
    state.setViewMode(ViewMode.grid);
    await shot(tester, '13_phone_grid');

    // Dark theme.
    await size(1440, 900);
    state.setViewMode(ViewMode.list);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pump();
    // Let the theme (and AnimatedDefaultTextStyle) transition finish.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await shot(tester, '14_desktop_dark');
    expect(tester.takeException(), isNull);
  });
}
