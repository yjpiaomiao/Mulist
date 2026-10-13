import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/app_state.dart';
import 'app/l10n.dart';
import 'app/scope.dart';
import 'app/shell.dart';
import 'app/theme.dart';
import 'core/services/core_context.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Thumbnails are small; keep the decoded image cache modest.
  PaintingBinding.instance.imageCache
    ..maximumSize = 400
    ..maximumSizeBytes = 48 << 20;
  final state = AppState();
  runApp(MusicManagerApp(state: state));
  await state.init();
}

class MusicManagerApp extends StatelessWidget {
  final AppState state;
  const MusicManagerApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: Builder(builder: (context) {
        final app = AppScope.watch(context);
        final lang = app.ready ? app.setting(SettingKeys.language) : 'system';
        final forced = lang == 'zh' ? const Locale('zh') : (lang == 'en' ? const Locale('en') : null);
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          onGenerateTitle: (ctx) => S.of(ctx).appName,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: ThemeMode.system,
          locale: forced,
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: [
            SDelegate(forced),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: app.ready ? const AppShell() : const Scaffold(body: SizedBox.shrink()),
        );
      }),
    );
  }
}
