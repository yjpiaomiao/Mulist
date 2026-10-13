// Track list (table on desktop, two-line rows on phones) and cover grid.
// Fixed-extent slivers keep scrolling smooth for any library size.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/l10n.dart';
import '../../app/scope.dart';
import '../../app/theme.dart';
import '../../core/model/track.dart';
import '../../core/search/search_index.dart';
import '../actions.dart';
import 'cover.dart';

bool get _isMac => Platform.isMacOS;

bool _modCtrl() {
  final k = HardwareKeyboard.instance;
  return _isMac ? k.isMetaPressed : k.isControlPressed;
}

bool _modShift() => HardwareKeyboard.instance.isShiftPressed;

/// Handles a click/tap on a row according to modifiers and mode.
void handleTrackTap(BuildContext context, int id, {required bool selectionMode}) {
  final app = AppScope.read(context);
  if (selectionMode) {
    app.selection.toggle(id);
    return;
  }
  if (_modShift()) {
    app.selection.range(app.view, id, additive: _modCtrl());
  } else if (_modCtrl()) {
    app.selection.toggle(id);
  } else {
    app.selection.only(id);
  }
  app.focus(id);
}

class LibraryToolbar extends StatelessWidget {
  final FocusNode searchFocus;
  final TextEditingController searchController;
  final bool compact;
  const LibraryToolbar({super.key, required this.searchFocus, required this.searchController, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    final s = S.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              focusNode: searchFocus,
              controller: searchController,
              onChanged: app.setQuery,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: compact ? s.searchShort : s.search,
                suffixIcon: searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          searchController.clear();
                          app.setQuery('');
                        },
                      ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SegmentedButton<ViewMode>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              ButtonSegment(value: ViewMode.list, icon: const Icon(Icons.view_list, size: 18), tooltip: s.listView),
              ButtonSegment(value: ViewMode.grid, icon: const Icon(Icons.grid_view, size: 18), tooltip: s.gridView),
            ],
            selected: {app.viewMode},
            onSelectionChanged: (v) => app.setViewMode(v.first),
          ),
          SortButton(),
        ],
      ),
    );
  }
}

String sortLabel(S s, SortField f) => switch (f) {
      SortField.artist => s.artist,
      SortField.album => s.album,
      SortField.title => s.title,
      SortField.duration => s.duration,
      SortField.year => s.year,
      SortField.genre => s.genre,
      SortField.format => s.format,
      SortField.path => s.path,
      SortField.added => s.added,
    };

