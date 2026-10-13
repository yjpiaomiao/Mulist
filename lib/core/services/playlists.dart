// Playlists (stored in the database, referencing track ids so that renamed
// or moved tracks are followed) and export to TXT / M3U / M3U8.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../model/track.dart';
import '../storage/backends.dart';
import '../storage/saf_storage.dart';
import 'core_context.dart';
import 'events.dart';

class PlaylistInfo {
  final int id;
  final String name;
  final int count;
  final int updatedAt;
  final Map<String, dynamic>? lastExport;
  const PlaylistInfo(this.id, this.name, this.count, this.updatedAt, this.lastExport);
}

class PlaylistEntry {
  final int pos;
  final int? trackId;
  final String fallback;
  const PlaylistEntry(this.pos, this.trackId, this.fallback);
}

enum ExportFormat { txt, m3u, m3u8 }

class ExportOptions {
  final ExportFormat format;
  final bool relative;

  /// '/' or '\'.
  final String separator;
  final bool crlf;
  final bool extInfo;
  final bool bom;

  /// Absolute directory relative paths are computed from (default: the
  /// directory of the playlist file). On Android: an ExternalStorage path
  /// such as /storage/emulated/0/Music.
  final String? baseDir;

  const ExportOptions({
    required this.format,
    this.relative = true,
    required this.separator,
    required this.crlf,
    this.extInfo = true,
    bool? bom,
    this.baseDir,
  }) : bom = bom ?? format != ExportFormat.m3u8;

  factory ExportOptions.platformDefault(ExportFormat f) =>
      ExportOptions(format: f, separator: Platform.isWindows ? r'\' : '/', crlf: Platform.isWindows);

  Map<String, Object?> toJson() => {
        'format': format.name,
        'relative': relative,
        'separator': separator,
        'crlf': crlf,
        'extInfo': extInfo,
        'bom': bom,
        'baseDir': baseDir,
      };

  factory ExportOptions.fromJson(Map<String, dynamic> j) => ExportOptions(
        format: ExportFormat.values.byName(j['format'] as String),
        relative: j['relative'] as bool? ?? true,
        separator: j['separator'] as String? ?? '/',
        crlf: j['crlf'] as bool? ?? false,
        extInfo: j['extInfo'] as bool? ?? true,
        bom: j['bom'] as bool?,
        baseDir: j['baseDir'] as String?,
      );
}

class ExportProblem {
  final String label;
  final String reason;
  const ExportProblem(this.label, this.reason);
}

class ExportResult {
  final Uint8List bytes;
  final int written;
  final List<ExportProblem> problems;
  const ExportResult(this.bytes, this.written, this.problems);
}

class Playlists {
  final CoreContext ctx;
  Playlists(this.ctx);

  List<PlaylistInfo> list() => [
        for (final x in ctx.db.db.select('SELECT p.id, p.name, p.updated_at, p.last_export_json, '
            '(SELECT count(*) FROM playlist_item i WHERE i.playlist_id = p.id) AS n FROM playlist p ORDER BY p.name COLLATE NOCASE'))
          PlaylistInfo(x['id'] as int, x['name'] as String, x['n'] as int, x['updated_at'] as int,
              x['last_export_json'] == null ? null : jsonDecode(x['last_export_json'] as String) as Map<String, dynamic>),
      ];

  int create(String name, List<int> trackIds) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return ctx.db.transaction(() {
      ctx.db.db.execute('INSERT INTO playlist(name, created_at, updated_at) VALUES(?, ?, ?)', [name, now, now]);
      final id = ctx.db.db.lastInsertRowId;
      _append(id, trackIds, 0);
      return id;
    }).also((_) => ctx.emit(const PlaylistsChanged()));
  }

  void _append(int id, List<int> trackIds, int start) {
    final st = ctx.db.db.prepare('INSERT INTO playlist_item(playlist_id, pos, track_id, fallback_path) '
        'SELECT ?, ?, id, rel_path FROM track WHERE id = ?');
    for (var i = 0; i < trackIds.length; i++) {
      st.execute([id, start + i, trackIds[i]]);
    }
    st.close();
  }

  void add(int id, List<int> trackIds) {
    ctx.db.transaction(() {
      final n = ctx.db.db.select('SELECT coalesce(max(pos) + 1, 0) AS n FROM playlist_item WHERE playlist_id = ?', [id]).first['n'] as int;
      _append(id, trackIds, n);
      _touch(id);
    });
    ctx.emit(const PlaylistsChanged());
  }

  void rename(int id, String name) {
    ctx.db.db.execute('UPDATE playlist SET name = ?, updated_at = ? WHERE id = ?', [name, DateTime.now().millisecondsSinceEpoch, id]);
    ctx.emit(const PlaylistsChanged());
  }

  void delete(int id) {
    ctx.db.db.execute('DELETE FROM playlist WHERE id = ?', [id]);
    ctx.emit(const PlaylistsChanged());
  }

  List<PlaylistEntry> items(int id) => [
        for (final x in ctx.db.db.select(
            'SELECT pos, track_id, fallback_path FROM playlist_item WHERE playlist_id = ? ORDER BY pos', [id]))
          PlaylistEntry(x['pos'] as int, x['track_id'] as int?, x['fallback_path'] as String? ?? ''),
      ];

