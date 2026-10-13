// Pinyin lookup for search (full spelling and initials, with common
// polyphones) and for Chinese sort keys.
import 'pinyin_data.dart';

Map<int, (int, int)>? _alts;

Map<int, (int, int)> _alternates() {
  final m = <int, (int, int)>{};
  const s = pinyinAlternates;
  for (var i = 0; i + 2 < s.length; i += 3) {
    m[s.codeUnitAt(i) + pinyinFirst] = (s.codeUnitAt(i + 1), s.codeUnitAt(i + 2));
  }
  return m;
}

bool isHan(int cp) => cp == 0x3007 || (cp >= pinyinFirst && cp <= pinyinLast);

/// Primary toneless reading of [cp], or null if it is not a known Han
/// character.
String? primaryPinyin(int cp) {
  if (cp == 0x3007) return pinyinSyllables[pinyinLingIndex - 1];
  if (cp < pinyinFirst || cp > pinyinLast) return null;
  final i = pinyinPrimary.codeUnitAt(cp - pinyinFirst);
  return i == 0 ? null : pinyinSyllables[i - 1];
}

/// All toneless readings of [cp] (primary first, at most three).
List<String> pinyinReadings(int cp) {
  final p = primaryPinyin(cp);
  if (p == null) return const [];
  final a = (_alts ??= _alternates())[cp];
  if (a == null) return [p];
  return [p, if (a.$1 > 0) pinyinSyllables[a.$1 - 1], if (a.$2 > 0) pinyinSyllables[a.$2 - 1]];
}

/// True if [s] contains at least one character with a pinyin reading.
bool hasHan(String s) {
  for (final r in s.runes) {
    if (primaryPinyin(r) != null) return true;
  }
  return false;
}

/// Search variants of [s] (already lower-cased): full pinyin and initials,
/// with polyphonic characters taking their 1st, 2nd and 3rd readings in turn
/// ("音乐" -> yinle, yinyue, yl, yy). Non-Han characters are kept. Returns an
/// empty list if [s] has no Han characters.
List<String> pinyinVariants(String s, {int maxVariants = 4}) {
  final runes = s.runes.toList();
  final readings = <List<String>?>[];
  var maxReadings = 0;
  for (final r in runes) {
    final list = pinyinReadings(r);
    readings.add(list.isEmpty ? null : list);
    if (list.length > maxReadings) maxReadings = list.length;
  }
  if (maxReadings == 0) return const [];
  final full = <String>{};
  final initials = <String>{};
  for (var k = 0; k < maxReadings && full.length < maxVariants; k++) {
    final f = StringBuffer();
    final ini = StringBuffer();
    for (var i = 0; i < runes.length; i++) {
      final rd = readings[i];
      if (rd == null) {
        final ch = String.fromCharCode(runes[i]);
        f.write(ch);
        // Initials keep latin letters and digits, drop spaces/punctuation.
        if (_isAlnum(runes[i])) ini.write(ch);
      } else {
        final syl = rd[k < rd.length ? k : rd.length - 1];
        f.write(syl);
        ini.write(syl[0]);
      }
    }
    full.add(f.toString());
    initials.add(ini.toString());
  }
  return [...full, ...initials.take(maxVariants)];
}

bool _isAlnum(int c) => (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a);

/// Sort key: Han characters are replaced by their primary pinyin, latin text
/// is lower-cased and digit runs are zero-padded (natural order). Symbols
/// sort first, then digits, letters (pinyin interleaved), then other scripts.
String sortKey(String s) {
  final b = StringBuffer();
  final runes = s.runes.toList();
  var i = 0;
  while (i < runes.length) {
    final r = runes[i];
    if (r >= 0x30 && r <= 0x39) {
      var j = i;
      while (j < runes.length && runes[j] >= 0x30 && runes[j] <= 0x39) {
        j++;
      }
      var digits = String.fromCharCodes(runes.sublist(i, j)).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      if (digits.length < 12) digits = digits.padLeft(12, '0');
      b.write(digits);
      i = j;
      continue;
    }
    final p = primaryPinyin(r);
    if (p != null) {
      // A Han character sorts after latin text spelled the same way.
      b
        ..write(p)
        ..write('{');
    } else {
      b.write(String.fromCharCode(r).toLowerCase());
    }
    i++;
  }
  return b.toString();
}