class SortButton extends StatelessWidget {
  const SortButton({super.key});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    final s = S.of(context);
    return PopupMenuButton<SortField>(
      tooltip: s.sortBy,
      icon: const Icon(Icons.sort),
      onSelected: (f) => app.setSort(f),
      itemBuilder: (_) => [
        for (final f in SortField.values)
          CheckedPopupMenuItem(
            value: f,
            checked: app.sort == f,
            height: 36,
            child: Row(children: [
              Text(sortLabel(s, f)),
              if (app.sort == f) ...[
                const Spacer(),
                Icon(app.descending ? Icons.arrow_downward : Icons.arrow_upward, size: 16),
              ],
            ]),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------------ table

class _Col {
  final SortField? sort;
  final String Function(S) label;
  final double? width; // null = flex
  final int flex;
  final String Function(TrackRow) text;
  final TextAlign align;
  const _Col(this.label, this.text, {this.sort, this.width, this.flex = 1, this.align = TextAlign.start});
}

final _columns = <_Col>[
  _Col((s) => '#', (r) => r.trackNo > 0 ? '${r.trackNo}' : '', width: 44, align: TextAlign.end),
  _Col((s) => s.title, (r) => r.displayTitle, sort: SortField.title, flex: 3),
  _Col((s) => s.artist, (r) => r.artist, sort: SortField.artist, flex: 2),
  _Col((s) => s.album, (r) => r.album, sort: SortField.album, flex: 2),
  _Col((s) => s.year, (r) => r.year, sort: SortField.year, width: 56),
  _Col((s) => s.genre, (r) => r.genre, sort: SortField.genre, width: 96),
  _Col((s) => s.duration, (r) => r.durationMs > 0 ? formatDuration(r.durationMs) : '', sort: SortField.duration, width: 64, align: TextAlign.end),
  _Col((s) => s.format, (r) => r.ext.toUpperCase(), sort: SortField.format, width: 64),
];

const double desktopRowHeight = 36;
const double mobileRowHeight = 64;

class TrackTable extends StatefulWidget {
  const TrackTable({super.key});
  @override
  State<TrackTable> createState() => _TrackTableState();
}

class _TrackTableState extends State<TrackTable> {
  final _scroll = ScrollController();
  int? _dragStart;
  bool _dragMoved = false;

  int? _indexAt(Offset local) {
    final app = AppScope.read(context);
    final i = ((local.dy + _scroll.offset) / desktopRowHeight).floor();
    if (i < 0 || i >= app.view.length) return null;
    return i;
  }

  /// Keeps [index] visible (keyboard navigation).
  void ensureVisible(int index) {
    if (!_scroll.hasClients) return;
    final top = index * desktopRowHeight;
    final view = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + desktopRowHeight > _scroll.offset + view) {
      _scroll.jumpTo(top + desktopRowHeight - view);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.bodyMedium!;
    if (app.focused != null) {
      final i = app.view.indexOf(app.focused!);
      if (i >= 0) WidgetsBinding.instance.addPostFrameCallback((_) => ensureVisible(i));
    }
    return Column(
      children: [
        // header
        Container(
          height: 32,
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.outlineVariant))),
          child: Row(children: [
            const SizedBox(width: 8),
            for (final c in _columns) _cell(c, _header(c, app, s, scheme)),
            const SizedBox(width: 16),
          ]),
        ),
        Expanded(
          child: app.view.isEmpty
              ? _EmptyHint(filtered: app.filtered)
              : Listener(
                  onPointerDown: (e) {
                    if (e.kind == PointerDeviceKind.mouse && e.buttons == kPrimaryButton) {
                      _dragStart = _indexAt(e.localPosition);
                      _dragMoved = false;
                    }
                  },
                  onPointerMove: (e) {
                    // Drag over rows: box/range selection.
                    final start = _dragStart;
                    if (start == null || e.buttons != kPrimaryButton) return;
                    final i = _indexAt(e.localPosition);
                    if (i == null) return;
                    if (i != start || _dragMoved) {
                      _dragMoved = true;
                      final lo = i < start ? i : start, hi = i < start ? start : i;
                      final ids = [for (var k = lo; k <= hi; k++) app.view[k]];
                      if (_modCtrl()) {
                        app.selection.addAll(ids);
                      } else {
                        app.selection.setAll(ids);
                      }
                    }
                  },
                  onPointerUp: (_) => _dragStart = null,
                  child: Scrollbar(
                    controller: _scroll,
                    child: ListenableBuilder(
                      listenable: app.selection,
                      builder: (context, _) => CustomScrollView(
                        controller: _scroll,
                        slivers: [
                          SliverFixedExtentList(
                            itemExtent: desktopRowHeight,
                            delegate: SliverChildBuilderDelegate(
                              (context, i) => _row(context, app, app.view[i], i, scheme, text),
                              childCount: app.view.length,
                              addAutomaticKeepAlives: false,
                              addRepaintBoundaries: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _cell(_Col c, Widget child) => c.width != null
      ? SizedBox(width: c.width, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: child))
      : Expanded(flex: c.flex, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: child));

  Widget _header(_Col c, AppState app, S s, ColorScheme scheme) {
    final label = Text(c.label(s),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: c.align,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant));
    if (c.sort == null) return label;
    final active = app.sort == c.sort;
    return InkWell(
      onTap: () => app.setSort(c.sort!),
      child: Row(children: [
        Flexible(child: label),
        if (active) Icon(app.descending ? Icons.arrow_drop_down : Icons.arrow_drop_up, size: 18, color: scheme.primary),
      ]),
    );
  }

  Widget _row(BuildContext context, AppState app, int id, int index, ColorScheme scheme, TextStyle text) {
    final r = app.rows[id];
    if (r == null) return const SizedBox.shrink();
    final selected = app.selection.contains(id);
    final dim = r.status != TrackStatus.ok;
    final style = text.copyWith(
      fontSize: 13,
      color: selected ? scheme.onSecondaryContainer : (dim ? scheme.onSurface.withValues(alpha: 0.45) : null),
      decoration: r.status == TrackStatus.missing ? TextDecoration.lineThrough : null,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => handleTrackTap(context, id, selectionMode: false),
      onDoubleTap: () => editTags(context, app.selection.contains(id) ? app.selectedInOrder() : [id]),
      onSecondaryTapDown: (d) {
        if (!app.selection.contains(id)) {
          app.selection.only(id);
          app.focus(id);
        }
        showTrackMenu(context, d.globalPosition, app.selectedInOrder());
      },
      child: Container(
        color: selected
            ? scheme.secondaryContainer
            : (index.isOdd ? scheme.surfaceContainerLowest.withValues(alpha: 0.6) : null),
        child: Row(children: [
          const SizedBox(width: 8),
          for (final c in _columns)
            _cell(
                c,
                c.sort == SortField.title && dim
                    ? Row(children: [
                        Icon(r.status == TrackStatus.missing ? Icons.link_off : Icons.error_outline, size: 14, color: scheme.error),
                        const SizedBox(width: 4),
                        Expanded(child: Text(c.text(r), maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
                      ])
                    : Text(c.text(r), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: c.align, style: style)),
          const SizedBox(width: 16),
        ]),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final bool filtered;
  const _EmptyHint({required this.filtered});
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final app = AppScope.read(context);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(filtered ? Icons.search_off : Icons.library_music_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 12),
        Text(filtered ? s.noResults : s.emptyLibrary),
        if (!filtered) ...[
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: app.addFolder, icon: const Icon(Icons.create_new_folder_outlined), label: Text(s.addFolder)),
        ],
      ]),
    );
  }
}

// ------------------------------------------------------------- mobile list

class TrackListMobile extends StatelessWidget {
  final bool selectionMode;
  final void Function(int id) onOpen;
  final void Function(int id) onLongPress;
  const TrackListMobile({super.key, required this.selectionMode, required this.onOpen, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    final scheme = Theme.of(context).colorScheme;
    if (app.view.isEmpty) return _EmptyHint(filtered: app.filtered);
    return Scrollbar(
      child: ListenableBuilder(
        listenable: app.selection,
        builder: (context, _) => CustomScrollView(slivers: [
          SliverFixedExtentList(
            itemExtent: mobileRowHeight,
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final id = app.view[i];
                final r = app.rows[id];
                if (r == null) return const SizedBox.shrink();
                final selected = app.selection.contains(id);
                return InkWell(
                  onTap: () => selectionMode ? app.selection.toggle(id) : onOpen(id),
                  onLongPress: () => onLongPress(id),
                  child: Container(
                    color: selected ? scheme.secondaryContainer : null,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(children: [
                      if (selectionMode)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked,
                              color: selected ? scheme.primary : scheme.outline),
                        ),
                      CoverThumb(hash: r.coverHash, size: 44),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(r.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
                          const SizedBox(height: 2),
                          Text(
                            [r.artist, r.album].where((x) => x.isNotEmpty).join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                        ]),
                      ),
                      const SizedBox(width: 8),
                      Text(r.durationMs > 0 ? formatDuration(r.durationMs) : '',
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ]),
                  ),
                );
              },
              childCount: app.view.length,
              addAutomaticKeepAlives: false,
            ),
          ),
        ]),
      ),
    );
  }
}

// -------------------------------------------------------------------- grid

class TrackGrid extends StatelessWidget {
  final bool selectionMode;
  final void Function(int id)? onOpen;
  final void Function(int id)? onLongPress;
  const TrackGrid({super.key, this.selectionMode = false, this.onOpen, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    final scheme = Theme.of(context).colorScheme;
    final compact = isCompact(context);
    if (app.view.isEmpty) return _EmptyHint(filtered: app.filtered);
    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth;
      final cols = compact ? (width / 150).floor().clamp(2, 3) : (width / 168).floor().clamp(2, 20);
      final tile = (width - 16 - (cols - 1) * 12) / cols;
      return Scrollbar(
        child: ListenableBuilder(
          listenable: app.selection,
          builder: (context, _) => GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              mainAxisExtent: tile + 46,
            ),
            itemCount: app.view.length,
            addAutomaticKeepAlives: false,
            itemBuilder: (context, i) {
              final id = app.view[i];
              final r = app.rows[id];
              if (r == null) return const SizedBox.shrink();
              final selected = app.selection.contains(id);
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (onOpen != null && !selectionMode) {
                    onOpen!(id);
                  } else {
                    handleTrackTap(context, id, selectionMode: selectionMode);
                  }
                },
                onLongPress: onLongPress == null ? null : () => onLongPress!(id),
                onDoubleTap: compact ? null : () => editTags(context, [id]),
                onSecondaryTapDown: (d) {
                  if (!app.selection.contains(id)) app.selection.only(id);
                  showTrackMenu(context, d.globalPosition, app.selectedInOrder());
                },
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: selected ? scheme.primary : Colors.transparent, width: 2),
                    color: selected ? scheme.secondaryContainer : null,
                  ),
                  padding: const EdgeInsets.all(4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    CoverThumb(hash: r.coverHash, size: tile - 12, radius: 6),
                    const SizedBox(height: 4),
                    Text(r.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                    Text(r.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                  ]),
                ),
              );
            },
          ),
        ),
      );
    });
  }
}
