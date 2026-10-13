import '../path/path_key.dart';

/// Normalizes text for matching: NFC, full-width ASCII to half-width,
/// ideographic space to space, lower case.
String searchNormalize(String s) {
  var needs = false;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0x41 && c <= 0x5A || c > 0x7F) {
      needs = true;
      break;
    }
  }
  if (!needs) return s;
  final n = nfc(s);
  final b = StringBuffer();
  for (var i = 0; i < n.length; i++) {
    final c = n.codeUnitAt(i);
    if (c >= 0xFF01 && c <= 0xFF5E) {
      b.writeCharCode(c - 0xFEE0);
    } else if (c == 0x3000) {
      b.writeCharCode(0x20);
    } else {
      b.writeCharCode(c);
    }
  }
  return b.toString().toLowerCase();
}
