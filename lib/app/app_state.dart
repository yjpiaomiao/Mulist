// UI isolate state. Holds the light rows of all tracks (for rendering), the
// current result list, selection, roots, playlists and job status. All
// disk work is delegated to the core / search / scan isolates.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/model/library_root.dart';
import '../core/model/track.dart';
import '../core/scan/scanner.dart';
import '../core/search/search_index.dart';
import '../core/search/search_isolate.dart';
import '../core/services/core_context.dart';
import '../core/services/core_isolate.dart';
import '../core/services/events.dart';
import '../core/services/playlists.dart';
import 'platform.dart';

enum ViewMode { list, grid }

/// What the library view shows.
sealed class LibrarySource {
  const LibrarySource();
}

class AllTracks extends LibrarySource {
  const AllTracks();
  @override
  bool operator ==(Object other) => other is AllTracks;
  @override
  int get hashCode => 1;
}

class RootTracks extends LibrarySource {
  final int rootId;
  const RootTracks(this.rootId);
  @override
  bool operator ==(Object other) => other is RootTracks && other.rootId == rootId;
  @override
  int get hashCode => rootId.hashCode;
}

class PlaylistTracks extends LibrarySource {
  final int playlistId;
  const PlaylistTracks(this.playlistId);
  @override
  bool operator ==(Object other) => other is PlaylistTracks && other.playlistId == playlistId;
  @override
  int get hashCode => playlistId.hashCode + 7;
}

class ScanStatus {
  final int rootId;
  final int found;
  final int parsed;
  final int toParse;
  final bool enumerating;
  const ScanStatus(this.rootId, this.found, this.parsed, this.toParse, this.enumerating);
}

class JobStatus {
  final int jobId;
  final JobKind kind;
  final int done;
  final int total;
  final String? current;
  const JobStatus(this.jobId, this.kind, this.done, this.total, this.current);
}

/// Selection of track ids, independent of the current order (a search does
/// not lose it). Range selection uses the anchor's index in the view.
class Selection extends ChangeNotifier {
  final _ids = <int>{};
  int? anchor;

  Set<int> get ids => _ids;
  int get length => _ids.length;
  bool contains(int id) => _ids.contains(id);
  bool get isEmpty => _ids.isEmpty;

  void only(int id) {
    _ids
      ..clear()
      ..add(id);
    anchor = id;
    notifyListeners();
  }

  void toggle(int id) {
    if (!_ids.remove(id)) _ids.add(id);
    anchor = id;
    notifyListeners();
  }

  void range(Int32List view, int toId, {bool additive = false}) {
    final a = anchor == null ? -1 : view.indexOf(anchor!);
    final b = view.indexOf(toId);
    if (b < 0) return;
    if (!additive) _ids.clear();
    if (a < 0) {
      _ids.add(toId);
      anchor = toId;
    } else {
      final lo = a < b ? a : b, hi = a < b ? b : a;
      for (var i = lo; i <= hi; i++) {
        _ids.add(view[i]);
      }
    }
    notifyListeners();
  }

  void setAll(Iterable<int> ids) {
    _ids
      ..clear()
      ..addAll(ids);
    notifyListeners();
  }

  void addAll(Iterable<int> ids) {
    _ids.addAll(ids);
    notifyListeners();
  }

  void clear() {
    if (_ids.isEmpty) return;
    _ids.clear();
    anchor = null;
    notifyListeners();
  }

  void retain(Set<int> existing) {
    final before = _ids.length;
    _ids.removeWhere((id) => !existing.contains(id));
    if (_ids.length != before) notifyListeners();
  }
}

class AppState extends ChangeNotifier {
  late final CoreClient core;
  late final SearchClient search;
  late final CorePaths paths;
  final selection = Selection();

  final rows = <int, TrackRow>{};
  List<LibraryRoot> roots = const [];
  List<PlaylistInfo> playlists = const [];
  Map<String, String> settings = const {};

  /// Ids currently shown, in order.
  Int32List view = Int32List(0);
  String query = '';
  SortField sort = SortField.artist;
  bool descending = false;
  LibrarySource source = const AllTracks();
  ViewMode viewMode = ViewMode.list;

  /// The track shown in the detail panel.
  int? focused;
  final scans = <int, ScanStatus>{};
  final _scanHandles = <int, ScanHandle>{};
  JobStatus? job;

  /// Finished jobs / scans waiting to be reported to the user.
  final finished = StreamController<Object>.broadcast();
  final historyChanged = StreamController<void>.broadcast();

  int _searchSeq = 0;
  Timer? _rowsTimer;
  final _pendingRows = <TrackRow>[];
  final _pendingRemoved = <int>[];
  RootIsolateToken? _token;
  bool ready = false;

