// The search isolate keeps the [SearchIndex] of all tracks. It loads the
// rows itself (own read connection) and hands a copy to the UI isolate.
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../db/database.dart';
import '../model/track.dart';
import 'search_index.dart';

class SearchClient {
  final SendPort _send;
  final ReceivePort _recv;
  final _pending = <int, Completer<Object?>>{};
  int _next = 0;

  SearchClient._(this._send, this._recv) {
    _recv.listen((m) {
      final (id, value) = m as (int, Object?);
      _pending.remove(id)?.complete(value);
    });
  }

  /// Starts the isolate and returns it together with all rows.
  static Future<(SearchClient, List<TrackRow>)> start(String dbPath) async {
    final first = ReceivePort();
    await Isolate.spawn(_main, (first.sendPort, dbPath), debugName: 'search');
    final msgs = StreamIterator(first);
    await msgs.moveNext();
    final send = msgs.current as SendPort;
    await msgs.moveNext();
    final rows = (msgs.current as List).cast<TrackRow>();
    await msgs.cancel();
    final recv = ReceivePort();
    send.send(recv.sendPort);
    return (SearchClient._(send, recv), rows);
  }

  Future<T> _call<T>(String op, Object? args) {
    final id = _next++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send.send((id, op, args));
    return c.future.then((v) => v as T);
  }

  Future<void> upsert(List<TrackRow> rows) => _call('upsert', rows);
  Future<void> remove(List<int> ids) => _call('remove', ids);

  /// Matching ids in display order.
  Future<Int32List> search(String query, SortField sort, bool descending) async {
    final t = await _call<TransferableTypedData>('search', (query, sort.index, descending));
    return t.materialize().asInt32List();
  }
}

Future<void> _main((SendPort, String) init) async {
  final (out, dbPath) = init;
  final port = ReceivePort();
  out.send(port.sendPort);
  final idx = SearchIndex();
  final db = AppDatabase.open(dbPath);
  final rows = db.allRows();
  db.close();
  idx.upsertAll(rows);
  out.send(rows);
  SendPort? reply;
  String? lastQuery;
  SortField? lastSort;
  bool? lastDesc;
  Int32List? lastResult;
  await for (final m in port) {
    if (m is SendPort) {
      reply = m;
      continue;
    }
    final (id, op, args) = m as (int, String, Object?);
    Object? result;
    switch (op) {
      case 'upsert':
        idx.upsertAll((args as List).cast<TrackRow>());
        lastQuery = null;
      case 'remove':
        idx.removeAll((args as List).cast<int>());
        lastQuery = null;
      case 'search':
        final (q, s, desc) = args as (String, int, bool);
        final sort = SortField.values[s];
        final narrow = lastQuery != null && lastSort == sort && lastDesc == desc && SearchIndex.narrows(lastQuery, q);
        final r = idx.search(q, sort, descending: desc, within: narrow ? lastResult : null);
        lastQuery = q;
        lastSort = sort;
        lastDesc = desc;
        lastResult = r;
        result = TransferableTypedData.fromList([r]);
    }
    reply!.send((id, result));
  }
}
