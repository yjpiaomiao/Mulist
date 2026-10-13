import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_manager/core/model/track.dart';
import 'package:music_manager/core/pinyin/pinyin.dart';
import 'package:music_manager/core/search/search_index.dart';

TrackRow t(int id, String title, String artist, {String album = '', int track = 0, String path = ''}) =>
    TrackRow(
      id: id,
      rootId: 1,
      relPath: path.isEmpty ? '$artist/$title.mp3' : path,
      title: title,
      artist: artist,
      album: album,
      trackNo: track,
    );

void main() {
  test('pinyin variants and polyphones', () {
    expect(pinyinVariants('音乐'), containsAll(['yinle', 'yinyue', 'yl', 'yy']));
    expect(pinyinVariants('周杰伦'), containsAll(['zhoujielun', 'zjl']));
    expect(pinyinVariants('abc'), isEmpty);
    expect(pinyinVariants('重庆 live'), contains('chongqing live'));
    expect(pinyinReadings('长'.runes.first).first, 'chang');
  });

  test('sort keys interleave pinyin with latin, natural numbers', () {
    final names = ['周杰伦', 'Adele', '阿杜', 'zhou', 'Track 10', 'Track 2', '陈奕迅', 'Beyond', '张学友'];
    names.sort((a, b) => sortKey(a).compareTo(sortKey(b)));
    expect(names, ['Adele', '阿杜', 'Beyond', '陈奕迅', 'Track 2', 'Track 10', '张学友', 'zhou', '周杰伦']);
  });

  group('search', () {
    final idx = SearchIndex()
      ..upsertAll([
        t(1, '晴天', '周杰伦', album: '叶惠美', track: 3),
        t(2, '音乐家', '某人'),
        t(3, 'Hello', 'Adele', album: '25', track: 1),
        t(4, '十年', '陈奕迅'),
        t(5, 'Ｆｕｌｌ　Width', 'X'),
        t(6, 'Song', 'B', path: '周杰伦/live/song.flac'),
      ]);
    List<int> s(String q, [SortField f = SortField.added]) => idx.search(q, f).toList();

    test('substring AND', () {
      expect(s('晴'), [1]);
      expect(s('周杰伦 晴天'), [1]);
      expect(s('周杰伦 十年'), isEmpty);
      expect(s('hello adele'), [3]);
      expect(s('HELLO'), [3]);
      expect(s('full width'), [5]);
    });

    test('pinyin full spelling, initials and polyphones', () {
      expect(s('qingtian'), [1]);
      expect(s('zjl'), [1, 6]);
      expect(s('yinle'), [2]);
      expect(s('yinyue'), [2]);
      expect(s('ylj'), [2]);
      expect(s('shinian'), [4]);
      expect(s('chen'), [4]);
    });

    test('file name and field prefixes', () {
      expect(s('live'), [6]);
      expect(s('artist:zjl'), [1]);
      expect(s('file:周杰伦'), [1, 6]);
      expect(s('title:周'), isEmpty);
      expect(s('专辑:叶惠美'), [1]);
    });

    test('narrowing detection', () {
      expect(SearchIndex.narrows('zh', 'zho'), isTrue);
      expect(SearchIndex.narrows('zho', 'zh'), isFalse);
      expect(SearchIndex.narrows('a', 'a b'), isTrue);
      expect(SearchIndex.narrows('', 'a'), isFalse);
    });
  });

  test('10k tracks: build, sort and search fast enough', () {
    final rnd = Random(1);
    const han = '的一是不了人我在有他这中大来上国个到说们为子和你地出道也时年得就那要下以生会自着去之过家学对可她里后小么心多天而能好都然没日于起还发成事只作当想看文无开手十用主行方又如前所本见经头面公同三已老从动两长知民样现分将外但身些与高意进把法此实回二理美点月明其种声全工己话儿者向情部正名定女问力机给等几很业最间新什打便位因重被走电四第门相次东政海口使教西再平真听世气信北少关并内加化由却代军产入先山五太水万市眼体别处总才场师书比住员九笑性通目华报立马命张活难神数件安表原车白应路期叫死常提感金何更反合放做系计或司利受光王果亲界及今京务制解各任至清物台象记边共风战干接它许八特觉望直服毛林题建南度统色字请交爱让认算论百吃义科怎元社术结六功指思非流每青管夫连远资队跟带花快条院变联言权往展该领传近留红治决周保达办运武半候七必城父强步完革深区际米';
    String word(int n) => String.fromCharCodes(List.generate(n, (_) => han.codeUnitAt(rnd.nextInt(han.length))));
    final rows = [
      for (var i = 0; i < 10000; i++)
        t(i + 1, word(2 + rnd.nextInt(5)), rnd.nextBool() ? word(3) : 'Artist ${rnd.nextInt(500)}',
            album: word(4), track: rnd.nextInt(20), path: '${word(3)}/${word(5)} ${rnd.nextInt(99)}.flac'),
    ];
    final sw = Stopwatch()..start();
    final idx = SearchIndex()..upsertAll(rows);
    final build = sw.elapsedMilliseconds;
    sw.reset();
    idx.sorted(SortField.artist);
    final sort = sw.elapsedMilliseconds;
    final times = <int>[];
    for (final q in ['a', 'zh', 'zhang', '的', 'artist 1', 'yl', 'de', 'xyzq', '中国', 'shi jie']) {
      sw.reset();
      idx.search(q, SortField.artist);
      times.add(sw.elapsedMicroseconds);
    }
    times.sort();
    // ignore: avoid_print
    print('build ${build}ms, sort ${sort}ms, search p50 ${times[5] ~/ 1000}ms max ${times.last ~/ 1000}ms');
    expect(times[8], lessThan(30000), reason: 'search p90 (JIT, debug)');
  });
}
