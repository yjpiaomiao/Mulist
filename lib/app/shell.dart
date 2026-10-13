// Adaptive shell: sidebar + table + detail panel + status bar on large
// windows, navigation rail on medium ones, bottom navigation on phones.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/scan/scanner.dart';
import '../core/services/events.dart';
import '../features/actions.dart';
import '../features/detail/detail_panel.dart';
import '../features/history/history_page.dart';
import '../features/library/library_view.dart';
import '../features/playlist/playlist_actions.dart';
import '../features/settings/settings_page.dart';
import 'app_state.dart';
import 'l10n.dart';
import 'scope.dart';
import 'theme.dart';

enum Section { library, playlists, history, settings }

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  Section _section = Section.library;
  final _searchFocus = FocusNode();
  final _search = TextEditingController();
  StreamSubscription<Object>? _finished;
  bool _selectionMode = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _finished ??= AppScope.read(context).finished.stream.listen(_onFinished);
  }

  @override
  void dispose() {
    _finished?.cancel();
    _searchFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onFinished(Object e) {
    if (!mounted) return;
    final s = S.of(context);
    if (e is ScanDone) {
      if (e.error != null) {
        toast(context, e.error!.split('\n').first);
      } else {
        toast(
          context,
          e.cancelled
              ? s.scanCancelled
              : s.scanDone(e.found, e.added, e.updated, e.failed, e.missing, e.elapsedMs / 1000),
        );
      }
      return;
    }
    if (e is! JobFinished) return;
    if (e.error != null) {
      toast(context, s.error(e.error!));
      return;
    }
    final text = s.jobSummary(e.succeeded, e.skipped.where((x) => x.skipped).length, e.failed.length);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('${_jobName(s, e.kind)}: $text'),
        duration: Duration(seconds: e.failed.isEmpty ? 4 : 10),
        action: e.failed.isEmpty && e.skipped.isEmpty
            ? null
            : SnackBarAction(label: s.showDetails, onPressed: () => _showJobDetails(e)),
      ),
    );
  }

  String _jobName(S s, JobKind k) => switch (k) {
    JobKind.tagWrite => s.jobTagWrite,
    JobKind.rename => s.jobRename,
    JobKind.undo => s.jobUndo,
    _ => s.jobExport,
  };

  void _showJobDetails(JobFinished e) {
    final s = S.of(context);
    final app = AppScope.read(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.jobSummary(e.succeeded, e.skipped.length, e.failed.length)),
        content: SizedBox(
          width: 520,
          height: 360,
          child: ListView(
            children: [
              if (e.failed.isNotEmpty) Text(s.failedItems, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              for (final f in e.failed)
                ListTile(dense: true, title: Text(f.label), subtitle: Text(s.error(f.error ?? ''))),
              if (e.skipped.isNotEmpty) Text(s.skippedItems),
              for (final f in e.skipped)
                ListTile(dense: true, title: Text(f.label), subtitle: Text(s.error(f.error ?? ''))),
            ],
          ),
        ),
        actions: [
          if (e.failed.isNotEmpty && e.kind == JobKind.tagWrite && e.batchId != null)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                app.core.call<int>('retry', e.batchId);
              },
              child: Text(s.retryFailed),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.close)),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ shortcuts

  void _moveFocus(int delta, {required bool extend}) {
    final app = AppScope.read(context);
    if (app.view.isEmpty) return;
    var i = app.focused == null ? -1 : app.view.indexOf(app.focused!);
    i = (i + delta).clamp(0, app.view.length - 1);
    final id = app.view[i];
    if (extend) {
      app.selection.anchor ??= app.focused ?? id;
      app.selection.range(app.view, id);
    } else {
      app.selection.only(id);
    }
    app.focus(id);
  }

  Map<ShortcutActivator, VoidCallback> _shortcuts() {
    final app = AppScope.read(context);
    final mac = Platform.isMacOS;
    SingleActivator k(LogicalKeyboardKey key, {bool shift = false}) =>
        SingleActivator(key, control: !mac, meta: mac, shift: shift);
    bool typing() => FocusManager.instance.primaryFocus?.context?.widget is EditableText;
    return {
      k(LogicalKeyboardKey.keyF): () => _searchFocus.requestFocus(),
      k(LogicalKeyboardKey.keyA): () {
        if (!typing()) app.selectAll();
      },
      k(LogicalKeyboardKey.keyZ): () {
        if (!typing()) undoLast(context);
      },
      k(LogicalKeyboardKey.keyE): () => editTags(context, app.selectedInOrder()),
      const SingleActivator(LogicalKeyboardKey.f2): () => renameFiles(context, app.selectedInOrder()),
      const SingleActivator(LogicalKeyboardKey.space): () {
        if (!typing()) app.setSetting('detailPanel', app.setting('detailPanel') == 'true' ? 'false' : 'true');
      },
      const SingleActivator(LogicalKeyboardKey.delete): () {
        if (!typing()) removeFromLibrary(context, app.selectedInOrder());
      },
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (typing()) {
          FocusManager.instance.primaryFocus?.unfocus();
        } else {
          app.selection.clear();
        }
      },
      const SingleActivator(LogicalKeyboardKey.arrowDown): () {
        if (!typing()) _moveFocus(1, extend: false);
      },
      const SingleActivator(LogicalKeyboardKey.arrowUp): () {
        if (!typing()) _moveFocus(-1, extend: false);
      },
      const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true): () {
        if (!typing()) _moveFocus(1, extend: true);
      },
      const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true): () {
        if (!typing()) _moveFocus(-1, extend: true);
      },
      const SingleActivator(LogicalKeyboardKey.enter): () {
        if (!typing() && app.selection.length > 0) editTags(context, app.selectedInOrder());
      },
    };
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final size = LayoutSize.of(MediaQuery.sizeOf(context).width);
    return switch (size) {
      LayoutSize.expanded => _desktop(context, rail: false),
      LayoutSize.medium => _desktop(context, rail: true),
      LayoutSize.compact => _phone(context),
    };
  }

  Widget _content(BuildContext context, {required bool compact, bool drawer = false}) {
    final app = AppScope.watch(context);
    final s = S.of(context);
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: LibraryToolbar(searchFocus: _searchFocus, searchController: _search, compact: compact),
            ),
            Builder(
              builder: (ctx) => IconButton(
                tooltip: s.details,
                isSelected: !drawer && app.setting('detailPanel') == 'true',
                icon: const Icon(Icons.info_outline),
                onPressed: () => drawer
                    ? Scaffold.of(ctx).openEndDrawer()
                    : app.setSetting('detailPanel', app.setting('detailPanel') == 'true' ? 'false' : 'true'),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
        _SelectionBar(compact: compact),
        const Divider(),
        Expanded(child: app.viewMode == ViewMode.grid ? const TrackGrid() : const TrackTable()),
      ],
    );
  }

  Widget _desktop(BuildContext context, {required bool rail}) {
    final app = AppScope.watch(context);
    final s = S.of(context);
    final showDetail = app.setting('detailPanel') == 'true' && _section == Section.library;
    final body = switch (_section) {
      Section.library || Section.playlists => _content(context, compact: false, drawer: rail),
      Section.history => const HistoryPage(),
      Section.settings => const SettingsPage(),
    };
    return CallbackShortcuts(
      bindings: _shortcuts(),
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    if (rail)
                      NavigationRail(
                        leading: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(s.appName, style: Theme.of(context).textTheme.titleSmall),
                        ),
                        selectedIndex: _section.index,
                        labelType: NavigationRailLabelType.all,
                        onDestinationSelected: (i) => setState(() => _section = Section.values[i]),
                        destinations: [
                          NavigationRailDestination(
                            icon: const Icon(Icons.library_music_outlined),
                            label: Text(s.library),
                          ),
                          NavigationRailDestination(icon: const Icon(Icons.queue_music), label: Text(s.playlists)),
                          NavigationRailDestination(icon: const Icon(Icons.history), label: Text(s.history)),
                          NavigationRailDestination(icon: const Icon(Icons.settings_outlined), label: Text(s.settings)),
                        ],
                      )
                    else
                      SizedBox(
                        width: 232,
                        child: _Sidebar(section: _section, onSection: (x) => setState(() => _section = x)),
                      ),
                    const VerticalDivider(width: 1),
                    if (rail && _section == Section.playlists)
                      SizedBox(
                        width: 220,
                        child: _Sidebar(
                          section: Section.library,
                          onSection: (x) => setState(() => _section = x),
                          playlistsOnly: true,
                        ),
                      ),
                    if (rail && _section == Section.playlists) const VerticalDivider(width: 1),
                    Expanded(child: body),
                    if (showDetail && !rail) ...[
                      const VerticalDivider(width: 1),
                      SizedBox(width: 320, child: DetailPanel(trackId: app.focused)),
                    ],
                  ],
                ),
              ),
              const _StatusBar(),
            ],
          ),
          endDrawer: rail
              ? Drawer(
                  width: 340,
                  child: SafeArea(child: DetailPanel(trackId: app.focused)),
                )
              : null,
        ),
      ),
    );
  }

  Widget _phone(BuildContext context) {
    final app = AppScope.watch(context);
    final s = S.of(context);
    final selecting = _selectionMode;
    Widget library = ListenableBuilder(
      listenable: app.selection,
      builder: (context, _) {
        final ids = app.selectedInOrder();
        return Scaffold(
          appBar: selecting
              ? AppBar(
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      app.selection.clear();
                      setState(() => _selectionMode = false);
                    },
                  ),
                  title: Text(s.selectedCount(app.selection.length)),
                  actions: [
                    TextButton(onPressed: app.selectAll, child: Text(s.selectAll)),
                    PopupMenuButton<void Function()>(onSelected: (f) => f(), itemBuilder: (ctx) => trackMenu(ctx, ids)),
                  ],
                )
              : AppBar(
                  title: Text(_sourceTitle(app, s)),
                  leading: app.source is AllTracks
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () => app.setSource(const AllTracks()),
                        ),
                  actions: [
                    IconButton(
                      tooltip: s.selectMode,
                      icon: const Icon(Icons.checklist),
                      onPressed: () => setState(() => _selectionMode = true),
                    ),
                  ],
                ),
          body: Column(
            children: [
              LibraryToolbar(searchFocus: _searchFocus, searchController: _search, compact: true),
              if (app.scans.isNotEmpty || app.job != null) const _StatusBar(),
              Expanded(
                child: app.viewMode == ViewMode.grid
                    ? TrackGrid(
                        selectionMode: selecting,
                        onOpen: (id) =>
                            Navigator.push(context, MaterialPageRoute<void>(builder: (_) => DetailPage(trackId: id))),
                        onLongPress: (id) {
                          setState(() => _selectionMode = true);
                          app.selection.toggle(id);
                        },
                      )
                    : TrackListMobile(
                        selectionMode: selecting,
                        onOpen: (id) {
                          app.focus(id);
                          Navigator.push(context, MaterialPageRoute<void>(builder: (_) => DetailPage(trackId: id)));
                        },
                        onLongPress: (id) {
                          setState(() => _selectionMode = true);
                          app.selection.toggle(id);
                        },
                      ),
              ),
            ],
          ),
          bottomNavigationBar: selecting
              ? BottomAppBar(
                  height: 64,
                  padding: EdgeInsets.zero,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _BarAction(Icons.edit_outlined, s.edit, ids.isEmpty ? null : () => editTags(context, ids)),
                      _BarAction(
                        Icons.drive_file_rename_outline,
                        s.rename,
                        ids.isEmpty ? null : () => renameFiles(context, ids),
                      ),
                      _BarAction(
                        Icons.playlist_add,
                        s.playlists,
                        ids.isEmpty ? null : () => addToPlaylist(context, ids),
                      ),
                      _BarAction(Icons.ios_share, s.export, ids.isEmpty ? null : () => exportTracks(context, ids)),
                    ],
                  ),
                )
              : null,
        );
      },
    );
    final page = switch (_section) {
      Section.library => library,
      Section.playlists => PlaylistsPane(onOpened: () => setState(() => _section = Section.library)),
      Section.history => const HistoryPage(),
      Section.settings => const SettingsPage(),
    };
    return PopScope(
      canPop: !selecting && _section == Section.library && app.source is AllTracks,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (selecting) {
          app.selection.clear();
          setState(() => _selectionMode = false);
        } else if (_section != Section.library) {
          setState(() => _section = Section.library);
        } else {
          app.setSource(const AllTracks());
        }
      },
      child: Scaffold(
        body: page,
        bottomNavigationBar: selecting
            ? null
            : NavigationBar(
                selectedIndex: _section.index,
                onDestinationSelected: (i) => setState(() => _section = Section.values[i]),
                destinations: [
                  NavigationDestination(icon: const Icon(Icons.library_music_outlined), label: s.library),
                  NavigationDestination(icon: const Icon(Icons.queue_music), label: s.playlists),
                  NavigationDestination(
                    icon: Badge(isLabelVisible: app.job != null, child: const Icon(Icons.history)),
                    label: s.tasks,
                  ),
                  NavigationDestination(icon: const Icon(Icons.settings_outlined), label: s.settings),
                ],
              ),
      ),
    );
  }

  String _sourceTitle(AppState app, S s) {
    final src = app.source;
    if (src is PlaylistTracks) {
      return app.playlists.where((p) => p.id == src.playlistId).firstOrNull?.name ?? s.playlists;
    }
    if (src is RootTracks) return app.rootOf(src.rootId)?.displayPath.split(RegExp(r'[\\/]')).last ?? s.folders;
    return '${s.appName} · ${s.library}';
  }
}

