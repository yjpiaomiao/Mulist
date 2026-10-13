// Metadata and format details of one track.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/l10n.dart';
import '../../app/scope.dart';
import '../../app/theme.dart';
import '../../core/model/track.dart';
import '../../core/services/core_context.dart';
import '../actions.dart';
import '../library/cover.dart';

class DetailPanel extends StatefulWidget {
  final int? trackId;
  final bool showActions;
  const DetailPanel({super.key, required this.trackId, this.showActions = true});

  @override
  State<DetailPanel> createState() => _DetailPanelState();
}

class _DetailPanelState extends State<DetailPanel> {
  TrackDetail? _detail;
  int? _loadedId;
  TrackRow? _loadedRow;

  void _load() {
    final id = widget.trackId;
    final app = AppScope.read(context);
    final row = id == null ? null : app.rows[id];
    if (id == _loadedId && identical(row, _loadedRow)) return;
    _loadedId = id;
    _loadedRow = row;
    if (id == null) {
      setState(() => _detail = null);
      return;
    }
    app.core.call<TrackDetail?>('detail', id).then((d) {
      if (mounted && _loadedId == id) setState(() => _detail = d);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    final s = S.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
    final d = _detail;
    final scheme = Theme.of(context).colorScheme;
    if (widget.trackId == null || d == null || d.row.id != widget.trackId) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            app.selection.length > 1 ? s.nSelectedDetail(app.selection.length) : s.selectTrackHint,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    final r = d.row;
    final root = app.rootOf(r.rootId);
    String v(String key) => joinProp(d.props[key], app);
    final trackText = [if (r.trackNo > 0) '${r.trackNo}', if (d.trackTotal > 0) '${d.trackTotal}'].join(' / ');
    final discText = [if (r.discNo > 0) '${r.discNo}', if (d.discTotal > 0) '${d.discTotal}'].join(' / ');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(child: CoverThumb(hash: r.coverHash, size: 200, radius: 8)),
        if (r.coverHash == null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(s.noCover, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
        const SizedBox(height: 12),
        SelectableText(r.displayTitle, style: Theme.of(context).textTheme.titleMedium),
        if (r.artist.isNotEmpty) Text(r.artist, style: TextStyle(color: scheme.onSurfaceVariant)),
        if (r.status != TrackStatus.ok)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              r.status == TrackStatus.missing ? s.missingFile : '${s.unreadable}: ${d.error ?? ''}',
              style: TextStyle(color: scheme.error),
            ),
          ),
        if (widget.showActions) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed: () => editTags(context, app.selection.contains(r.id) ? app.selectedInOrder() : [r.id]),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: Text(s.edit),
            ),
            OutlinedButton.icon(
              onPressed: () => renameFiles(context, app.selection.contains(r.id) ? app.selectedInOrder() : [r.id]),
              icon: const Icon(Icons.drive_file_rename_outline, size: 18),
              label: Text(s.rename),
            ),
          ]),
        ],
        _Section(s.tags, [
          (s.title, v('TITLE')),
          (s.artist, v('ARTIST')),
          (s.album, v('ALBUM')),
          (s.albumArtist, v('ALBUMARTIST')),
          (s.trackNo, trackText),
          (s.discNo, discText),
          (s.year, v('DATE').isNotEmpty ? v('DATE') : r.year),
          (s.genre, v('GENRE')),
          (s.composer, v('COMPOSER')),
          (s.comment, v('COMMENT')),
        ]),
        _Section(s.formatInfo, [
          (s.container, d.container),
          (s.codec, r.codec),
          (s.bitrate, r.bitrate > 0 ? '${r.bitrate} kbps' : ''),
          (s.sampleRate, r.sampleRate > 0 ? '${r.sampleRate} Hz' : ''),
          (s.channels, d.channels > 0 ? '${d.channels}' : ''),
          (s.bitDepth, r.bitDepth > 0 ? '${r.bitDepth} bit' : ''),
          (s.duration, r.durationMs > 0 ? formatDuration(r.durationMs) : ''),
          (s.tagFormats, d.tagFormats.join(' + ')),
          (s.fileSize, formatSize(r.size)),
          (s.filePath, '${root?.displayPath ?? ''}/${r.relPath}'),
        ]),
        if (d.pictures.isNotEmpty)
          _Section(s.pictures, [
            for (final p in d.pictures) (p.type.isEmpty ? s.cover : p.type, '${p.mime} · ${formatSize(p.size)}'),
          ]),
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(s.allRawTags, style: Theme.of(context).textTheme.titleSmall),
          children: [
            for (final t in (d.tags.isEmpty ? [(format: d.tagFormats.join(' + '), props: d.props)] : d.tags)) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(t.format, style: TextStyle(fontWeight: FontWeight.w600, color: scheme.primary)),
                ),
              ),
              for (final e in t.props.entries) _kv(context, e.key, e.value.join('\n')),
            ],
          ],
        ),
      ],
    );
  }
}

String joinProp(List<String>? v, AppState app) => (v ?? const []).join(app.setting(SettingKeys.multiSeparator));

Widget _kv(BuildContext context, String k, String v) {
  final scheme = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 96, child: Text(k, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
      Expanded(
        child: GestureDetector(
          onLongPress: () => Clipboard.setData(ClipboardData(text: v)),
          child: SelectableText(v, style: const TextStyle(fontSize: 13)),
        ),
      ),
    ]),
  );
}

class _Section extends StatelessWidget {
  final String title;
  final List<(String, String)> rows;
  const _Section(this.title, this.rows);
  @override
  Widget build(BuildContext context) {
    final visible = rows.where((r) => r.$2.isNotEmpty).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        for (final (k, v) in visible) _kv(context, k, v),
      ]),
    );
  }
}

/// Full-screen detail page (phones).
class DetailPage extends StatelessWidget {
  final int trackId;
  const DetailPage({super.key, required this.trackId});
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.details), actions: [
        PopupMenuButton<void Function()>(
          onSelected: (f) => f(),
          itemBuilder: (ctx) => trackMenu(ctx, [trackId]),
        ),
      ]),
      body: DetailPanel(trackId: trackId),
    );
  }
}
