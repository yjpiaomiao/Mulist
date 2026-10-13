import '../model/library_root.dart';
import 'desktop_storage.dart';
import 'saf_storage.dart';
import 'storage_backend.dart';

DesktopStorage? _desktop;
SafStorage? _saf;

/// The backend for [root] (one instance per isolate).
StorageBackend backendFor(LibraryRoot root) =>
    root.isSaf ? (_saf ??= SafStorage()) : (_desktop ??= DesktopStorage());