  /// Replaces the order of the playlist: [positions] lists the old
  /// positions in their new order; positions not listed are removed.
  void reorder(int id, List<int> positions) {
    ctx.db.transaction(() {
      final old = {for (final e in items(id)) e.pos: e};
      ctx.db.db.execute('DELETE FROM playlist_item WHERE playlist_id = ?', [id]);
      final st = ctx.db.db.prepare('INSERT INTO playlist_item(playlist_id, pos, track_id, fallback_path) VALUES(?, ?, ?, ?)');
      var n = 0;
      for (final pos in positions) {
        final e = old[pos];
        if (e == null) continue;
        st.execute([id, n++, e.trackId, e.fallback]);
      }
      st.close();
      _touch(id);
    });
    ctx.emit(const PlaylistsChanged());
  }

  void _touch(int id) =>
      ctx.db.db.execute('UPDATE playlist SET updated_at = ? WHERE id = ?', [DateTime.now().millisecondsSinceEpoch, id]);

  // ---------------------------------------------------------------- export

  /// Builds the playlist file for [trackIds]. [targetPath] is where the file
  /// will be saved (absolute; on Android a derived /storage/... path or
  /// null when unknown) and is the default base of relative paths.
  ExportResult build(List<int> trackIds, ExportOptions o, {String? targetPath}) {
    final rows = {for (final r in ctx.db.rowsByIds(trackIds)) r.id: r};
    final docs = <int, String?>{};
    for (var i = 0; i < trackIds.length; i += 500) {
      final chunk = trackIds.sublist(i, i + 500 > trackIds.length ? trackIds.length : i + 500);
      for (final x in ctx.db.db.select('SELECT id, saf_doc_id FROM track WHERE id IN (${List.filled(chunk.length, '?').join(',')})', chunk)) {
        docs[x['id'] as int] = x['saf_doc_id'] as String?;
      }
    }
    final problems = <ExportProblem>[];
    final out = StringBuffer();
    final nl = o.crlf ? '\r\n' : '\n';
    final m3u = o.format != ExportFormat.txt;
    if (m3u) out.write('#EXTM3U$nl');
    // Paths of the target platform style: Windows paths use '\' internally.
    final winStyle = Platform.isWindows;
    final ctxPath = winStyle ? p.windows : p.posix;
    final base = o.baseDir ?? (targetPath == null ? null : ctxPath.dirname(targetPath));
    var written = 0;
    for (final id in trackIds) {
      final r = rows[id];
      if (r == null) continue;
      final display = r.artist.isEmpty ? r.displayTitle : '${r.artist} - ${r.displayTitle}';
      if (!m3u) {
        out.write('$display$nl');
        written++;
        continue;
      }
      final root = ctx.root(r.rootId);
      final abs = backendFor(root).absolutePath(root, r.relPath, docId: docs[id]);
      String? path;
      if (abs == null) {
        problems.add(ExportProblem(r.relPath, root.isSaf ? 'no_absolute_path_use_relative' : 'no_absolute_path'));
        continue;
      }
      if (o.relative) {
        if (base == null) {
          problems.add(ExportProblem(r.relPath, 'no_base_dir'));
          continue;
        }
        try {
          path = ctxPath.relative(abs, from: base);
          if (winStyle && path.length > 1 && path[1] == ':') throw const FormatException('different drive');
        } catch (_) {
          problems.add(ExportProblem(r.relPath, 'no_relative_path'));
          continue;
        }
      } else {
        path = abs;
      }
      path = path.replaceAll(RegExp(r'[\\/]'), o.separator);
      if (o.extInfo) out.write('#EXTINF:${(r.durationMs / 1000).round()},$display$nl');
      out.write('$path$nl');
      written++;
    }
    final body = utf8.encode(out.toString());
    final bytes = o.bom ? Uint8List.fromList([0xEF, 0xBB, 0xBF, ...body]) : Uint8List.fromList(body);
    return ExportResult(bytes, written, problems);
  }

  /// Writes the file on desktop. Returns the result for the summary.
  ExportResult exportToPath(List<int> trackIds, ExportOptions o, String path, {int? playlistId}) {
    final r = build(trackIds, o, targetPath: path);
    File(path).writeAsBytesSync(r.bytes, flush: true);
    if (playlistId != null) _rememberExport(playlistId, o, path);
    return r;
  }

  void _rememberExport(int id, ExportOptions o, String path) {
    ctx.db.db.execute('UPDATE playlist SET last_export_json = ? WHERE id = ?', [
      jsonEncode({...o.toJson(), 'path': path}),
      id,
    ]);
    ctx.emit(const PlaylistsChanged());
  }

  /// Android: path base for relative entries of a document created by the
  /// system picker (derived from its document id), or null.
  static String? androidDocPath(String uri, String? docId) => docId == null ? null : safDocIdToPath(uri, docId);

  List<int> trackIdsOf(int playlistId) => [for (final e in items(playlistId)) if (e.trackId != null) e.trackId!];

  List<TrackRow> rowsOf(int playlistId) {
    final ids = trackIdsOf(playlistId);
    final m = {for (final r in ctx.db.rowsByIds(ids)) r.id: r};
    return [for (final id in ids) if (m[id] != null) m[id]!];
  }
}

extension _Also<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}
