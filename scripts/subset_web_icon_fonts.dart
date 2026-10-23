// Subsets the icon fonts of the browser build to the icons the app uses.
//
//   dart run scripts/subset_web_icon_fonts.dart <build dir> <app.dill> \
//     <flutter root>
//
// Run by scripts/build_web.sh. `flutter build web --wasm` also compiles a
// dart2js fallback, and Flutter's icon tree shaker reads that fallback's
// kernel. Ours is the small "unsupported browser" app (lib/main_web.dart),
// so Flutter would keep only its few icons and every other icon in the app
// would render blank. The build script therefore passes
// --no-tree-shake-icons and runs this instead, on a kernel of the Wasm app,
// with the same const finder and font-subset tools Flutter uses.
import 'dart:convert';
import 'dart:io';

/// Web measures font height with a space, so Flutter keeps it in every
/// subset it makes for the web.
const _spaceCodePoint = 32;

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'usage: dart run scripts/subset_web_icon_fonts.dart <build dir> '
      '<app.dill> <flutter root>',
    );
    exit(64);
  }
  final [buildDir, appDill, flutterRoot] = args;
  final tools = _findTools(flutterRoot);
  final dart = '$flutterRoot/bin/cache/dart-sdk/bin/dart';

  final finder = await Process.run(dart, [
    tools.constFinder,
    '--kernel-file',
    appDill,
    '--class-library-uri',
    'package:flutter/src/widgets/icon_data.dart',
    '--class-name',
    'IconData',
    '--annotation-class-name',
    '_StaticIconProvider',
    '--annotation-class-library-uri',
    'package:flutter/src/widgets/icon_data.dart',
  ]);
  if (finder.exitCode != 0) {
    _fail('const finder failed:\n${finder.stderr}');
  }
  final found = jsonDecode(finder.stdout as String) as Map<String, Object?>;
  final nonConstant = found['nonConstantLocations'] as List<Object?>;
  if (nonConstant.isNotEmpty) {
    // Flutter refuses to tree-shake in this case too: an IconData built at
    // runtime could name any glyph.
    _fail(
      'IconData is constructed at runtime here, so icons cannot be '
      'subset:\n${const JsonEncoder.withIndent('  ').convert(nonConstant)}',
    );
  }

  final codePointsByFamily = <String, Set<int>>{};
  for (final instance in found['constantInstances'] as List<Object?>) {
    final icon = instance as Map<String, Object?>;
    final family = icon['fontFamily'] as String?;
    final codePoint = icon['codePoint'] as num?;
    if (family == null || codePoint == null) continue;
    final package = icon['fontPackage'] as String?;
    final key = package == null ? family : 'packages/$package/$family';
    (codePointsByFamily[key] ??= <int>{}).add(codePoint.round());
  }

  final manifest =
      jsonDecode(File('$buildDir/assets/FontManifest.json').readAsStringSync())
          as List<Object?>;
  for (final entry in manifest) {
    final family = entry as Map<String, Object?>;
    final codePoints = codePointsByFamily[family['family']];
    if (codePoints == null) continue;
    final fonts = family['fonts'] as List<Object?>;
    if (fonts.length != 1) {
      _fail('${family['family']} has several font files; cannot subset it');
    }
    final asset = (fonts.single as Map<String, Object?>)['asset'] as String;
    await _subset(
      tools.fontSubset,
      File('$buildDir/assets/$asset'),
      codePoints,
    );
  }
}

Future<void> _subset(String fontSubset, File font, Set<int> codePoints) async {
  final output = File('${font.path}.subset');
  final process = await Process.start(fontSubset, [output.path, font.path]);
  final sorted = codePoints.toList()..sort();
  process.stdin.write(
    [...sorted.map((c) => '$c'), 'optional:$_spaceCodePoint'].join(' '),
  );
  await process.stdin.close();
  final stderrText = process.stderr.transform(utf8.decoder).join();
  await process.stdout.drain<void>();
  if (await process.exitCode != 0) {
    _fail('font-subset failed for ${font.path}:\n${await stderrText}');
  }
  final before = font.lengthSync();
  output.renameSync(font.path);
  stdout.writeln(
    '${font.uri.pathSegments.last}: ${codePoints.length} icons, '
    '${before ~/ 1024} KB -> ${font.lengthSync() ~/ 1024} KB',
  );
}

({String constFinder, String fontSubset}) _findTools(String flutterRoot) {
  final engine = Directory('$flutterRoot/bin/cache/artifacts/engine');
  final executable = Platform.isWindows ? 'font-subset.exe' : 'font-subset';
  if (engine.existsSync()) {
    for (final host in engine.listSync().whereType<Directory>()) {
      final constFinder = File('${host.path}/const_finder.dart.snapshot');
      final fontSubset = File('${host.path}/$executable');
      if (constFinder.existsSync() && fontSubset.existsSync()) {
        return (constFinder: constFinder.path, fontSubset: fontSubset.path);
      }
    }
  }
  _fail(
    'const_finder and font-subset were not found under ${engine.path}; '
    'run `flutter precache` first',
  );
}

Never _fail(String message) {
  stderr.writeln('subset_web_icon_fonts: $message');
  exit(1);
}
