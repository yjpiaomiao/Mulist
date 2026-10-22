// Operations on a set of tracks shared by menus, toolbars and shortcuts.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/l10n.dart';
import '../app/platform.dart';
import '../app/scope.dart';
import '../app/theme.dart';
import '../core/services/playlists.dart';
import 'editor/tag_editor.dart';
import 'playlist/export_dialog.dart';
import 'rename/rename_page.dart';

bool isCompact(BuildContext context) => LayoutSize.of(MediaQuery.sizeOf(context).width) == LayoutSize.compact;

Future<void> editTags(BuildContext context, List<int> ids) async {
  if (ids.isEmpty) return;
  final page = TagEditor(trackIds: ids);
  if (isCompact(context)) {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page, fullscreenDialog: true));
  } else {
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760), child: page),
      ),
    );
  }
}

Future<void> renameFiles(BuildContext context, List<int> ids) async {
  if (ids.isEmpty) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RenamePage(trackIds: ids), fullscreenDialog: true));
}

Future<void> exportTracks(BuildContext context, List<int> ids, {int? playlistId, String? name}) async {
  if (ids.isEmpty) return;
  await showExportDialog(context, ids, playlistId: playlistId, name: name ?? 'playlist');
}

Future<String?> askText(BuildContext context, String title, {String initial = '', String? label}) {
  final c = TextEditingController(text: initial);
  final s = S.of(context);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(s.ok)),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String message, {String? action}) async {
  final s = S.of(context);
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action ?? s.ok)),
      ],
    ),
  );
  return r == true;
}

void toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
}

Future<void> addToPlaylist(BuildContext context, List<int> ids) async {
  if (ids.isEmpty) return;
  final app = AppScope.read(context);
  final s = S.of(context);
  final choice = await showDialog<Object>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(s.addToPlaylist),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, 'new'),
          child: ListTile(leading: const Icon(Icons.add), title: Text(s.newPlaylist), contentPadding: EdgeInsets.zero),
        ),
        for (final p in app.playlists)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, p),
            child: ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(p.name),
              trailing: Text(s.tracksCount(p.count)),
              contentPadding: EdgeInsets.zero,
            ),
          ),
      ],
    ),
  );
  if (!context.mounted || choice == null) return;
  if (choice == 'new') {
    final name = await askText(context, s.newPlaylist, label: s.playlistName);
    if (name == null || name.isEmpty) return;
    await app.core.call<int>('playlistCreate', {'name': name, 'tracks': ids});
    if (context.mounted) toast(context, s.addedToPlaylist(ids.length, name));
  } else if (choice is PlaylistInfo) {
    await app.core.call<void>('playlistAdd', {'id': choice.id, 'tracks': ids});
    if (context.mounted) toast(context, s.addedToPlaylist(ids.length, choice.name));
  }
}

Future<void> revealTrack(BuildContext context, int id) async {
  final path = await AppScope.read(context).core.call<String?>('physicalPath', id);
  if (path != null) await PlatformIo.reveal(path);
}

Future<void> copyTrackPath(BuildContext context, int id) async {
  final app = AppScope.read(context);
  var path = await app.core.call<String?>('physicalPath', id);
  if (path == null) {
    final f = await app.core.call<Map?>('fileOf', id);
    if (f == null) return;
    path = '${app.rootOf(f['rootId'] as int)?.displayPath ?? ''}/${f['rel']}';
  }
  await Clipboard.setData(ClipboardData(text: path));
}

Future<void> removeFromLibrary(BuildContext context, List<int> ids) async {
  if (ids.isEmpty) return;
  final s = S.of(context);
  if (!await confirm(context, s.removeTracksConfirm(ids.length), action: s.removeFromLibrary)) return;
  if (!context.mounted) return;
  final app = AppScope.read(context);
  app.selection.clear();
  await app.removeFromLibrary(ids);
}

Future<void> undoLast(BuildContext context) async {
  final app = AppScope.read(context);
  try {
    await app.undoLast();
  } catch (e) {
    if (context.mounted) toast(context, S.of(context).error(e.toString()));
  }
}

/// Context menu items for the selected tracks.
List<PopupMenuEntry<void Function()>> trackMenu(BuildContext context, List<int> ids, {int? playlistId}) {
  final s = S.of(context);
  final single = ids.length == 1;
  PopupMenuItem<void Function()> item(IconData icon, String text, void Function() f, {bool enabled = true}) =>
      PopupMenuItem(value: f, enabled: enabled, height: 36, child: Row(children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(text)]));
  return [
    item(Icons.play_arrow_rounded, s.play, () => AppScope.read(context).playSelection(ids), enabled: ids.isNotEmpty),
    const PopupMenuDivider(),
    item(Icons.edit_outlined, s.editTags, () => editTags(context, ids)),
    item(Icons.drive_file_rename_outline, s.renameFiles, () => renameFiles(context, ids)),
    item(Icons.playlist_add, s.addToPlaylist, () => addToPlaylist(context, ids)),
    item(Icons.ios_share, s.exportPlaylist, () => exportTracks(context, ids)),
    if (!Platform.isAndroid) item(Icons.folder_open, s.revealInFiles, () => revealTrack(context, ids.first), enabled: single),
    item(Icons.content_copy, s.copyPath, () => copyTrackPath(context, ids.first), enabled: single),
    const PopupMenuDivider(),
    item(Icons.remove_circle_outline, s.removeFromLibrary, () => removeFromLibrary(context, ids)),
  ];
}

Future<void> showTrackMenu(BuildContext context, Offset position, List<int> ids) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final f = await showMenu<void Function()>(
    context: context,
    position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
    items: trackMenu(context, ids),
  );
  f?.call();
}
