import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Validated classic CBH file set. This is the input layer for the Dart
/// decoder; it does not produce games or make a database available to import.
final class CbhFileSet {
  CbhFileSet._(this.files, this.records);

  final Map<String, File> files;
  final List<CbhIndexRecord> records;

  File file(String extension) => files[extension]!;
}

final class CbhIndexRecord {
  const CbhIndexRecord({
    required this.ordinal,
    required this.raw,
    required this.guidingText,
    required this.gameOffset,
    required this.annotationOffset,
    required this.whitePlayer,
    required this.blackPlayer,
    required this.tournament,
    required this.annotator,
    required this.source,
    required this.packedDate,
    required this.resultCode,
  });

  final int ordinal;
  final Uint8List raw;
  final bool guidingText;
  final int gameOffset;
  final int annotationOffset;
  final int whitePlayer;
  final int blackPlayer;
  final int tournament;
  final int annotator;
  final int source;
  final int packedDate;
  final int resultCode;

  int get year => (packedDate >> 9) & 0xfff;
  int get month => (packedDate >> 5) & 0xf;
  int get day => packedDate & 0x1f;
}

final class CbhFormatException implements Exception {
  const CbhFormatException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Reads only the bounded index and validates every referenced companion
/// record before any game or annotation bytes are interpreted.
final class CbhIndexReader {
  static const extensions = <String>[
    '.cbh',
    '.cbp',
    '.cbt',
    '.cbc',
    '.cbs',
    '.cbg',
    '.cba',
  ];
  static const _headerSize = 46;
  static const _recordSize = 46;
  static const _maximumRecords = 100000;
  static const _maximumSourceBytes = 512 * 1024 * 1024;

  static Future<CbhFileSet> open(String sourcePath) async {
    if (p.extension(sourcePath).toLowerCase() != '.cbh') {
      throw const CbhFormatException('Select a classic .cbh index file.');
    }
    final source = File(sourcePath).absolute;
    final directory = source.parent;
    final stem = p.basenameWithoutExtension(source.path).toLowerCase();
    final entries = <String, File>{};
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File) entries[p.basename(entry.path).toLowerCase()] = entry;
    }
    final files = <String, File>{};
    var totalBytes = 0;
    for (final extension in extensions) {
      final file = entries['$stem$extension'];
      if (file == null) {
        throw CbhFormatException(
          'Missing $extension companion file. Keep all seven classic CBH files together.',
        );
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw CbhFormatException('Linked CBH companion files are unsupported.');
      }
      totalBytes += await file.length();
      if (totalBytes > _maximumSourceBytes) {
        throw const CbhFormatException(
          'This decoder supports databases up to 512 MiB.',
        );
      }
      files[extension] = file;
    }

    final index = await files['.cbh']!.readAsBytes();
    if (index.length < _headerSize ||
        (index.length - _headerSize) % _recordSize != 0) {
      throw const CbhFormatException('Truncated CBH index.');
    }
    final count = (index.length - _headerSize) ~/ _recordSize;
    if (count > _maximumRecords) {
      throw const CbhFormatException('CBH index exceeds 100,000 records.');
    }
    if (!((index[0] == 0 && index[1] == 0 && index[2] == 0x2c) ||
            (index[0] == 0 && index[1] == 0 && index[2] == 0x24)) ||
        !(index[3] == 0 &&
            index[4] == 0x2e &&
            (index[5] == 1 || index[5] == 5))) {
      throw const CbhFormatException('Unsupported classic CBH signature.');
    }
    if (_unsigned(index, 6, 4) != count + 1) {
      throw const CbhFormatException(
        'CBH record count does not match its index.',
      );
    }

    final metadataLengths = <String, int>{};
    for (final entry in <(String, int)>[
      ('.cbp', 67),
      ('.cbt', 99),
      ('.cbc', 62),
      ('.cbs', 68),
    ]) {
      final file = files[entry.$1]!;
      final header = await file
          .openRead(0, 28)
          .fold<List<int>>(<int>[], (bytes, part) => bytes..addAll(part));
      if (header.length != 28) {
        throw CbhFormatException('Truncated ${entry.$1} metadata header.');
      }
      final length = await file.length();
      if (length < 28 + header[24]) {
        throw CbhFormatException('Invalid ${entry.$1} metadata header.');
      }
      if ((length - 28 - header[24]) % entry.$2 != 0) {
        throw CbhFormatException('Truncated ${entry.$1} metadata record.');
      }
      metadataLengths[entry.$1] = (length - 28 - header[24]) ~/ entry.$2;
    }
    final gameLength = await files['.cbg']!.length();
    final annotationLength = await files['.cba']!.length();
    final records = <CbhIndexRecord>[];
    for (var ordinal = 0; ordinal < count; ordinal++) {
      final start = _headerSize + ordinal * _recordSize;
      final raw = Uint8List.sublistView(index, start, start + _recordSize);
      final guiding = raw[0] & 2 != 0;
      final gameOffset = _unsigned(raw, 1, 4);
      if (gameOffset < 26 || gameOffset > gameLength - 4) {
        throw CbhFormatException('Record ${ordinal + 1}: invalid game offset.');
      }
      final annotationOffset = guiding ? 0 : _unsigned(raw, 5, 4);
      if (!guiding &&
          annotationOffset != 0 &&
          (annotationOffset < 26 || annotationOffset > annotationLength - 14)) {
        throw CbhFormatException(
          'Record ${ordinal + 1}: invalid annotation offset.',
        );
      }
      final whitePlayer = guiding ? 0 : _unsigned(raw, 9, 3);
      final blackPlayer = guiding ? 0 : _unsigned(raw, 12, 3);
      final tournament = guiding ? 0 : _unsigned(raw, 15, 3);
      final annotator = guiding ? 0 : _unsigned(raw, 18, 3);
      final sourceIndex = guiding ? 0 : _unsigned(raw, 21, 3);
      if (!guiding) {
        for (final reference in <(String, int)>[
          ('.cbp', whitePlayer),
          ('.cbp', blackPlayer),
          ('.cbt', tournament),
          ('.cbc', annotator),
          ('.cbs', sourceIndex),
        ]) {
          if (reference.$2 >= metadataLengths[reference.$1]!) {
            throw CbhFormatException(
              'Record ${ordinal + 1}: invalid ${reference.$1} metadata reference.',
            );
          }
        }
      } else if (raw[5] != 0 || raw[6] != 0) {
        throw CbhFormatException(
          'Record ${ordinal + 1}: unsupported guiding text index.',
        );
      }
      final packedDate = guiding ? 0 : _unsigned(raw, 24, 3);
      final month = (packedDate >> 5) & 0xf;
      final resultCode = guiding ? 0 : raw[27];
      if (!guiding && (month > 12 || resultCode > 7)) {
        throw CbhFormatException(
          'Record ${ordinal + 1}: invalid date or result.',
        );
      }
      records.add(
        CbhIndexRecord(
          ordinal: ordinal,
          raw: raw,
          guidingText: guiding,
          gameOffset: gameOffset,
          annotationOffset: annotationOffset,
          whitePlayer: whitePlayer,
          blackPlayer: blackPlayer,
          tournament: tournament,
          annotator: annotator,
          source: sourceIndex,
          packedDate: packedDate,
          resultCode: resultCode,
        ),
      );
    }
    return CbhFileSet._(Map.unmodifiable(files), List.unmodifiable(records));
  }

  static int _unsigned(List<int> bytes, int offset, int length) {
    var value = 0;
    for (var i = 0; i < length; i++) {
      value = (value << 8) | bytes[offset + i];
    }
    return value;
  }
}
