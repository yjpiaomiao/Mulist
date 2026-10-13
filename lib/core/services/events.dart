// Events sent from the core isolate to the UI isolate.
import '../model/track.dart';

sealed class CoreEvent {
  const CoreEvent();
}

/// Tracks were added/updated ([rows]) or removed ([removed]).
class RowsChanged extends CoreEvent {
  final List<TrackRow> rows;
  final List<int> removed;
  const RowsChanged(this.rows, this.removed);
}

enum JobKind { tagWrite, undo, rename, export, recovery, maintenance }

/// Progress of the running job.
class JobProgress extends CoreEvent {
  final int jobId;
  final JobKind kind;
  final int done;
  final int total;
  final String? current;
  const JobProgress(this.jobId, this.kind, this.done, this.total, [this.current]);
}

class ItemResult {
  final int? trackId;
  final String label;
  final String? error;
  final bool skipped;
  const ItemResult(this.trackId, this.label, {this.error, this.skipped = false});
}

/// A finished job with its "succeeded / skipped / failed" summary.
class JobFinished extends CoreEvent {
  final int jobId;
  final JobKind kind;
  final int? batchId;
  final int succeeded;
  final List<ItemResult> skipped;
  final List<ItemResult> failed;
  final bool cancelled;
  final String? error;
  const JobFinished({
    required this.jobId,
    required this.kind,
    this.batchId,
    required this.succeeded,
    this.skipped = const [],
    this.failed = const [],
    this.cancelled = false,
    this.error,
  });
}

/// Library roots changed (added / removed / updated).
class RootsChanged extends CoreEvent {
  const RootsChanged();
}

/// Playlists changed.
class PlaylistsChanged extends CoreEvent {
  const PlaylistsChanged();
}

/// History (operation journal) changed.
class HistoryChanged extends CoreEvent {
  const HistoryChanged();
}
