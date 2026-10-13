// Path identity: the key used for duplicate and conflict detection across
// platforms (NFC + lower-case folding, '/' separators).
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// NFC normalization (names produced by this app are always written as NFC).
String nfc(String s) {
  // Pure ASCII needs no normalization; this fast path covers most names.
  for (var i = 0; i < s.length; i++) {
    if (s.codeUnitAt(i) > 0x7f) return unorm.nfc(s);
  }
  return s;
}

/// Key of a relative path: NFC, case folded, '/' separated. macOS (NFD on
/// disk) and Windows (NFC) spellings of the same name share a key, and so do
/// `A.mp3` / `a.mp3` (case-insensitive file systems).
String pathKey(String relPath) => nfc(relPath.replaceAll('\\', '/')).toLowerCase();

/// Splits a relative path ('/' or '\' separated) into segments.
List<String> splitRel(String relPath) =>
    relPath.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();

/// Directory part of a '/'-separated relative path ('' for top level).
String relDir(String relPath) {
  final i = relPath.lastIndexOf('/');
  return i < 0 ? '' : relPath.substring(0, i);
}

/// Last segment of a '/'-separated relative path.
String relName(String relPath) {
  final i = relPath.lastIndexOf('/');
  return i < 0 ? relPath : relPath.substring(i + 1);
}

/// Joins relative segments with '/'.
String relJoin(String dir, String name) => dir.isEmpty ? name : '$dir/$name';

/// File extension without dot, lower case ('' if none).
String extOf(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0 || i == name.length - 1) return '';
  return name.substring(i + 1).toLowerCase();
}

/// File name without extension.
String stemOf(String name) {
  final i = name.lastIndexOf('.');
  return i <= 0 ? name : name.substring(0, i);
}
