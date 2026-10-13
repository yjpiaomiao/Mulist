// Single and batch tag editor. Only fields the user actually changes are
// written; with several tracks, differing values show "(multiple values)".
import 'package:flutter/material.dart';

import '../../app/l10n.dart';
import '../../app/platform.dart';
import '../../app/scope.dart';
import '../../core/model/tag_fields.dart';
import '../../core/services/core_context.dart';
import '../library/cover.dart';

class TagEditor extends StatefulWidget {
  final List<int> trackIds;
  const TagEditor({super.key, required this.trackIds});

  @override
  State<TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends State<TagEditor> {
  final _controllers = <TagField, TextEditingController>{};
  Map<String, String?> _initial = {};
  String? _coverHash;
  bool _coverSame = true;
  String _coverAction = 'keep';
  String? _coverPath;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    for (final f in TagField.values) {
      _controllers[f] = TextEditingController()..addListener(() => setState(() {}));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final info = await AppScope.read(context).core.call<Map<String, Object?>>('editInfo', widget.trackIds);
    if (!mounted) return;
    _initial = (info['fields'] as Map).cast<String, String?>();
    for (final f in TagField.values) {
      _controllers[f]!.text = _initial[f.key] ?? '';
    }
    setState(() {
      _coverHash = info['cover'] as String?;
      _coverSame = info['coverSame'] as bool;
      _loading = false;
    });
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool _changed(TagField f) {
    final init = _initial[f.key];
    final now = _controllers[f]!.text;
    // A "multiple values" field counts as changed once something is typed.
    return init == null ? now.isNotEmpty : now != init;
  }

  bool get _dirty => TagField.values.any(_changed) || _coverAction != 'keep';

  Future<void> _save() async {
    final app = AppScope.read(context);
    final sep = app.setting(SettingKeys.multiSeparator);
    final set = <String, List<String>>{};
    for (final f in TagField.values) {
      if (!_changed(f)) continue;
      final text = _controllers[f]!.text.trim();
      set[f.key] = text.isEmpty ? const [] : (f.multiValued ? splitValues(text, sep) : [text]);
    }
    await app.startTagWrite(widget.trackIds, set, cover: _coverAction, coverPath: _coverPath);
    if (mounted) Navigator.of(context).pop();
  }

  String _label(S s, TagField f) => switch (f) {
        TagField.title => s.title,
        TagField.artist => s.artist,
        TagField.album => s.album,
        TagField.albumArtist => s.albumArtist,
        TagField.trackNumber => s.trackNo,
        TagField.discNumber => s.discNo,
        TagField.date => s.year,
        TagField.genre => s.genre,
        TagField.composer => s.composer,
        TagField.comment => s.comment,
      };

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final app = AppScope.watch(context);
    final sep = app.setting(SettingKeys.multiSeparator);
    final n = widget.trackIds.length;
    final scheme = Theme.of(context).colorScheme;
    Widget field(TagField f) {
      final multiple = _initial[f.key] == null;
      return TextField(
        controller: _controllers[f],
        maxLines: f == TagField.comment ? 3 : 1,
        minLines: 1,
        decoration: InputDecoration(
          labelText: _label(s, f),
          hintText: multiple ? s.multipleValues : null,
          floatingLabelBehavior: multiple ? FloatingLabelBehavior.always : null,
          helperText: f.multiValued ? s.separatorHint(sep) : null,
          suffixIcon: _changed(f)
              ? IconButton(
                  tooltip: s.revert,
                  icon: const Icon(Icons.undo, size: 18),
                  onPressed: () => _controllers[f]!.text = _initial[f.key] ?? '',
                )
              : null,
          filled: true,
          fillColor: _changed(f) ? scheme.primaryContainer.withValues(alpha: 0.35) : null,
        ),
      );
    }

    Widget pair(TagField a, TagField b) =>
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: field(a)), const SizedBox(width: 12), Expanded(child: field(b))]);

    return Scaffold(
      appBar: AppBar(
        title: Text(n == 1 ? s.editTags : s.editingN(n)),
        automaticallyImplyLeading: false,
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(onPressed: _dirty && !_loading ? _save : null, child: Text(s.save)),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Column(children: [
                    _coverAction == 'remove'
                        ? const CoverThumb(hash: null, size: 112)
                        : _coverAction == 'set'
                            ? const Icon(Icons.image, size: 112)
                            : CoverThumb(hash: _coverSame ? _coverHash : null, size: 112),
                    const SizedBox(height: 4),
                    PopupMenuButton<String>(
                      tooltip: s.cover,
                      onSelected: (v) async {
                        if (v == 'set') {
                          final p = await PlatformIo.pickImage();
                          if (p == null) return;
                          setState(() {
                            _coverAction = 'set';
                            _coverPath = p;
                          });
                        } else {
                          setState(() => _coverAction = v);
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'keep', child: Text(s.keepCover)),
                        PopupMenuItem(value: 'set', child: Text(s.replaceCover)),
                        PopupMenuItem(value: 'remove', child: Text(s.removeCover)),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(switch (_coverAction) { 'set' => s.replaceCover, 'remove' => s.removeCover, _ => s.keepCover },
                              style: const TextStyle(fontSize: 12)),
                          const Icon(Icons.arrow_drop_down, size: 18),
                        ]),
                      ),
                    ),
                  ]),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(children: [
                      field(TagField.title),
                      const SizedBox(height: 12),
                      field(TagField.artist),
                    ]),
                  ),
                ]),
                const SizedBox(height: 12),
                pair(TagField.album, TagField.albumArtist),
                const SizedBox(height: 12),
                pair(TagField.trackNumber, TagField.discNumber),
                const SizedBox(height: 12),
                pair(TagField.date, TagField.genre),
                const SizedBox(height: 12),
                field(TagField.composer),
                const SizedBox(height: 12),
                field(TagField.comment),
                const SizedBox(height: 16),
                Text(s.onlyChangedWritten, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ),
    );
  }
}