  /// [testPaths] replaces the platform directories (tests).
  Future<void> init({CorePaths? testPaths}) async {
    if (testPaths != null) {
      paths = testPaths;
    } else {
      final support = await getApplicationSupportDirectory();
      final cache = await getApplicationCacheDirectory();
      // Windows path_provider derives directories from ProductName. Keep the
      // original storage identity when the displayed product becomes Mulist.
      paths = Platform.isWindows
          ? CorePaths(
              '${support.parent.path}${Platform.pathSeparator}music_manager',
              '${cache.parent.path}${Platform.pathSeparator}music_manager',
            )
          : CorePaths(support.path, cache.path);
    }
    _token = RootIsolateToken.instance;
    core = await CoreClient.start(paths, _token);
    core.events.listen(_onCoreEvent);
    settings = await core.call<Map<String, String>>('settings');
    sort = SortField.values.firstWhere((s) => s.name == settings[SettingKeys.sort], orElse: () => SortField.artist);
    descending = settings[SettingKeys.sortDesc] == 'true';
    viewMode = settings[SettingKeys.viewMode] == 'grid' ? ViewMode.grid : ViewMode.list;
    roots = await core.call<List<LibraryRoot>>('roots');
    if (Platform.isMacOS) await _resolveBookmarks();
    final (client, all) = await SearchClient.start(paths.dbPath);
    search = client;
    for (final r in all) {
      rows[r.id] = r;
    }
    playlists = await core.call<List<PlaylistInfo>>('playlists');
    ready = true;
    await refreshView();
  }

  Future<void> _resolveBookmarks() async {
    final bms = await core.call<Map<int, List<int>?>>('bookmarks');
    for (final e in bms.entries) {
      if (e.value == null) continue;
      final r = await PlatformIo.resolveBookmark(Uint8List.fromList(e.value!));
      if (r == null) continue;
      await core.call<void>('setRootLocator', {'id': e.key, 'locator': r.path});
      if (r.refreshed != null) await core.call<void>('setBookmark', {'id': e.key, 'bookmark': r.refreshed});
    }
    roots = await core.call<List<LibraryRoot>>('roots');
  }

  String setting(String key) => settings[key] ?? SettingKeys.defaults[key] ?? '';

  Future<void> setSetting(String key, String value) async {
    settings = {...settings, key: value};
    notifyListeners();
    await core.call<void>('setSetting', {'key': key, 'value': value});
  }

  // ---------------------------------------------------------------- events

  void _onCoreEvent(CoreEvent e) {
    switch (e) {
      case RowsChanged():
        _queueRows(e.rows, e.removed);
      case JobProgress():
        job = JobStatus(e.jobId, e.kind, e.done, e.total, e.current);
        notifyListeners();
      case JobFinished():
        if (job?.jobId == e.jobId) job = null;
        finished.add(e);
        notifyListeners();
      case RootsChanged():
        core.call<List<LibraryRoot>>('roots').then((r) {
          roots = r;
          notifyListeners();
        });
      case PlaylistsChanged():
        core.call<List<PlaylistInfo>>('playlists').then((p) {
          playlists = p;
          if (source is PlaylistTracks) refreshView();
          notifyListeners();
        });
      case HistoryChanged():
        historyChanged.add(null);
    }
  }

  /// Row updates are coalesced (scans send many small batches).
  void _queueRows(List<TrackRow> updated, List<int> removed) {
    _pendingRows.addAll(updated);
    _pendingRemoved.addAll(removed);
    _rowsTimer ??= Timer(const Duration(milliseconds: 120), _flushRows);
  }

  Future<void> _flushRows() async {
    _rowsTimer = null;
    final up = List.of(_pendingRows);
    final rm = List.of(_pendingRemoved);
    _pendingRows.clear();
    _pendingRemoved.clear();
    for (final r in up) {
      rows[r.id] = r;
    }
    for (final id in rm) {
      rows.remove(id);
    }
    if (up.isNotEmpty) await search.upsert(up);
    if (rm.isNotEmpty) {
      await search.remove(rm);
      selection.retain(rows.keys.toSet());
    }
    await refreshView();
  }

  // ------------------------------------------------------------------ view

  Future<void> setQuery(String q) async {
    query = q;
    await refreshView();
  }

  Future<void> setSort(SortField s, {bool? desc}) async {
    if (s == sort && desc == null) {
      descending = !descending;
    } else {
      sort = s;
      descending = desc ?? false;
    }
    unawaited(core.call<void>('setSetting', {'key': SettingKeys.sort, 'value': sort.name}));
    unawaited(core.call<void>('setSetting', {'key': SettingKeys.sortDesc, 'value': '$descending'}));
    await refreshView();
  }

  void setViewMode(ViewMode m) {
    viewMode = m;
    unawaited(core.call<void>('setSetting', {'key': SettingKeys.viewMode, 'value': m.name}));
    notifyListeners();
  }

