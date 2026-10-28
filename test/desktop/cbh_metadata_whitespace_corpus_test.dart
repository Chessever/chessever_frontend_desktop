import 'dart:convert';
import 'dart:io';

import 'package:chessever/desktop/services/cbh_conversion_service.dart';
import 'package:chessever/desktop/services/cbh_index_reader.dart';
import 'package:chessever/desktop/services/cbh_frame_reader.dart';
import 'package:chessever/utils/pgn_multi_parser.dart' show splitPgnGames;
import 'package:crypto/crypto.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final manifest = Platform.environment['CHESSEVER_CBH_TAB_FIXTURES'];
  for (final label in ['desktop', 'onedrive']) {
    test(
      'complete $label My games imports through the actual default Dart backend without metadata loss',
      () async {
        final fixtures =
            (jsonDecode(await File(manifest!).readAsString()) as List)
                .cast<Map<String, dynamic>>();
        final fixture = fixtures.singleWhere((f) => f['label'] == label);
        final source = File(fixture['frozen'] as String);
        final family = source.parent.listSync().whereType<File>().toList();
        final before = {
          for (final f in family)
            f.path: sha256.convert(await f.readAsBytes()).toString(),
        };
        final index = await CbhIndexReader.open(source.path);
        final out = await Directory.systemTemp.createTemp(
          'cbh-tab-full-$label-',
        );
        addTearDown(() => out.delete(recursive: true));
        final service = CbhConversionService(destination: out);
        expect(service.executable, isNull);
        final result = await service.convert(
          source.path,
          onProgress: (message) {
            if (message.contains('500 of') || message.contains('000 of')) {
              // ignore: avoid_print
              print('$label: $message');
            }
          },
        );
        expect(result, isNotNull);
        final games = splitPgnGames(await File(result!).readAsString());
        expect(games.length, index.records.length);
        final raw = {
          for (final ext in ['.cbp', '.cbt', '.cbc', '.cbs'])
            ext: await index.file(ext).readAsBytes(),
        };
        List<int> record(String ext, int id, int width) {
          final bytes = raw[ext]!;
          final at = 28 + bytes[24] + id * width;
          return bytes.sublist(at, at + width);
        }

        final reference = Directory(p.join(out.path, 'control-free-reference'));
        await reference.create();
        for (final f in family) {
          await f.copy(p.join(reference.path, p.basename(f.path)));
        }
        final referenceBytes = {
          for (final e in raw.entries) e.key: e.value.toList(),
        };
        var replaced = 0;
        for (final r in index.records) {
          for (final field in <(String, int, int, int, int)>[
            ('.cbp', r.whitePlayer, 67, 9, 30),
            ('.cbp', r.whitePlayer, 67, 39, 20),
            ('.cbp', r.blackPlayer, 67, 9, 30),
            ('.cbp', r.blackPlayer, 67, 39, 20),
            ('.cbt', r.tournament, 99, 9, 40),
            ('.cbt', r.tournament, 99, 49, 30),
            ('.cbc', r.annotator, 62, 9, 45),
            ('.cbs', r.source, 68, 9, 25),
            ('.cbs', r.source, 68, 34, 16),
          ]) {
            final bytes = referenceBytes[field.$1]!;
            final at = 28 + bytes[24] + field.$2 * field.$3 + field.$4;
            for (var j = 0; j < field.$5 && bytes[at + j] != 0; j++) {
              if (bytes[at + j] == 9) {
                bytes[at + j] = 32;
                replaced++;
              }
            }
          }
        }
        expect(
          replaced,
          1,
          reason:
              'Only the verified metadata TAB is changed, in a disposable reference copy only',
        );
        for (final e in referenceBytes.entries) {
          await File(
            p.join(
              reference.path,
              p.basenameWithoutExtension(source.path) + e.key,
            ),
          ).writeAsBytes(e.value);
        }
        final referenceService = CbhConversionService(
          destination: Directory(p.join(out.path, 'reference-pgn')),
        );
        final referenceResult = await referenceService.convert(
          p.join(reference.path, p.basename(source.path)),
        );
        final referenceGames = splitPgnGames(
          await File(referenceResult!).readAsString(),
        );
        expect(referenceGames.length, games.length);
        expect(
          referenceService.preservationSummary,
          isNot(contains('metadata tabs')),
        );
        expect(
          service.preservationSummary,
          contains('1 record contains metadata tabs displayed as spaces'),
        );
        final frames = CbhFrameReader(index);
        for (var i = 0; i < games.length; i++) {
          final r = index.records[i];
          final parsed = PgnGame.parsePgn(games[i]);
          expect(
            base64Decode(parsed.headers['ChessBaseIndex']!),
            orderedEquals(r.raw),
            reason: '$label record ${i + 1}',
          );
          for (final field in [
            ('ChessBaseWhiteRecord', record('.cbp', r.whitePlayer, 67)),
            ('ChessBaseBlackRecord', record('.cbp', r.blackPlayer, 67)),
            ('ChessBaseEventRecord', record('.cbt', r.tournament, 99)),
            ('ChessBaseAnnotatorRecord', record('.cbc', r.annotator, 62)),
            ('ChessBaseSourceRecord', record('.cbs', r.source, 68)),
          ]) {
            expect(
              base64Decode(parsed.headers[field.$1]!),
              orderedEquals(field.$2),
              reason: '$label record ${i + 1} ${field.$1}',
            );
          }
          expect(parsed.headers.values.any((v) => v.contains('\t')), isFalse);
          final annotation = await frames.annotations(r);
          if (annotation.raw.isEmpty) {
            expect(parsed.headers['ChessBaseAnnotationFrame'], isNull);
          } else {
            expect(
              base64Decode(parsed.headers['ChessBaseAnnotationFrame']!),
              orderedEquals(annotation.raw),
              reason: '$label original annotation frame ${i + 1}',
            );
          }
          // The reference has no TAB branch at all. Everything other than the
          // deliberately different raw metadata archive must match byte-for-byte:
          // complete movetext, variations, NAGs, comments and annotation frames.
          expect(
            _withoutMetadataArchive(games[i]),
            _withoutMetadataArchive(referenceGames[i]),
            reason: '$label unchanged playable/annotation output ${i + 1}',
          );
        }
        final after = {
          for (final f in family)
            f.path: sha256.convert(await f.readAsBytes()).toString(),
        };
        expect(after, before);
        // ignore: avoid_print
        print(
          'WHOLE_CBH_TAB_ACCEPTANCE $label games=${games.length} rawMetadata=exact annotationFrames=exact controlFreeReference=identical sourceUnchanged=true',
        );
      },
      skip:
          manifest == null
              ? 'Set CHESSEVER_CBH_TAB_FIXTURES for private complete databases'
              : false,
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}

String _withoutMetadataArchive(String game) => game.replaceAll(
  RegExp(
    r'^\[ChessBase(?:White|Black|Event|Annotator|Source)Record "[^"\r\n]*"\]\r?\n',
    multiLine: true,
  ),
  '',
);
