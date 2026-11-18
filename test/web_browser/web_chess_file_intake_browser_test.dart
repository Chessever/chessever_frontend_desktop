@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:libcompress/libcompress.dart';
import 'package:path/path.dart' as p;
import 'package:web/web.dart' as web;

import 'package:chessever/desktop/services/cbh_conversion_service.dart';
import 'package:chessever/desktop/services/cbh_move_tables.dart';
import 'package:chessever/desktop/services/library_pgn_import_picker.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/web_file_intake.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

import 'harness.dart';

void main() {
  setUpAll(mountBrowserLocalDatabase);

  setUp(() async {
    final output = await Directory.systemTemp.createTemp('web_cbh_test_');
    addTearDown(() => output.delete(recursive: true));
    CbhConversionGateway.handler =
        CbhConversionService(destination: output).convert;
    addTearDown(() => CbhConversionGateway.handler = null);
  });

  test(
    'dropping a classic CBH set opens its annotated game in Library',
    () async {
      final files = _classicDatabase('Study');
      final paths = await copyDroppedChessFilesIntoAppStorage(
        _dropFiles(files),
      );

      expect(paths.map(p.basename), ['Study.CBH']);
      final games = await _openInLibrary(paths);
      _expectChessBaseGame(games.single, files['Study.cba']!);
    },
  );

  test(
    'Library picker admits every database format and only links plain PGN',
    () async {
      final classic = _classicDatabase('Study');
      final bytes = Uint8List.fromList(utf8.encode(_annotatedPgn));
      final formats = {
        ...classic,
        'archive.CBV': _cbvArchive(_classicDatabase('Archive')),
        'positions.pgn': bytes,
        'positions.pgn.bz2': BZip2Encoder().encodeBytes(bytes),
        'positions.pgn.zst': ZstdCodec().compress(bytes),
      };
      final permissionRequests = <String>[];
      final writtenBack = Completer<String>();
      _setOpenFilePicker((options) {
        final args = options.dartify() as Map;
        expect(args['multiple'], isTrue);
        final type = (args['types'] as List).single as Map;
        final extensions = (type['accept'] as Map).values.expand(
          (values) => values as List,
        );
        expect(
          extensions,
          unorderedEquals([
            '.pgn',
            '.bz2',
            '.zst',
            '.cbh',
            '.cbv',
            '.cbp',
            '.cbt',
            '.cbc',
            '.cbs',
            '.cbg',
            '.cba',
          ]),
        );
        return [
          for (final entry in formats.entries)
            _fileHandle(
              entry.key,
              entry.value,
              permissionRequests,
              onWrite: writtenBack.complete,
            ),
        ];
      });

      final paths = (await pickLibraryPgnDatabasePaths())!;
      expect(paths.map(p.basename), [
        'Study.CBH',
        'archive.CBV',
        'positions.pgn',
        'positions.pgn.bz2',
        'positions.pgn.zst',
      ]);
      expect(permissionRequests, ['positions.pgn']);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final repository = container.read(localChessDatabaseRepositoryProvider);
      final games = await _openInLibrary(paths, repository: repository);
      expect(games, hasLength(5));
      for (final game in games) {
        if (game.metadata.containsKey('ChessBaseAnnotationFrame')) {
          _expectChessBaseGame(game, classic['Study.cba']!);
        } else {
          expect(game.metadata['White'], 'Işık, İpek');
          expect(game.startingFen, _startFen);
          expect(game.mainline.map((move) => move.san), ['c5', 'Nf3']);
          expect(game.mainline.first.variations!.single.single.san, 'e5');
          expect(game.mainline.first.comments, contains('The Sicilian'));
          expect(game.mainline.first.nags, contains(1));
        }
      }
      final pgn = paths.singleWhere(
        (path) => p.basename(path) == 'positions.pgn',
      );
      await File(pgn).writeAsString('Edited PGN');
      expect(
        await writtenBack.future.timeout(const Duration(seconds: 5)),
        'Edited PGN',
      );
    },
  );

  test(
    'a picked folder can contain same-named ChessBase sets in different directories',
    () async {
      final files = {
        for (final entry in _classicDatabase('Study').entries)
          'Library/A/${entry.key}': entry.value,
        for (final entry in _classicDatabase('Study').entries)
          'Library/B/${entry.key}': entry.value,
      };
      _setInputPicker(files, directory: true);
      final library = LocalChessLibraryNotifier();
      addTearDown(library.dispose);
      final opened = await library.pickFolder();
      expect(opened, isTrue, reason: library.state.error);
      expect(library.state.source!.label, 'Library');
      expect(library.state.source!.games, hasLength(2));
    },
  );

  test(
    'the browser file input also opens a complete classic database',
    () async {
      _setOpenFilePicker(null);
      final files = _classicDatabase('Copy');
      _setInputPicker(files);
      final paths = (await pickLibraryPgnDatabasePaths())!;
      expect(paths.map(p.basename), ['Copy.CBH']);
      final games = await _openInLibrary(paths);
      _expectChessBaseGame(games.single, files['Copy.cba']!);
    },
  );

  test('a missing companion cannot come from another drop', () async {
    final files = _classicDatabase('Study');
    final complete = await copyDroppedChessFilesIntoAppStorage([
      DropItemDirectory.fromData(Uint8List(0), _dropFiles(files), name: 'A'),
      DropItemDirectory.fromData(Uint8List(0), _dropFiles(files), name: 'B'),
    ]);
    expect(complete.map((path) => p.basename(p.dirname(path))), ['A', 'B']);
    expect(await _openInLibrary(complete), hasLength(2));

    final earlier = await copyDroppedChessFilesIntoAppStorage(
      _dropFiles(files),
    );
    expect(await _openInLibrary(earlier), hasLength(1));

    final loose = await copyDroppedChessFilesIntoAppStorage(
      _dropFiles({'Study.CBH': files['Study.CBH']!}),
    );
    final library = LocalChessLibraryNotifier();
    addTearDown(library.dispose);
    expect(await library.openPaths(loose), isFalse);
    expect(library.state.error, contains('Missing .cbp companion file'));
    expect(library.state.source, isNull);
  });
}

