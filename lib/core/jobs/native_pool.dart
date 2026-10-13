// A pool of isolates that run native core calls (tag reads, writes,
// restores). Native calls are synchronous FFI calls, so parallel IO needs
// several isolates. A file opened in a worker stays open there (handle) so
// that prepare and commit of one write use the same descriptor on Android.
import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:mm_native/mm_native.dart';

import '../model/library_root.dart';
import '../storage/backends.dart';
import '../storage/storage_backend.dart';

class NativeWorker {
  final SendPort _send;
  final ReceivePort _recv;
  final Isolate _isolate;
  final _pending = <int, Completer<Object?>>{};
  int _next = 0;
  int busy = 0;

  NativeWorker._(this._send, this._recv, this._isolate) {
    _recv.listen((m) {
      final (id, ok, value) = m as (int, bool, Object?);
      final c = _pending.remove(id);
      if (c == null) return;
      if (ok) {
        c.complete(value);
      } else {
        final (code, detail) = value as (String, String?);
        c.completeError(MmException(code, detail));
      }
    });
  }

  static Future<NativeWorker> spawn(RootIsolateToken? token) async {
    final recv = ReceivePort();
    final ready = ReceivePort();
    final iso = await Isolate.spawn(_main, (ready.sendPort, recv.sendPort, token), debugName: 'native-worker');
    final send = await ready.first as SendPort;
    ready.close();
    return NativeWorker._(send, recv, iso);
  }

  Future<T> call<T>(String op, Map<String, Object?> args) {
    final id = _next++;
    final c = Completer<Object?>();
    _pending[id] = c;
    busy++;
    _send.send((id, op, args));
    return c.future.then((v) => v as T).whenComplete(() => busy--);
  }

  void dispose() {
    _recv.close();
    _isolate.kill(priority: Isolate.immediate);
    for (final c in _pending.values) {
      c.completeError(MmException('worker_stopped'));
    }
    _pending.clear();
  }

  static void _main((SendPort, SendPort, RootIsolateToken?) init) {
    final (ready, reply, token) = init;
    if (token != null) BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    final port = ReceivePort();
    ready.send(port.sendPort);
    final handles = <int, NativeFile>{};
    var nextHandle = 1;
    port.listen((m) async {
      final (id, op, args) = m as (int, String, Map<String, Object?>);
      try {
        final r = await _run(op, args, handles, () => nextHandle++);
        reply.send((id, true, r));
      } on MmException catch (e) {
        reply.send((id, false, (e.code, e.detail)));
      } on StorageException catch (e) {
        reply.send((id, false, (e.code, e.detail)));
      } catch (e) {
        reply.send((id, false, ('exception', e.toString())));
      }
    });
  }

  static Future<Object?> _run(
      String op, Map<String, Object?> a, Map<int, NativeFile> handles, int Function() newHandle) async {
    NativeFile h() => handles[a['handle'] as int] ?? (throw MmException('bad_handle'));
    switch (op) {
      case 'open':
        final root = LibraryRoot.fromMap(a['root'] as Map);
        final f = await backendFor(root)
            .open(root, a['rel'] as String, docId: a['doc'] as String?, write: a['write'] == true);
        final id = newHandle();
        handles[id] = f;
        return id;
      case 'close':
        handles.remove(a['handle'] as int)?.close();
        return null;
      case 'read':
        return MmNative.tryRead(h().target,
            thumbDir: a['thumbDir'] as String?, detail: a['detail'] == true);
      case 'prepare':
        return MmNative.prepareWrite(h().target, (a['request'] as Map).cast<String, dynamic>());
      case 'commit':
        return MmNative.commit(h().target, (a['plan'] as Map).cast<String, dynamic>());
      case 'prepareRestore':
        return MmNative.prepareRestore(h().target, (a['request'] as Map).cast<String, dynamic>());
      case 'copyOut':
        return MmNative.copyOut(h().target, a['out'] as String);
      case 'extractPicture':
        return MmNative.extractPicture(h().target, a['index'] as int, a['out'] as String);
      case 'makeThumb':
        return MmNative.makeThumb(a['image'] as String, a['out'] as String, a['size'] as int);
      default:
        throw MmException('unknown_op', op);
    }
  }
}

class NativePool {
  final List<NativeWorker> workers;
  NativePool._(this.workers);

  static Future<NativePool> spawn(int count, RootIsolateToken? token) async =>
      NativePool._(await Future.wait(List.generate(count, (_) => NativeWorker.spawn(token))));

  /// The least busy worker.
  NativeWorker pick() => workers.reduce((a, b) => b.busy < a.busy ? b : a);

  /// Opens a file on a worker, runs [body] and closes it.
  Future<T> withFile<T>(LibraryRoot root, String rel, String? docId, bool write,
      Future<T> Function(NativeWorker w, int handle) body) async {
    final w = pick();
    final handle = await w.call<int>('open', {'root': root.toMap(), 'rel': rel, 'doc': docId, 'write': write});
    try {
      return await body(w, handle);
    } finally {
      await w.call<void>('close', {'handle': handle});
    }
  }

  void dispose() {
    for (final w in workers) {
      w.dispose();
    }
  }
}
