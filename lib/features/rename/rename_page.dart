// Batch rename: template, target folder, conflict policy, and a preview of
// every "old name -> new name" before anything is touched.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/l10n.dart';
import '../../app/platform.dart';
import '../../app/scope.dart';
import '../../core/path/path_key.dart';
import '../../core/path/sanitizer.dart';
import '../../core/services/core_context.dart';
import '../../core/services/renamer.dart';
import '../../core/template/template.dart';
import '../actions.dart';

class RenamePage extends StatefulWidget {
  final List<int> trackIds;
  const RenamePage({super.key, required this.trackIds});
  @override
  State<RenamePage> createState() => _RenamePageState();
}

class _RenamePageState extends State<RenamePage> {
  final _template = TextEditingController();
  Timer? _debounce;
  RenamePreview? _preview;
  bool _busy = false;
  bool _onlyProblems = false;
  ConflictPolicy _policy = ConflictPolicy.number;
  int? _targetRoot;
  String _targetRel = '';
  String? _targetDisplay;
  final _overrides = <int, String>{};
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _template.text = AppScope.read(context).setting(SettingKeys.renameTemplate);
      _refresh();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _template.dispose();
    super.dispose();
  }

  bool get _hasDirs {
    try {
      return RenameTemplate.parse(_template.text).hasDirectories;
    } on TemplateError {
      return false;
    }
  }

  void _changed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _refresh);
    setState(() {});
  }

  Future<void> _refresh() async {
    final app = AppScope.read(context);
    final seq = ++_seq;
    setState(() => _busy = true);
    final p = await app.core.call<RenamePreview>(
      'renamePreview',
      RenameRequest(
        trackIds: widget.trackIds,
        template: _template.text,
        targetRootId: _hasDirs ? _targetRoot : null,
        targetRel: _targetRel,
        policy: _policy,
        overrides: _overrides,
        illegalChars: app.setting(SettingKeys.illegalChars) == 'underscore' ? IllegalCharMode.underscore : IllegalCharMode.fullWidth,
      ),
    );
    if (!mounted || seq != _seq) return;
    setState(() {
      _preview = p;
      _busy = false;
    });
  }

  Future<void> _pickTarget() async {
    final app = AppScope.read(context);
    final s = S.of(context);
    final picked = await PlatformIo.pickFolder();
    if (picked == null) return;
    final r = await app.core.call<Map>('resolveTarget', picked.toArgs());
    if (!mounted) return;
    setState(() {
      _targetRoot = r['rootId'] as int;
      _targetRel = r['rel'] as String;
      _targetDisplay = picked.display;
    });
    if (r['added'] == true) toast(context, s.targetAdded);
    await _refresh();
  }

  Future<void> _editItem(RenamePreviewItem it) async {
    final s = S.of(context);
    final v = await askText(context, s.rename, initial: it.toRel);
    if (v == null || v.isEmpty) return;
    _overrides[it.trackId] = v;
    await _refresh();
  }

  Future<void> _run() async {
    final p = _preview;
    if (p == null) return;
    final app = AppScope.read(context);
    await app.setSetting(SettingKeys.renameTemplate, _template.text);
    await app.core.call<int>('rename', p.items);
    if (mounted) Navigator.pop(context);
  }

  String _flagText(S s, String f) => switch (f) {
        RenameFlag.unchanged => s.flagUnchanged,
        RenameFlag.sanitized => s.flagSanitized,
        RenameFlag.conflict => s.flagConflict,
        RenameFlag.numbered => s.flagNumbered,
        RenameFlag.longPath => s.flagLongPath,
        RenameFlag.missingFields => s.flagMissing,
        RenameFlag.extChanged => s.flagExt,
        RenameFlag.manual => s.flagManual,
        _ => f,
      };

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final app = AppScope.watch(context);
    final scheme = Theme.of(context).colorScheme;
    final p = _preview;
    final items = p?.items ?? const <RenamePreviewItem>[];
    final change = items.where((i) => i.actionable).length;
    final unchanged = items.where((i) => i.flags.contains(RenameFlag.unchanged)).length;
    final problems = items.where((i) => i.hasProblem).length;
    final shown = _onlyProblems ? items.where((i) => i.hasProblem).toList() : items;
    final error = p?.templateError;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.renameFiles),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: !_busy && error == null && change > 0 ? _run : null,
              icon: const Icon(Icons.play_arrow),
              label: Text('${s.execute} ($change)'),
            ),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: _template,
              onChanged: _changed,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: InputDecoration(
                labelText: s.template,
                errorText: error == null || error == 'target_required' ? null : error,
                helperText: s.templateHelp,
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (_hasDirs)
                OutlinedButton.icon(
                  onPressed: _pickTarget,
                  icon: const Icon(Icons.folder_outlined, size: 18),
                  label: Text(_targetDisplay ?? s.chooseTarget, overflow: TextOverflow.ellipsis),
                  style: error == 'target_required' ? OutlinedButton.styleFrom(foregroundColor: scheme.error) : null,
                ),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text('${s.conflictPolicy}: '),
                SegmentedButton<ConflictPolicy>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: [
                    ButtonSegment(value: ConflictPolicy.number, label: Text(s.autoNumber)),
                    ButtonSegment(value: ConflictPolicy.skip, label: Text(s.skipConflict)),
                  ],
                  selected: {_policy},
                  onSelectionChanged: (v) {
                    setState(() => _policy = v.first);
                    _refresh();
                  },
                ),
              ]),
              FilterChip(
                label: Text(s.onlyProblems),
                selected: _onlyProblems,
                onSelected: (v) => setState(() => _onlyProblems = v),
              ),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Checkbox(
                  value: app.setting(SettingKeys.removeEmptyDirs) == 'true',
                  onChanged: (v) => app.setSetting(SettingKeys.removeEmptyDirs, '${v == true}'),
                ),
                Text(s.removeEmptyDirs),
              ]),
            ]),
            if (error == 'target_required')
              Padding(padding: const EdgeInsets.only(top: 4), child: Text(s.targetRequired, style: TextStyle(color: scheme.error))),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Text(
                  p == null ? '' : s.previewSummary(change, unchanged, problems, p.elapsedMs),
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ),
              if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
            Text(s.companionsNote, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
          ]),
        ),
        const Divider(),
        Expanded(
          child: ListView.builder(
            itemCount: shown.length,
            itemExtent: 64,
            itemBuilder: (context, i) {
              final it = shown[i];
              final bad = it.flags.contains(RenameFlag.conflict);
              final warn = it.hasProblem && !bad;
              return InkWell(
                onTap: () => _editItem(it),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(it.fromRel, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    Row(children: [
                      Icon(Icons.arrow_forward, size: 14, color: bad ? scheme.error : (warn ? Colors.orange : scheme.primary)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '${app.rootOf(it.toRoot)?.displayPath == app.rootOf(it.fromRoot)?.displayPath ? '' : '[${relName(app.rootOf(it.toRoot)?.displayPath ?? '')}] '}${it.toRel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: bad ? scheme.error : null,
                            fontWeight: it.flags.contains(RenameFlag.unchanged) ? FontWeight.normal : FontWeight.w500,
                          ),
                        ),
                      ),
                      for (final f in it.flags)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: f == RenameFlag.conflict ? scheme.error : scheme.outlineVariant),
                            ),
                            child: Text(
                              f == RenameFlag.missingFields ? '${_flagText(s, f)}: ${it.missing.join(',')}' : _flagText(s, f),
                              style: TextStyle(fontSize: 10, color: f == RenameFlag.conflict ? scheme.error : scheme.onSurfaceVariant),
                            ),
                          ),
                        ),
                    ]),
                  ]),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