const _startFen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
const _annotatedPgn = '''
[Event "Opening study"]
[White "Işık, İpek"]
[Black "Black"]
[SetUp "1"]
[FEN "$_startFen"]
[Result "1-0"]

1... c5 \$1 {The Sicilian} (1... e5) 2. Nf3 1-0
''';

Future<List<ChessGame>> _openInLibrary(
  List<String> paths, {
  LocalChessDatabaseRepository? repository,
}) async {
  final library = LocalChessLibraryNotifier(
    localDatabaseRepository: repository,
  );
  addTearDown(library.dispose);
  final opened = await library.openPaths(paths);
  expect(opened, isTrue, reason: library.state.error);
  expect(library.state.warning, isNull);
  return library.state.source!.games
      .map((entry) => ChessGame.fromPgn(entry.id, entry.rawPgn))
      .toList();
}

void _expectChessBaseGame(ChessGame game, Uint8List annotations) {
  expect(game.metadata['White'], 'André');
  expect(game.metadata['Result'], '1-0');
  expect(game.mainline.map((move) => move.san), ['e4', 'e5']);
  expect(game.mainline.first.comments, contains('Claim the centre'));
  expect(game.mainline.first.variations!.single.single.san, 'c5');
  expect(
    base64Decode(game.metadata['ChessBaseAnnotationFrame'] as String),
    annotations.sublist(26),
  );
}

void _setOpenFilePicker(List<JSObject> Function(JSObject)? pick) {
  final window = web.window;
  final property = 'showOpenFilePicker'.toJS;
  final original = window.getProperty<JSAny?>(property);
  final replacement =
      pick == null
          ? null
          : ((JSObject options) => Future.value(pick(options).toJS).toJS).toJS;
  window.setProperty(property, replacement);
  addTearDown(() => window.setProperty(property, original));
}

JSObject _fileHandle(
  String name,
  Uint8List bytes,
  List<String> permissions, {
  required void Function(String) onWrite,
}) {
  final file = web.File([bytes.toJS].toJS, name);
  final writable =
      JSObject()
        ..['write'] =
            ((JSUint8Array contents) {
              onWrite(utf8.decode(contents.toDart));
              return Future<JSAny?>.value().toJS;
            }).toJS
        ..['close'] = (() => Future<JSAny?>.value().toJS).toJS;
  return JSObject()
    ..['name'] = name.toJS
    ..['getFile'] = (() => Future.value(file).toJS).toJS
    ..['createWritable'] = (() => Future.value(writable).toJS).toJS
    ..['requestPermission'] =
        ((JSObject _) {
          permissions.add(name);
          return Future.value('granted'.toJS).toJS;
        }).toJS;
}

