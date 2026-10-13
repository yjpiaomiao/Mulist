// Export a list of tracks as TXT ("Artist - Title" per line), M3U or M3U8
// (always UTF-8; relative or absolute paths).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/l10n.dart';
import '../../app/platform.dart';
import '../../app/scope.dart';
import '../../core/path/sanitizer.dart';
import '../../core/services/playlists.dart';
import '../../core/storage/saf_storage.dart';
import '../actions.dart';

Future<void> showExportDialog(BuildContext context, List<int> ids, {int? playlistId, required String name}) =>
    showDialog<void>(context: context, builder: (_) => _ExportDialog(ids: ids, playlistId: playlistId, name: name));

class _ExportDialog extends StatefulWidget {
  final List<int> ids;
  final int? playlistId;
  final String name;
  const _ExportDialog({required this.ids, this.playlistId, required this.name});
  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  ExportFormat _format = ExportFormat.m3u8;
  bool _relative = true;
  String _sep = Platform.isWindows ? r'\' : '/';
  bool _crlf = Platform.isWindows;
  bool _extInfo = true;
  bool? _bom;
  String? _baseDir;
  bool _busy = false;

  ExportOptions get _options =>
      ExportOptions(format: _format, relative: _relative, separator: _sep, crlf: _crlf, extInfo: _extInfo, bom: _bom, baseDir: _baseDir);

  Future<void> _chooseBase() async {
    final picked = await PlatformIo.pickFolder();
    if (picked == null) return;
    String? path = picked.locator;
    if (picked.kind == 'saf') {
      path = picked.docId == null ? null : safDocIdToPath(picked.locator, picked.docId!);
    }
    setState(() => _baseDir = path);
  }

  Future<void> _export() async {
    final app = AppScope.read(context);
    final s = S.of(context);
    final ext = _format.name;
    final fileName = '${sanitizeSegment(widget.name).value}.$ext';
    setState(() => _busy = true);
    try {
      ExportResult r;
      String where;
      if (Platform.isAndroid) {
        final doc = await PlatformIo.androidCreateDocument(fileName, Uint8List(0));
        if (doc == null) return;
        final target = doc.docId == null ? null : safDocIdToPath(doc.uri, doc.docId!);
        r = await app.core.call<ExportResult>('exportBuild', {'tracks': widget.ids, 'options': _options.toJson(), 'target': target});
        await PlatformIo.androidWriteUri(doc.uri, r.bytes);
        where = target ?? fileName;
      } else {
        final path = await PlatformIo.pickSavePath(fileName, [ext]);
        if (path == null) return;
        final full = path.toLowerCase().endsWith('.$ext') ? path : '$path.$ext';
        r = await app.core.call<ExportResult>('exportToPath', {
          'tracks': widget.ids,
          'options': _options.toJson(),
          'path': full,
          'playlist': widget.playlistId,
        });
        where = full;
      }
      if (!mounted) return;
      Navigator.pop(context);
      if (r.problems.isEmpty) {
        toast(context, s.exported(r.written, where));
      } else {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(s.exported(r.written, where)),
            content: SizedBox(
              width: 480,
              height: 300,
              child: ListView(children: [
                Text(s.exportProblems(r.problems.length), style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                for (final p in r.problems)
                  ListTile(
                    dense: true,
                    title: Text(p.label),
                    subtitle: Text(switch (p.reason) {
                      'no_absolute_path_use_relative' || 'no_absolute_path' => s.problemNoAbsolute,
                      'no_relative_path' || 'no_base_dir' => s.problemNoRelative,
                      _ => p.reason,
                    }),
                  ),
              ]),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.close))],
          ),
        );
      }
    } catch (e) {
      if (mounted) toast(context, s.error(e.toString()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final m3u = _format != ExportFormat.txt;
    final bom = _bom ?? _format != ExportFormat.m3u8;
    return AlertDialog(
      title: Text('${s.exportPlaylist} · ${s.tracksCount(widget.ids.length)}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.exportFormat),
            const SizedBox(height: 6),
            SegmentedButton<ExportFormat>(
              showSelectedIcon: false,
              segments: [
                const ButtonSegment(value: ExportFormat.m3u8, label: Text('M3U8')),
                const ButtonSegment(value: ExportFormat.m3u, label: Text('M3U')),
                ButtonSegment(value: ExportFormat.txt, label: Text(s.plainText)),
              ],
              selected: {_format},
              onSelectionChanged: (v) => setState(() {
                _format = v.first;
                _bom = null;
              }),
            ),
            if (m3u) ...[
              const SizedBox(height: 12),
              Text(s.pathMode),
              const SizedBox(height: 6),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: true, label: Text(s.relativePaths)),
                  ButtonSegment(value: false, label: Text(s.absolutePaths)),
                ],
                selected: {_relative},
                onSelectionChanged: (v) => setState(() => _relative = v.first),
              ),
              if (_relative)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(s.baseDir),
                  subtitle: Text(_baseDir ?? s.baseDirDefault, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (_baseDir != null) IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _baseDir = null)),
                    TextButton(onPressed: _chooseBase, child: Text(s.chooseBaseDir)),
                  ]),
                ),
              Row(children: [
                Expanded(child: Text(s.pathSeparator)),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [ButtonSegment(value: r'\', label: Text(r'\')), ButtonSegment(value: '/', label: Text('/'))],
                  selected: {_sep},
                  onSelectionChanged: (v) => setState(() => _sep = v.first),
                ),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s.extInfo),
                value: _extInfo,
                onChanged: (v) => setState(() => _extInfo = v),
              ),
            ],
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Text(s.lineEnding)),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [ButtonSegment(value: true, label: Text('CRLF')), ButtonSegment(value: false, label: Text('LF'))],
                selected: {_crlf},
                onSelectionChanged: (v) => setState(() => _crlf = v.first),
              ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.utf8Bom),
              value: bom,
              onChanged: (v) => setState(() => _bom = v),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
        FilledButton(onPressed: _busy ? null : _export, child: Text(s.export)),
      ],
    );
  }
}