  Future<void> setSource(LibrarySource s) async {
    if (s == source) return;
    source = s;
    if (s is PlaylistTracks) {
      _playlistOrder = await core.call<List<int>>('playlistTrackIds', s.playlistId);
    }
    await refreshView();
  }

  List<int> _playlistOrder = const [];

  Future<void> refreshView() async {
    if (!ready) return;
    final seq = ++_searchSeq;
    final src = source;
    if (src is PlaylistTracks) {
      // Playlist order is the user's order; the query filters it.
      final ids = await search.search(query, sort, descending);
      if (seq != _searchSeq) return;
      final match = ids.toSet();
      view = Int32List.fromList(_playlistOrder.where((id) => match.contains(id) && rows.containsKey(id)).toList());
    } else {
      var ids = await search.search(query, sort, descending);
      if (seq != _searchSeq) return;
      if (src is RootTracks) {
        ids = Int32List.fromList(ids.where((id) => rows[id]?.rootId == src.rootId).toList());
      }
      view = ids;
    }
    notifyListeners();
  }

  bool get filtered => query.trim().isNotEmpty || source is! AllTracks;

  /// "Select all" = everything in the current (searched / filtered) view.
  void selectAll() => selection.setAll(view);

  /// Selected ids in view order (selected tracks outside the view last).
  List<int> selectedInOrder() {
    final s = selection.ids;
    final inView = [for (final id in view) if (s.contains(id)) id];
    if (inView.length == s.length) return inView;
    final seen = inView.toSet();
    return [...inView, ...s.where((id) => !seen.contains(id) && rows.containsKey(id))];
  }

  int get selectedOutsideView {
    if (selection.isEmpty) return 0;
    final v = view.toSet();
    return selection.ids.where((id) => !v.contains(id)).length;
  }

  void focus(int? id) {
    focused = id;
    notifyListeners();
  }

  // ----------------------------------------------------------------- roots

  Future<LibraryRoot?> addFolder() async {
    final picked = await PlatformIo.pickFolder();
    if (picked == null) return null;
    final root = await core.call<LibraryRoot>('addRoot', picked.toArgs());
    roots = await core.call<List<LibraryRoot>>('roots');
    notifyListeners();
    rescan(root);
    return root;
  }

  Future<void> removeRoot(LibraryRoot r) async {
    _scanHandles[r.id]?.cancel();
    await core.call<void>('removeRoot', r.id);
    if (source is RootTracks && (source as RootTracks).rootId == r.id) await setSource(const AllTracks());
  }

  void rescan(LibraryRoot root, {bool full = false}) {
    if (_scanHandles.containsKey(root.id)) return;
    final h = startScan(ScanRequest(
      dbPath: paths.dbPath,
      root: root,
      thumbDir: paths.thumbDir,
      separator: setting(SettingKeys.multiSeparator),
      workers: Platform.isAndroid ? 3 : (Platform.numberOfProcessors.clamp(2, 8)),
      full: full,
      token: _token,
    ));
    _scanHandles[root.id] = h;
    scans[root.id] = ScanStatus(root.id, 0, 0, 0, true);
    notifyListeners();
    h.events.listen((e) {
      switch (e) {
        case ScanProgress():
          scans[root.id] = ScanStatus(root.id, e.found, e.parsed, e.toParse, e.enumerating);
          notifyListeners();
        case ScanRows():
          _queueRows(e.rows, const []);
        case ScanDone():
          scans.remove(root.id);
          _scanHandles.remove(root.id);
          finished.add(e);
          core.call<List<LibraryRoot>>('roots').then((r) {
            roots = r;
            notifyListeners();
          });
          notifyListeners();
      }
    });
  }

  void rescanAll() {
    for (final r in roots) {
      rescan(r);
    }
  }

  void cancelScan(int rootId) => _scanHandles[rootId]?.cancel();

  LibraryRoot? rootOf(int id) {
    for (final r in roots) {
      if (r.id == id) return r;
    }
    return null;
  }

  String thumbPath(String hash) => '${paths.thumbDir}${Platform.pathSeparator}$hash.jpg';

  // ------------------------------------------------------------------ jobs

  Future<int> startTagWrite(List<int> ids, Map<String, List<String>> set, {String cover = 'keep', String? coverPath}) =>
      core.call<int>('tagWrite', {
        'tracks': ids,
        'request': {
          'set': set,
          'cover': {'action': cover, 'path': coverPath},
        },
      });

  Future<void> cancelJob() async {
    final j = job;
    if (j != null) await core.call<void>('cancel', j.jobId);
  }

  Future<void> undoLast() => core.call<int>('undoLast');

  Future<void> removeFromLibrary(List<int> ids) => core.call<void>('removeTracks', ids);

  @override
  void dispose() {
    for (final h in _scanHandles.values) {
      h.cancel();
    }
    finished.close();
    historyChanged.close();
    super.dispose();
  }
}
