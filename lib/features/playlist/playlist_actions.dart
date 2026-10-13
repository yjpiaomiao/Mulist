import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/l10n.dart';
import '../../app/scope.dart';
import '../../core/services/playlists.dart';
import '../actions.dart';

Future<void> createPlaylist(BuildContext context, {List<int> tracks = const []}) async {
  final s = S.of(context);
  final app = AppScope.read(context);
  final name = await askText(context, s.newPlaylist, label: s.playlistName);
  if (name == null || name.isEmpty) return;
  final id = await app.core.call<int>('playlistCreate', {'name': name, 'tracks': tracks});
  await app.setSource(PlaylistTracks(id));
}

Future<void> renamePlaylist(BuildContext context, PlaylistInfo p) async {
  final s = S.of(context);
  final name = await askText(context, s.renamePlaylist, initial: p.name, label: s.playlistName);
  if (name == null || name.isEmpty || !context.mounted) return;
  await AppScope.read(context).core.call<void>('playlistRename', {'id': p.id, 'name': name});
}

Future<void> deletePlaylist(BuildContext context, PlaylistInfo p) async {
  final s = S.of(context);
  if (!await confirm(context, s.deletePlaylistConfirm(p.name), action: s.delete) || !context.mounted) return;
  final app = AppScope.read(context);
  await app.core.call<void>('playlistDelete', p.id);
  if (app.source == PlaylistTracks(p.id)) await app.setSource(const AllTracks());
}

Future<void> exportPlaylist(BuildContext context, PlaylistInfo p) async {
  final ids = await AppScope.read(context).core.call<List<int>>('playlistTrackIds', p.id);
  if (context.mounted) await exportTracks(context, ids, playlistId: p.id, name: p.name);
}

/// Removes the selected tracks from the shown playlist.
Future<void> removeFromPlaylist(BuildContext context, int playlistId, Set<int> trackIds) async {
  final app = AppScope.read(context);
  final items = await app.core.call<List<PlaylistEntry>>('playlistItems', playlistId);
  final keep = [for (final e in items) if (e.trackId == null || !trackIds.contains(e.trackId)) e.pos];
  await app.core.call<void>('playlistReorder', {'id': playlistId, 'positions': keep});
  app.selection.clear();
}

List<PopupMenuEntry<void Function()>> playlistMenu(BuildContext context, PlaylistInfo p) {
  final s = S.of(context);
  return [
    PopupMenuItem(value: () => exportPlaylist(context, p), child: Text(s.exportPlaylist)),
    PopupMenuItem(value: () => renamePlaylist(context, p), child: Text(s.renamePlaylist)),
    PopupMenuItem(value: () => deletePlaylist(context, p), child: Text(s.deletePlaylist)),
  ];
}

/// Playlist list (phone tab).
class PlaylistsPane extends StatelessWidget {
  final VoidCallback onOpened;
  const PlaylistsPane({super.key, required this.onOpened});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.playlists), actions: [
        IconButton(icon: const Icon(Icons.add), tooltip: s.newPlaylist, onPressed: () => createPlaylist(context)),
      ]),
      body: app.playlists.isEmpty
          ? Center(child: Text(s.noPlaylists))
          : ListView(children: [
              for (final p in app.playlists)
                ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(p.name),
                  subtitle: Text(s.tracksCount(p.count)),
                  onTap: () async {
                    await app.setSource(PlaylistTracks(p.id));
                    onOpened();
                  },
                  trailing: PopupMenuButton<void Function()>(onSelected: (f) => f(), itemBuilder: (ctx) => playlistMenu(ctx, p)),
                ),
            ]),
    );
  }
}
