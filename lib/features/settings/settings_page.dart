import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/l10n.dart';
import '../../app/scope.dart';
import '../../core/model/library_root.dart';
import '../../core/services/core_context.dart';
import '../actions.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final app = AppScope.watch(context);
    final scheme = Theme.of(context).colorScheme;
    String v(String k) => app.setting(k);
    Widget header(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(t, style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)),
        );
    return Scaffold(
      appBar: AppBar(title: Text(s.settings)),
      body: ListView(children: [
        header(s.rootsSection),
        for (final r in app.roots) _RootTile(root: r),
        ListTile(
          leading: const Icon(Icons.create_new_folder_outlined),
          title: Text(s.addFolder),
          subtitle: Platform.isAndroid ? Text(s.androidPickerNote) : null,
          onTap: app.addFolder,
        ),
        header(s.settings),
        ListTile(
          title: Text(s.language),
          trailing: DropdownButton<String>(
            value: v(SettingKeys.language),
            underline: const SizedBox.shrink(),
            items: [
              DropdownMenuItem(value: 'system', child: Text(s.followSystem)),
              const DropdownMenuItem(value: 'zh', child: Text('简体中文')),
              const DropdownMenuItem(value: 'en', child: Text('English')),
            ],
            onChanged: (x) => app.setSetting(SettingKeys.language, x!),
          ),
        ),
        ListTile(
          title: Text(s.multiSeparator),
          subtitle: Text('"${v(SettingKeys.multiSeparator)}"'),
          onTap: () async {
            final x = await askText(context, s.multiSeparator, initial: v(SettingKeys.multiSeparator));
            if (x != null && x.trim().isNotEmpty) {
              // Keep surrounding spaces as typed (e.g. "; ").
              await app.setSetting(SettingKeys.multiSeparator, x.endsWith(' ') || x.contains(' ') ? x : '$x ');
            }
          },
        ),
        SwitchListTile(
          title: Text(s.keepMtime),
          value: v(SettingKeys.keepMtime) == 'true',
          onChanged: (x) => app.setSetting(SettingKeys.keepMtime, '$x'),
        ),
        SwitchListTile(
          title: Text(s.wholeFileBackup),
          subtitle: Text(s.wholeFileBackupHint),
          value: v(SettingKeys.wholeFileBackup) == 'true',
          onChanged: (x) => app.setSetting(SettingKeys.wholeFileBackup, '$x'),
        ),
        if (v(SettingKeys.wholeFileBackup) == 'true')
          ListTile(
            title: Text(s.backupLimit),
            trailing: Text(v(SettingKeys.wholeFileBackupLimitMb)),
            onTap: () async {
              final x = await askText(context, s.backupLimit, initial: v(SettingKeys.wholeFileBackupLimitMb));
              if (x != null && int.tryParse(x) != null) await app.setSetting(SettingKeys.wholeFileBackupLimitMb, x);
            },
          ),
        ListTile(
          title: Text(s.ioConcurrency),
          trailing: DropdownButton<String>(
            value: v(SettingKeys.ioConcurrency),
            underline: const SizedBox.shrink(),
            items: [for (final n in ['1', '2', '3', '4']) DropdownMenuItem(value: n, child: Text(n))],
            onChanged: (x) => app.setSetting(SettingKeys.ioConcurrency, x!),
          ),
        ),
        ListTile(
          title: Text(s.illegalChars),
          trailing: DropdownButton<String>(
            value: v(SettingKeys.illegalChars),
            underline: const SizedBox.shrink(),
            items: [
              DropdownMenuItem(value: 'fullWidth', child: Text(s.fullWidthChars)),
              DropdownMenuItem(value: 'underscore', child: Text(s.underscore)),
            ],
            onChanged: (x) => app.setSetting(SettingKeys.illegalChars, x!),
          ),
        ),
        header(s.about),
        ListTile(title: Text(s.appName), subtitle: Text(s.aboutText)),
        const SizedBox(height: 24),
      ]),
    );
  }
}

class _RootTile extends StatelessWidget {
  final LibraryRoot root;
  const _RootTile({required this.root});
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final app = AppScope.watch(context);
    final scan = app.scans[root.id];
    final last = root.lastScanAt == null ? s.neverScanned : s.lastScan(DateTime.fromMillisecondsSinceEpoch(root.lastScanAt!).toString().substring(0, 16));
    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(root.displayPath, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: scan != null
          ? LinearProgressIndicator(value: scan.toParse == 0 ? null : scan.parsed / scan.toParse)
          : Text(last),
      trailing: PopupMenuButton<String>(
        onSelected: (x) async {
          switch (x) {
            case 'scan':
              app.rescan(root);
            case 'full':
              app.rescan(root, full: true);
            case 'cancel':
              app.cancelScan(root.id);
            case 'remove':
              if (await confirm(context, s.removeFolderConfirm(root.displayPath), action: s.delete)) await app.removeRoot(root);
          }
        },
        itemBuilder: (_) => [
          if (scan == null) PopupMenuItem(value: 'scan', child: Text(s.rescan)),
          if (scan == null) PopupMenuItem(value: 'full', child: Text(s.fullRescan)),
          if (scan != null) PopupMenuItem(value: 'cancel', child: Text(s.cancel)),
          PopupMenuItem(value: 'remove', child: Text(s.removeFolder)),
        ],
      ),
    );
  }
}