class _BarAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _BarAction(this.icon, this.label, this.onTap);
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    ),
  );
}

class _SelectionBar extends StatelessWidget {
  final bool compact;
  const _SelectionBar({required this.compact});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    final s = S.of(context);
    final src = app.source;
    return ListenableBuilder(
      listenable: app.selection,
      builder: (context, _) {
        final n = app.selection.length;
        final outside = app.selectedOutsideView;
        final playlist = src is PlaylistTracks ? app.playlists.where((p) => p.id == src.playlistId).firstOrNull : null;
        if (n == 0 && playlist == null) return const SizedBox.shrink();
        final ids = app.selectedInOrder();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
          child: Row(
            children: [
              if (playlist != null) ...[
                const Icon(Icons.queue_music, size: 18),
                const SizedBox(width: 6),
                Text(playlist.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                PopupMenuButton<void Function()>(
                  icon: const Icon(Icons.more_horiz, size: 18),
                  onSelected: (f) => f(),
                  itemBuilder: (ctx) => playlistMenu(ctx, playlist),
                ),
                const SizedBox(width: 12),
              ],
              if (n > 0) ...[
                Text(s.selectedCount(n)),
                if (outside > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      s.outsideView(outside),
                      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.tertiary),
                    ),
                  ),
              ],
              const Spacer(),
              if (n > 0) ...[
                IconButton(
                  tooltip: s.editTags,
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => editTags(context, ids),
                ),
                IconButton(
                  tooltip: s.renameFiles,
                  icon: const Icon(Icons.drive_file_rename_outline),
                  onPressed: () => renameFiles(context, ids),
                ),
                IconButton(
                  tooltip: s.addToPlaylist,
                  icon: const Icon(Icons.playlist_add),
                  onPressed: () => addToPlaylist(context, ids),
                ),
                IconButton(
                  tooltip: s.exportPlaylist,
                  icon: const Icon(Icons.ios_share),
                  onPressed: () => exportTracks(context, ids),
                ),
                if (playlist != null)
                  IconButton(
                    tooltip: s.removeFromPlaylist,
                    icon: const Icon(Icons.playlist_remove),
                    onPressed: () => removeFromPlaylist(context, playlist.id, app.selection.ids.toSet()),
                  ),
                TextButton(onPressed: app.selection.clear, child: Text(s.clearSelection)),
              ] else
                TextButton(onPressed: app.selectAll, child: Text(s.selectAll)),
            ],
          ),
        );
      },
    );
  }
}

