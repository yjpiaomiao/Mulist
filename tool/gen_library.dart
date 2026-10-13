// Generates a synthetic library for manual testing and benchmarks:
//
//   dart run tool/gen_library.dart <out-dir> [count=10000]
//
// Tiny valid MP3/FLAC files with random Chinese/English tags, organized as
// Artist/Album/NN Title.ext, a cover on every third album.
import 'dart:io';
import 'dart:math';

import 'package:mm_native/mm_native.dart';

const _fixtures = 'packages/mm_native/test/fixtures';
const _han = '的一是在不了有和人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定行学法所民得经十三之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其些然前外天政四日那社义事平形相全表间样与关各重新线内数正心反你明看原又么利比或但质气第向道命此变条只没结解问意建月公无系军很情者最立代想已通并提直题党程展五果料象员革位入常文总次品式活设及管特件长求老头基资边流路级少图山统接知较将组见计别她手角期根论运农指几九区强放决西被干做必战先回则任取据处理府研质记布石林量';
const _latin = ['Love', 'Night', 'Dream', 'Sky', 'Blue', 'Rain', 'Fire', 'Song', 'Heart', 'Time', 'Light', 'Road', 'Home', 'Star'];

void main(List<String> args) {
  final out = Directory(args.isEmpty ? 'build/synthetic_library' : args[0]);
  final count = args.length > 1 ? int.parse(args[1]) : 10000;
  final rnd = Random(2024);
  String han(int n) => String.fromCharCodes(List.generate(n, (_) => _han.codeUnitAt(rnd.nextInt(_han.length))));
  String latin(int n) => List.generate(n, (_) => _latin[rnd.nextInt(_latin.length)]).join(' ');
  String name() => rnd.nextInt(3) == 0 ? latin(1 + rnd.nextInt(3)) : han(2 + rnd.nextInt(5));
  final artists = List.generate(400, (i) => rnd.nextInt(4) == 0 ? 'Artist ${latin(1)} $i' : han(2 + rnd.nextInt(2)));
  final genres = ['流行', 'Rock', '民谣', 'Jazz', '古典', 'Electronic', '说唱', 'Pop'];
  final mp3 = File('$_fixtures/notag.mp3').readAsBytesSync();
  final flac = File('$_fixtures/nopad.flac').readAsBytesSync();
  final cover = '$_fixtures/cover.jpg';
  final sw = Stopwatch()..start();
  var made = 0;
  var album = 0;
  while (made < count) {
    final artist = artists[rnd.nextInt(artists.length)];
    final albumName = name();
    final year = 1980 + rnd.nextInt(45);
    final genre = genres[rnd.nextInt(genres.length)];
    final tracks = 8 + rnd.nextInt(8);
    final useFlac = rnd.nextInt(4) == 0;
    final dir = Directory('${out.path}/${_safe(artist)}/${_safe(albumName)}')..createSync(recursive: true);
    for (var t = 1; t <= tracks && made < count; t++) {
      final title = name();
      final ext = useFlac ? 'flac' : 'mp3';
      final f = File('${dir.path}/${t.toString().padLeft(2, '0')} ${_safe(title)}.$ext');
      if (f.existsSync()) continue;
      f.writeAsBytesSync(useFlac ? flac : mp3);
      final plan = MmNative.prepareWrite(MmTarget.path(f.path), {
        'set': {
          'TITLE': [title],
          'ARTIST': [artist],
          'ALBUM': [albumName],
          'ALBUMARTIST': [artist],
          'TRACKNUMBER': ['$t/$tracks'],
          'DATE': ['$year'],
          'GENRE': [genre],
        },
        if (album % 3 == 0) 'cover': {'action': 'set', 'path': cover},
      });
      MmNative.commit(MmTarget.path(f.path), plan);
      final stage = plan['stagePath'] as String?;
      if (stage != null && File(stage).existsSync()) File(stage).deleteSync();
      made++;
    }
    album++;
  }
  stdout.writeln('$made files in ${sw.elapsed.inSeconds}s -> ${out.path}');
}

String _safe(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