void _setInputPicker(Map<String, Uint8List> files, {bool directory = false}) {
  final prototype = web.window
      .getProperty<JSObject>('HTMLInputElement'.toJS)
      .getProperty<JSObject>('prototype'.toJS);
  final original = prototype['click'];
  prototype['click'] =
      ((web.HTMLInputElement input) {
        expect(input.hasAttribute('webkitdirectory'), directory);
        expect(input.multiple, isTrue);
        if (!directory) {
          expect(
            input.accept.split(','),
            containsAll([
              '.cbh',
              '.cbp',
              '.cbt',
              '.cbc',
              '.cbs',
              '.cbg',
              '.cba',
              '.cbv',
            ]),
          );
        }
        final transfer = web.DataTransfer();
        final object = web.window.getProperty<JSObject>('Object'.toJS);
        for (final entry in files.entries) {
          final file = web.File([entry.value.toJS].toJS, p.basename(entry.key));
          if (directory) {
            object.callMethod<JSObject>(
              'defineProperty'.toJS,
              file,
              'webkitRelativePath'.toJS,
              {'value': entry.key}.jsify(),
            );
          }
          transfer.items.add(file);
        }
        input.files = transfer.files;
        input.dispatchEvent(web.Event('change'));
      }).toJSCaptureThis;
  addTearDown(() => prototype['click'] = original);
}

List<DropItem> _dropFiles(Map<String, Uint8List> files) => [
  for (final entry in files.entries)
    DropItemFile.fromData(entry.value, name: entry.key),
];

// Build a CBV with one uncompressed block per member.
Uint8List _cbvArchive(Map<String, Uint8List> files) {
  const entrySize = 140;
  final tableSize = 8 + entrySize * files.length;
  final size = files.values.fold(
    tableSize,
    (sum, data) => sum + 5 + data.length,
  );
  final archive =
      Uint8List(size)
        ..[0] = 8
        ..[4] = entrySize;
  final header = ByteData.sublistView(archive)
    ..setUint16(2, files.length, Endian.little);
  var entryOffset = 8;
  var blockOffset = tableSize;
  for (final entry in files.entries) {
    archive.setAll(entryOffset, entry.key.codeUnits);
    header.setUint32(entryOffset + 132, 5 + entry.value.length, Endian.little);
    header.setUint32(entryOffset + 136, entry.value.length, Endian.little);
    header.setUint16(blockOffset, 1 + entry.value.length, Endian.little);
    archive.setAll(blockOffset + 5, entry.value);
    entryOffset += entrySize;
    blockOffset += 5 + entry.value.length;
  }
  return archive;
}

Map<String, Uint8List> _classicDatabase(String stem) {
  final index =
      Uint8List(92)
        ..[2] = 0x2c
        ..[4] = 0x2e
        ..[5] = 1
        ..[9] = 2
        ..[50] =
            26 // CBG offset.
        ..[54] =
            26 // CBA offset.
        ..[60] =
            1 // Black player index.
        ..[73] = 2; // White wins.
  final players =
      Uint8List(28 + 67 * 2)
        ..setAll(28 + 9, latin1.encode('André'))
        ..setAll(28 + 67 + 9, 'Black'.codeUnits);
  final event = Uint8List(28 + 99)..setAll(28 + 9, 'Opening study'.codeUnits);
  final moves = <int>[
    cbhMoveLookup.indexOf(0x80), // e4
    (cbhMoveLookup.indexOf(0xfe) + 1) & 255, // Push variation.
    (cbhMoveLookup.indexOf(0x80) + 1) & 255, // e5
    (cbhMoveLookup.indexOf(0xff) + 2) & 255, // Pop to after e4.
    (cbhMoveLookup.indexOf(0x78) + 2) & 255, // c5
  ];
  final games =
      Uint8List(26 + 4 + moves.length)
        ..[29] = 4 + moves.length
        ..setAll(30, moves);
  final comment = 'Claim the centre'.codeUnits;
  final annotations =
      Uint8List(26 + 14 + 8 + comment.length)
        ..[39] = 14 + 8 + comment.length
        ..[43] =
            0x02 // After-move comment at move address 0.
        ..[45] = 8 + comment.length
        ..setAll(48, comment);
  return {
    '$stem.CBH': index,
    '$stem.cbp': players,
    '$stem.cbt': event,
    '$stem.cbc': Uint8List(28 + 62),
    '$stem.cbs': Uint8List(28 + 68),
    '$stem.cbg': games,
    '$stem.cba': annotations,
  };
}
