// Builds the native core (TagLib 2.3.2 + mm_core shim) as one shared
// library through Dart native assets.
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _taglibDirs = [
  '',
  'ape',
  'asf',
  'dsdiff',
  'dsf',
  'flac',
  'mp4',
  'mpc',
  'mpeg',
  'mpeg/id3v1',
  'mpeg/id3v2',
  'mpeg/id3v2/frames',
  'ogg',
  'ogg/flac',
  'ogg/opus',
  'ogg/speex',
  'ogg/vorbis',
  'riff',
  'riff/aiff',
  'riff/wav',
  'toolkit',
  'trueaudio',
  'wavpack',
];

const _coreSources = [
  'src/audio_region.cpp',
  'src/base_file.cpp',
  'src/fsutil.cpp',
  'src/overlay_stream.cpp',
  'src/tagio.cpp',
  'src/thumbs.cpp',
];

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final root = input.packageRoot;
    final taglibSources = <String>[];
    for (final dir in _taglibDirs) {
      final d = Directory.fromUri(root.resolve('third_party/taglib/taglib/$dir'));
      final files = d
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.cpp'))
          .map((f) => 'third_party/taglib/taglib/${dir.isEmpty ? '' : '$dir/'}'
              '${f.uri.pathSegments.last}')
          .toList()
        ..sort();
      taglibSources.addAll(files);
    }

    final code = input.config.code;
    final os = code.targetOS;
    final msvc = os == OS.windows;
    final flags = <String>[
      if (msvc) ...[
        '/EHsc',
        '/utf-8',
        '/Gy',
        '/Gw',
        '/GS',
        '/MP',
        '/W1',
        '/wd4251',
        '/wd4275',
      ] else ...[
        '-fvisibility=hidden',
        '-fvisibility-inlines-hidden',
        '-ffunction-sections',
        '-fdata-sections',
        '-fexceptions',
        '-frtti',
        '-w',
        if (os == OS.macOS || os == OS.iOS)
          '-Wl,-dead_strip'
        else ...[
          '-Wl,--gc-sections',
          '-Wl,--exclude-libs,ALL',
          '-s',
        ],
        if (os == OS.android) '-Wl,-z,max-page-size=16384',
      ],
    ];

    final builder = CBuilder.library(
      name: 'mm_core',
      assetName: 'mm_core',
      language: Language.cpp,
      std: 'c++17',
      sources: [..._coreSources, ...taglibSources],
      includes: [
        'src/taglib_config',
        'src',
        for (final d in _taglibDirs) 'third_party/taglib/taglib/$d',
        'third_party/utfcpp/source',
        'third_party/stb',
      ],
      defines: {
        'TAGLIB_STATIC': null,
        'HAVE_CONFIG_H': null,
        if (msvc) ...{
          'NOMINMAX': null,
          'WIN32_LEAN_AND_MEAN': null,
          '_CRT_SECURE_NO_WARNINGS': null,
          'UNICODE': null,
          '_UNICODE': null,
        },
      },
      flags: flags,
      optimizationLevel: OptimizationLevel.oS,
      buildModeDefine: false,
    );
    await builder.run(input: input, output: output);
  });
}
