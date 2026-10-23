// Post-processes `flutter build web --wasm` output for app.chessever.com.
//
//   dart run scripts/finalize_web_build.dart build/web --preconnect <origin>
//
// Run by scripts/build_web.sh. It:
//
//  * deletes what the browser never loads: the native Stockfish binaries
//    (pubspec assets are shared by every platform), the JavaScript fallback
//    build, the CanvasKit renderers (the loader pins skwasm), RevenueCat's
//    web SDK, and the standalone loader files that index.html inlines;
//  * moves the compiled app and its assets into `v/<content hash>/`, so
//    every file there can be served `immutable` and a deploy never mixes
//    two builds in one browser cache;
//  * points the inlined loader at that directory and adds preconnect hints.
//
// Only the HTML page and files reached by fixed URLs stay at the root; they
// are served with revalidation.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const _assetBasePlaceholder = '__CHESSEVER_ASSET_BASE__';
const _preconnectMarker = '<!-- chessever:preconnect -->';

/// Paths (relative to the build directory) that stay at the root.
const _rootEntries = <String>{
  'index.html',
  'favicon.png',
  'manifest.json',
  'icons',
  // sqflite's shared worker and the sqlite3 build it loads, by page-relative
  // URL. A shared worker is keyed by its URL, so it should not move per
  // deploy either.
  'sqflite_sw.js',
  'sqlite3.wasm',
};

/// Never loaded by the browser build.
const _unusedEntries = <String>[
  // Native engine binaries, bundled because pubspec assets are shared.
  'assets/assets/engine',
  // The dart2js build only exists so `flutter build web --wasm` succeeds;
  // the loader never selects it (see web/flutter_bootstrap.js).
  'main.dart.js',
  // Inlined into index.html.
  'flutter.js',
  'flutter_bootstrap.js',
  // Flutter's deprecated service worker; the page registers none.
  'flutter_service_worker.js',
  // CanvasKit variants. The loader is pinned to skwasm.
  'canvaskit/canvaskit.js',
  'canvaskit/canvaskit.js.symbols',
  'canvaskit/canvaskit.wasm',
  'canvaskit/chromium',
  'canvaskit/webparagraph',
  'canvaskit/wimp.js',
  'canvaskit/wimp.js.symbols',
  'canvaskit/wimp.wasm',
  // Build bookkeeping.
  '.last_build_id',
  // RevenueCat's web SDK. Only the Mac App Store edition bills through
  // RevenueCat; see _revenueCatStub.
  'assets/packages/purchases_flutter',
];

/// flutter_soloud starts its worker from this page-relative URL, which it
/// hardcodes, so a copy has to exist at the root as well.
const _soloudWorker = 'assets/packages/flutter_soloud/web/worker.dart.js';

/// purchases_flutter's web plugin injects its ~1 MB SDK from this hardcoded
/// page-relative URL while plugins register, before the app runs, whether or
/// not the app ever bills through it. The browser edition does not, so an
/// empty script answers the request: the plugin's load succeeds and nothing
/// is parsed.
const _revenueCatScript =
    'assets/packages/purchases_flutter/assets/web/purchases_js_hybrid_mappings.js';
const _revenueCatStub =
    '// RevenueCat is not used by the browser edition of ChessEver.\n';

void main(List<String> args) {
  if (args.isEmpty || args.first.startsWith('-')) {
    stderr.writeln(
      'usage: dart run scripts/finalize_web_build.dart <build dir> '
      '[--preconnect <origin>]...',
    );
    exit(64);
  }
  final out = Directory(args.first);
  final preconnect = <String>[];
  for (var i = 1; i < args.length; i++) {
    if (args[i] == '--preconnect' && i + 1 < args.length) {
      preconnect.add(Uri.parse(args[++i]).origin);
    } else {
      stderr.writeln('unknown argument: ${args[i]}');
      exit(64);
    }
  }

  String path(String relative) => '${out.path}/$relative';

  for (final required in [
    'index.html',
    'main.dart.wasm',
    'main.dart.mjs',
    'canvaskit/skwasm.wasm',
    'sqflite_sw.js',
    'sqlite3.wasm',
    _soloudWorker,
  ]) {
    if (FileSystemEntity.typeSync(path(required)) ==
        FileSystemEntityType.notFound) {
      _fail('$required is missing from ${out.path}');
    }
  }
  if (Directory(path('v')).existsSync()) {
    _fail('${out.path} was already finalized; build again first');
  }

  for (final unused in _unusedEntries) {
    final type = FileSystemEntity.typeSync(path(unused));
    if (type == FileSystemEntityType.directory) {
      Directory(path(unused)).deleteSync(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      File(path(unused)).deleteSync();
    }
  }
  for (final entity in out.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.symbols')) {
      entity.deleteSync();
    }
  }

  final versioned = <String>[
    for (final entity in out.listSync())
      if (!_rootEntries.contains(_name(entity))) _name(entity),
  ]..sort();

  final digest = _contentHash(out, versioned);
  final base = 'v/$digest/';
  Directory(path(base)).createSync(recursive: true);
  for (final entry in versioned) {
    FileSystemEntity entity = File(path(entry));
    if (FileSystemEntity.isDirectorySync(path(entry))) {
      entity = Directory(path(entry));
    }
    entity.renameSync(path('$base$entry'));
  }

  File(path(_soloudWorker))
    ..createSync(recursive: true)
    ..writeAsBytesSync(File(path('$base$_soloudWorker')).readAsBytesSync());
  File(path(_revenueCatScript))
    ..createSync(recursive: true)
    ..writeAsStringSync(_revenueCatStub);

  final indexFile = File(path('index.html'));
  var index = indexFile.readAsStringSync();
  if (!index.contains(_assetBasePlaceholder)) {
    _fail('index.html has no $_assetBasePlaceholder; was the loader inlined?');
  }
  if (index.contains('{{')) {
    _fail('index.html still holds an unexpanded {{template}} token');
  }
  index = index.replaceAll(_assetBasePlaceholder, '/$base');
  index = index.replaceFirst(
    _preconnectMarker,
    [
      for (final origin in preconnect)
        '<link rel="preconnect" href="$origin" crossorigin>',
    ].join('\n  '),
  );
  indexFile.writeAsStringSync(index);

  stdout.writeln('web build finalized: /$base');
  for (final file in ['main.dart.wasm', 'canvaskit/skwasm.wasm']) {
    final bytes = File(path('$base$file')).lengthSync();
    stdout.writeln('  $file ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB');
  }
}

String _name(FileSystemEntity entity) =>
    entity.uri.pathSegments.lastWhere((segment) => segment.isNotEmpty);

/// A short hash over every versioned file's path and bytes.
String _contentHash(Directory root, List<String> entries) {
  final files = <File>[
    for (final entry in entries)
      if (FileSystemEntity.isDirectorySync('${root.path}/$entry'))
        ...Directory(
          '${root.path}/$entry',
        ).listSync(recursive: true).whereType<File>()
      else
        File('${root.path}/$entry'),
  ]..sort((a, b) => a.path.compareTo(b.path));
  final listing = StringBuffer();
  for (final file in files) {
    final relative = file.path.substring(root.path.length);
    listing.writeln('$relative\t${sha256.convert(file.readAsBytesSync())}');
  }
  return sha256
      .convert(utf8.encode(listing.toString()))
      .toString()
      .substring(0, 16);
}

Never _fail(String message) {
  stderr.writeln('finalize_web_build: $message');
  exit(1);
}
