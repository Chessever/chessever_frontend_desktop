import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

import 'cbh_frame_reader.dart';
import 'cbh_index_reader.dart';
import 'cbh_metadata_reader.dart';
import 'cbh_move_decoder.dart';

/// Converts the currently verified subset of classic CBH directly in Dart.
/// No output is published when any record uses an unsupported construct.
final class CbhDartConversion {
  CbhDartConversion({
    required this.destination,
    this.isCancelled,
    this.onProgress,
  });

  final Directory destination;
  final bool Function()? isCancelled;
  final void Function(int done, int total)? onProgress;

  Future<File> convert(String sourcePath) async {
    _checkCancellation();
    final files = await CbhIndexReader.open(sourcePath);
    if (files.records.isEmpty) {
      throw const CbhFormatException('The CBH database has no records.');
    }
    final originalHashes = await _hashes(files);
    final frames = CbhFrameReader(files);
    final metadata = CbhMetadataReader(files);
    final gameText = StringBuffer();
    for (final record in files.records) {
      _checkCancellation();
      if (record.guidingText) {
        throw CbhFormatException(
          'Record ${record.ordinal + 1}: guiding text is not decoded yet.',
        );
      }
      if (record.annotationOffset != 0) {
        throw CbhFormatException(
          'Record ${record.ordinal + 1}: annotations are not decoded yet.',
        );
      }
      final frame = await frames.game(record);
      final info = await metadata.read(record);
      final san = CbhMoveDecoder().decode(frame);
      final pgn = _pgn(record, info, san);
      try {
        final parsed = ChessGame.fromPgn('cbh-${record.ordinal}', pgn);
        if (parsed.mainline.length != san.length) {
          throw const FormatException('PGN move count changed.');
        }
      } on Object {
        throw CbhFormatException(
          'Record ${record.ordinal + 1}: converted PGN did not parse.',
        );
      }
      gameText.write(pgn);
      gameText.write('\n\n');
      onProgress?.call(record.ordinal + 1, files.records.length);
    }
    _checkCancellation();
    final finalHashes = await _hashes(files);
    for (final extension in CbhIndexReader.extensions) {
      if (originalHashes[extension] != finalHashes[extension]) {
        throw const CbhFormatException(
          'CBH source changed during conversion. Close its writer and try again.',
        );
      }
    }
    _checkCancellation();
    await destination.create(recursive: true);
    final stem = p.basenameWithoutExtension(sourcePath);
    final unique = DateTime.now().microsecondsSinceEpoch;
    final published = File(p.join(destination.path, '$stem-$unique.pgn'));
    final temporary = File(p.join(destination.path, '.$stem-$unique.partial'));
    try {
      await temporary.writeAsString(gameText.toString(), flush: true);
      _checkCancellation();
      if (await published.exists()) {
        throw const CbhFormatException(
          'Converted PGN destination already exists.',
        );
      }
      return await temporary.rename(published.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  void _checkCancellation() {
    if (isCancelled?.call() == true) {
      throw const CbhFormatException('CBH conversion cancelled.');
    }
  }

  static Future<Map<String, Digest>> _hashes(CbhFileSet files) async {
    final result = <String, Digest>{};
    for (final extension in CbhIndexReader.extensions) {
      result[extension] =
          await sha256.bind(files.file(extension).openRead()).first;
    }
    return result;
  }

  static String _pgn(
    CbhIndexRecord record,
    CbhGameMetadata metadata,
    List<String> san,
  ) {
    final result = switch (record.resultCode) {
      0 || 4 => '0-1',
      1 || 5 => '1/2-1/2',
      2 || 6 => '1-0',
      _ => '*',
    };
    final headers = <String, String>{
      'Event': metadata.event.isEmpty ? '?' : metadata.event,
      'Site': metadata.site.isEmpty ? '?' : metadata.site,
      'Date': _date(record.year, record.month, record.day),
      'Round':
          record.raw[29] == 0
              ? '?'
              : record.raw[30] == 0
              ? '${record.raw[29]}'
              : '${record.raw[29]}.${record.raw[30]}',
      'White': metadata.white.isEmpty ? '?' : metadata.white,
      'Black': metadata.black.isEmpty ? '?' : metadata.black,
      'Result': result,
      'ChessBaseIndex': base64Encode(record.raw),
      'ChessBaseWhiteRecord': base64Encode(metadata.whiteRecord),
      'ChessBaseBlackRecord': base64Encode(metadata.blackRecord),
      'ChessBaseEventRecord': base64Encode(metadata.eventRecord),
      'ChessBaseAnnotatorRecord': base64Encode(metadata.annotatorRecord),
      'ChessBaseSourceRecord': base64Encode(metadata.sourceRecord),
      if (metadata.eventDate.year != 0 ||
          metadata.eventDate.month != 0 ||
          metadata.eventDate.day != 0)
        'EventDate': _date(
          metadata.eventDate.year,
          metadata.eventDate.month,
          metadata.eventDate.day,
        ),
      if (metadata.annotator.isNotEmpty) 'Annotator': metadata.annotator,
      if (metadata.sourceTitle.isNotEmpty) 'SourceTitle': metadata.sourceTitle,
      if (metadata.sourcePublisher.isNotEmpty)
        'Source': metadata.sourcePublisher,
      if (metadata.sourceDate.year != 0 ||
          metadata.sourceDate.month != 0 ||
          metadata.sourceDate.day != 0)
        'SourceDate': _date(
          metadata.sourceDate.year,
          metadata.sourceDate.month,
          metadata.sourceDate.day,
        ),
      if (metadata.sourceVersionDate.year != 0 ||
          metadata.sourceVersionDate.month != 0 ||
          metadata.sourceVersionDate.day != 0)
        'SourceVersionDate': _date(
          metadata.sourceVersionDate.year,
          metadata.sourceVersionDate.month,
          metadata.sourceVersionDate.day,
        ),
      if (metadata.sourceVersion != 0)
        'SourceVersion': '${metadata.sourceVersion}',
      if (metadata.sourceQuality != 0)
        'SourceQuality': '${metadata.sourceQuality}',
      if (record.resultCode >= 4) 'ChessBaseResultCode': '${record.resultCode}',
      if (record.resultCode >= 4)
        'ChessBaseResult':
            const ['-:+', '=:=', '+:-', '0-0'][record.resultCode - 4],
      if (record.resultCode >= 4 && record.resultCode <= 6)
        'Termination': 'forfeit',
    };
    final text = StringBuffer();
    for (final entry in headers.entries) {
      text.writeln('[${entry.key} "${_escape(entry.value)}"]');
    }
    text.writeln();
    for (var i = 0; i < san.length; i++) {
      if (i.isEven) text.write('${i ~/ 2 + 1}. ');
      text.write(san[i]);
      text.write(' ');
    }
    text.write(result);
    return text.toString();
  }

  static String _date(int year, int month, int day) =>
      '${year == 0 ? '????' : year.toString().padLeft(4, '0')}.'
      '${month == 0 ? '??' : month.toString().padLeft(2, '0')}.'
      '${day == 0 ? '??' : day.toString().padLeft(2, '0')}';

  static String _escape(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
}
