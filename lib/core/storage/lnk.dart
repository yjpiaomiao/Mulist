// Minimal Windows Shell Link (.lnk) reader: returns the local target path.
// See [MS-SHLLINK]: ShellLinkHeader, LinkTargetIDList, LinkInfo
// (LocalBasePath / LocalBasePathUnicode + CommonPathSuffix), StringData.
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

const _hasIdList = 0x1;
const _hasLinkInfo = 0x2;
const _hasName = 0x4;
const _hasRelativePath = 0x8;
const _isUnicode = 0x80;

/// Returns the target path of the shortcut at [lnkPath], or null if it has
/// no local target (network shares are not followed).
String? readLnkTarget(String lnkPath) {
  final Uint8List b;
  try {
    final f = File(lnkPath);
    if (f.lengthSync() > 1 << 20) return null;
    b = f.readAsBytesSync();
  } on FileSystemException {
    return null;
  }
  return parseLnk(b, p.dirname(lnkPath));
}

String? parseLnk(Uint8List b, String lnkDir) {
  if (b.length < 0x4C) return null;
  final d = ByteData.sublistView(b);
  if (d.getUint32(0, Endian.little) != 0x4C) return null;
  final flags = d.getUint32(0x14, Endian.little);
  var off = 0x4C;
  if (flags & _hasIdList != 0) {
    if (off + 2 > b.length) return null;
    off += 2 + d.getUint16(off, Endian.little);
  }
  String? fromInfo;
  if (flags & _hasLinkInfo != 0 && off + 0x1C <= b.length) {
    final size = d.getUint32(off, Endian.little);
    final headerSize = d.getUint32(off + 4, Endian.little);
    final infoFlags = d.getUint32(off + 8, Endian.little);
    if (infoFlags & 0x1 != 0 && off + size <= b.length) {
      // VolumeIDAndLocalBasePath
      final baseOff = d.getUint32(off + 16, Endian.little);
      final suffixOff = d.getUint32(off + 24, Endian.little);
      String? base;
      String suffix = '';
      if (headerSize >= 0x24 && off + 0x24 <= b.length) {
        final baseU = d.getUint32(off + 28, Endian.little);
        final suffixU = d.getUint32(off + 32, Endian.little);
        if (baseU != 0) base = _utf16z(b, off + baseU);
        if (suffixU != 0) suffix = _utf16z(b, off + suffixU) ?? '';
      }
      if (base == null && baseOff != 0) {
        base = _asciiz(b, off + baseOff);
        if (suffixOff != 0) suffix = _asciiz(b, off + suffixOff) ?? '';
      }
      if (base != null && base.isNotEmpty) {
        fromInfo = suffix.isEmpty ? base : p.windows.join(base, suffix);
      }
    }
    off += size;
  }
  if (fromInfo != null) return fromInfo;
  // Fall back to the relative path in StringData (always Unicode on modern
  // Windows; the ANSI LinkInfo path cannot be decoded without the code page).
  if (flags & _isUnicode == 0) return null;
  if (flags & _hasName != 0) off = _skipString(d, off);
  if (flags & _hasRelativePath != 0 && off + 2 <= b.length) {
    final n = d.getUint16(off, Endian.little);
    if (off + 2 + n * 2 > b.length) return null;
    final rel = String.fromCharCodes(Uint16List.fromList(
        [for (var i = 0; i < n; i++) d.getUint16(off + 2 + i * 2, Endian.little)]));
    return p.windows.normalize(p.windows.join(lnkDir, rel));
  }
  return null;
}

int _skipString(ByteData d, int off) {
  if (off + 2 > d.lengthInBytes) return d.lengthInBytes;
  return off + 2 + d.getUint16(off, Endian.little) * 2;
}

String? _utf16z(Uint8List b, int off) {
  final units = <int>[];
  for (var i = off; i + 1 < b.length; i += 2) {
    final u = b[i] | (b[i + 1] << 8);
    if (u == 0) return String.fromCharCodes(units);
    units.add(u);
  }
  return null;
}

/// Only pure ASCII is accepted: the ANSI code page is unknown here.
String? _asciiz(Uint8List b, int off) {
  final out = <int>[];
  for (var i = off; i < b.length; i++) {
    if (b[i] == 0) return String.fromCharCodes(out);
    if (b[i] > 0x7F) return null;
    out.add(b[i]);
  }
  return null;
}