class _Sidebar extends StatelessWidget {
  final Section section;
  final ValueChanged<Section> onSection;
  final bool playlistsOnly;
  const _Sidebar({required this.section, required this.onSection, this.playlistsOnly = false});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget tile(IconData icon, String text, bool selected, VoidCallback onTap, {Widget? trailing, String? tooltip}) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: Material(
            color: selected ? scheme.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onTap,
              child: SizedBox(
                height: 36,
                child: Row(
                  children: [
                    const SizedBox(width: 10),
                    Icon(icon, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Tooltip(
                        message: tooltip ?? '',
                        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    ?trailing,
                  ],
                ),
              ),
            ),
          ),
        );
    Widget header(String text, {Widget? action}) => Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
            ),
          ),
          ?action,
        ],
      ),
    );
    final inLibrary = section == Section.library || section == Section.playlists;
    return Container(
      color: scheme.surfaceContainerLow,
      child: ListView(
        children: [
          if (!playlistsOnly) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 20, 18, 4),
              child: Text(s.appName, style: Theme.of(context).textTheme.titleLarge),
            ),
            header(s.library),
            tile(
              Icons.library_music_outlined,
              s.allTracks,
              inLibrary && app.source is AllTracks,
              () {
                app.setSource(const AllTracks());
                onSection(Section.library);
              },
              trailing: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Text('${app.rows.length}', style: const TextStyle(fontSize: 12)),
              ),
            ),
            header(
              s.folders,
              action: IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: s.addFolder,
                icon: const Icon(Icons.add, size: 18),
                onPressed: app.addFolder,
              ),
            ),
            for (final r in app.roots)
              tile(
                app.scans.containsKey(r.id) ? Icons.sync : Icons.folder_outlined,
                r.displayPath.split(RegExp(r'[\\/]')).where((x) => x.isNotEmpty).lastOrNull ?? r.displayPath,
                inLibrary && app.source == RootTracks(r.id),
                () {
                  app.setSource(RootTracks(r.id));
                  onSection(Section.library);
                },
                tooltip: r.displayPath,
                trailing: PopupMenuButton<String>(
                  iconSize: 16,
                  padding: EdgeInsets.zero,
                  onSelected: (x) async {
                    switch (x) {
                      case 'scan':
                        app.rescan(r);
                      case 'full':
                        app.rescan(r, full: true);
                      case 'cancel':
                        app.cancelScan(r.id);
                      case 'remove':
                        if (await confirm(context, s.removeFolderConfirm(r.displayPath), action: s.delete))
                          await app.removeRoot(r);
                    }
                  },
                  itemBuilder: (_) => [
                    if (!app.scans.containsKey(r.id)) PopupMenuItem(value: 'scan', child: Text(s.rescan)),
                    if (!app.scans.containsKey(r.id)) PopupMenuItem(value: 'full', child: Text(s.fullRescan)),
                    if (app.scans.containsKey(r.id)) PopupMenuItem(value: 'cancel', child: Text(s.cancel)),
                    PopupMenuItem(value: 'remove', child: Text(s.removeFolder)),
                  ],
                ),
              ),
          ],
          header(
            s.playlists,
            action: IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: s.newPlaylist,
              icon: const Icon(Icons.add, size: 18),
              onPressed: () => createPlaylist(context, tracks: app.selectedInOrder()),
            ),
          ),
          for (final p in app.playlists)
            tile(
              Icons.queue_music,
              p.name,
              inLibrary && app.source == PlaylistTracks(p.id),
              () {
                app.setSource(PlaylistTracks(p.id));
                onSection(Section.library);
              },
              trailing: PopupMenuButton<void Function()>(
                iconSize: 16,
                padding: EdgeInsets.zero,
                onSelected: (f) => f(),
                itemBuilder: (ctx) => playlistMenu(ctx, p),
              ),
            ),
          if (!playlistsOnly) ...[
            const SizedBox(height: 8),
            const Divider(),
            tile(Icons.history, s.history, section == Section.history, () => onSection(Section.history)),
            tile(Icons.settings_outlined, s.settings, section == Section.settings, () => onSection(Section.settings)),
          ],
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar();
  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    final scan = app.scans.values.firstOrNull;
    final job = app.job;
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        child: ListenableBuilder(
          listenable: app.selection,
          builder: (context, _) => Row(
            children: [
              Text(s.tracksCount(app.view.length)),
              if (app.selection.length > 0) Text(' · ${s.selectedCount(app.selection.length)}'),
              const Spacer(),
              if (scan != null) ...[
                const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                const SizedBox(width: 6),
                Text(s.scanning(scan.parsed, scan.toParse, scan.found)),
                TextButton(
                  onPressed: () => app.cancelScan(scan.rootId),
                  child: Text(s.cancel, style: const TextStyle(fontSize: 12)),
                ),
              ],
              if (job != null) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: 80,
                  child: LinearProgressIndicator(value: job.total == 0 ? null : job.done / job.total),
                ),
                const SizedBox(width: 6),
                Text('${job.done}/${job.total}'),
                TextButton(
                  onPressed: app.cancelJob,
                  child: Text(s.cancel, style: const TextStyle(fontSize: 12)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
