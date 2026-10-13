// Operation history: every tag write, rename and undo, with undo / retry.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/l10n.dart';
import '../../app/scope.dart';
import '../../core/services/core_isolate.dart';
import '../actions.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<HistoryEntry> _entries = const [];
  StreamSubscription<void>? _sub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sub ??= AppScope.read(context).historyChanged.stream.listen((_) => _load());
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final e = await AppScope.read(context).core.call<List<HistoryEntry>>('history');
    if (mounted) setState(() => _entries = e);
  }

  String _kind(S s, HistoryEntry e) => switch (e.kind) {
        'tag_write' => s.kindTagWrite,
        'rename' => s.kindRename,
        _ => s.kindUndo,
      };

  String _state(S s, String st) => switch (st) {
        'done' => s.stateDone,
        'partial' => s.statePartial,
        'failed' => s.stateFailed,
        'undone' => s.stateUndone,
        'running' => s.stateRunning,
        'skipped' => s.stateSkipped,
        _ => st,
      };

  Future<void> _items(HistoryEntry e) async {
    final app = AppScope.read(context);
    final items = await app.core.call<List<HistoryItem>>('historyItems', e.id);
    if (!mounted) return;
    final s = S.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.7,
        child: ListView.builder(
          itemCount: items.length,
          itemBuilder: (ctx, i) {
            final it = items[i];
            final before = it.before['rel'] as String? ?? app.rows[it.trackId]?.relPath ?? '#${it.trackId}';
            final after = it.after['rel'] as String?;
            return ListTile(
              dense: true,
              leading: Icon(
                it.state == 'done' ? Icons.check : (it.state == 'failed' ? Icons.error_outline : Icons.remove),
                color: it.state == 'failed' ? Theme.of(ctx).colorScheme.error : null,
              ),
              title: Text(after == null || after == before ? before : '$before → $after', maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: it.error == null ? Text(_state(s, it.state)) : Text(s.error(it.error!)),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final app = AppScope.read(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(s.history), actions: [
        IconButton(
          tooltip: s.clearHistory,
          icon: const Icon(Icons.delete_sweep_outlined),
          onPressed: () async {
            if (await confirm(context, s.clearHistoryConfirm, action: s.clearHistory)) {
              await app.core.call<void>('clearHistory');
            }
          },
        ),
      ]),
      body: _entries.isEmpty
          ? Center(child: Text(s.noHistory, style: TextStyle(color: scheme.onSurfaceVariant)))
          : ListView.separated(
              itemCount: _entries.length,
              separatorBuilder: (_, _) => const Divider(),
              itemBuilder: (context, i) {
                final e = _entries[i];
                final sm = e.summary;
                final time = DateTime.fromMillisecondsSinceEpoch(e.createdAt);
                final t = '${time.year}-${_2(time.month)}-${_2(time.day)} ${_2(time.hour)}:${_2(time.minute)}';
                final counts = sm.containsKey('ok')
                    ? s.jobSummary(sm['ok'] as int? ?? 0, sm['skipped'] as int? ?? 0, sm['failed'] as int? ?? 0)
                    : s.tracksCount(sm['count'] as int? ?? 0);
                final keys = (sm['keys'] as List?)?.join(', ');
                return ListTile(
                  onTap: () => _items(e),
                  leading: Icon(switch (e.kind) {
                    'tag_write' => Icons.edit_note,
                    'rename' => Icons.drive_file_rename_outline,
                    _ => Icons.undo,
                  }),
                  title: Text('${_kind(s, e)} · ${_state(s, e.state)}'),
                  subtitle: Text([t, counts, if (keys != null && keys.isNotEmpty) keys].join(' · ')),
                  trailing: Wrap(spacing: 4, children: [
                    if (e.kind == 'tag_write' && (e.state == 'partial' || e.state == 'failed'))
                      TextButton(onPressed: () => app.core.call<int>('retry', e.id), child: Text(s.retryFailed)),
                    if (e.undoable)
                      TextButton.icon(
                        icon: const Icon(Icons.undo, size: 18),
                        label: Text(s.undo),
                        onPressed: () async {
                          if (await confirm(context, s.undoConfirm, action: s.undo)) {
                            await app.core.call<int>('undo', e.id);
                          }
                        },
                      ),
                  ]),
                );
              },
            ),
    );
  }

  static String _2(int v) => v.toString().padLeft(2, '0');
}
