import 'dart:io';

import 'cbh_index_reader.dart';

/// Text and date fields from the four fixed-record classic CBH metadata files.
/// Unrecognized bytes fail conversion instead of silently changing names.
final class CbhMetadataReader {
  CbhMetadataReader(this.files);

  final CbhFileSet files;
  final _metadataWhitespaceRecords = <int>{};

  /// Game records with readable TAB-to-space normalization, counted once each.
  int get normalizedWhitespaceRecords => _metadataWhitespaceRecords.length;

  Future<CbhGameMetadata> read(CbhIndexRecord record) async {
    if (record.guidingText) {
      throw const CbhFormatException(
        'Guiding text has a separate record layout.',
      );
    }
    final recordNumber = record.ordinal + 1;
    final white = await _readFixed(files.file('.cbp'), record.whitePlayer, 67);
    final black = await _readFixed(files.file('.cbp'), record.blackPlayer, 67);
    final event = await _readFixed(files.file('.cbt'), record.tournament, 99);
    final annotator = await _readFixed(
      files.file('.cbc'),
      record.annotator,
      62,
    );
    final source = await _readFixed(files.file('.cbs'), record.source, 68);
    return CbhGameMetadata(
      whiteRecord: white,
      blackRecord: black,
      eventRecord: event,
      annotatorRecord: annotator,
      sourceRecord: source,
      white: _name(white, recordNumber, 'White'),
      black: _name(black, recordNumber, 'Black'),
      event: _text(event, 9, 40, recordNumber, 'Event name (.cbt)'),
      site: _text(event, 49, 30, recordNumber, 'Event site (.cbt)'),
      eventDate: _date(event, 79),
      annotator: _text(annotator, 9, 45, recordNumber, 'Annotator (.cbc)'),
      sourceTitle: _text(source, 9, 25, recordNumber, 'Source title (.cbs)'),
      sourcePublisher: _text(
        source,
        34,
        16,
        recordNumber,
        'Source publisher (.cbs)',
      ),
      sourceDate: _date(source, 50),
      sourceVersionDate: _date(source, 54),
      sourceVersion: source[58],
      sourceQuality: source[59],
    );
  }

  static Future<List<int>> _readFixed(File file, int index, int width) async {
    final handle = await file.open();
    try {
      final header = await handle.read(28);
      if (header.length != 28) {
        throw const CbhFormatException('Truncated metadata header.');
      }
      final offset = 28 + header[24] + index * width;
      if (offset + width > await handle.length()) {
        throw const CbhFormatException('Invalid metadata reference.');
      }
      await handle.setPosition(offset);
      final record = await handle.read(width);
      if (record.length != width) {
        throw const CbhFormatException('Truncated metadata record.');
      }
      return record;
    } finally {
      await handle.close();
    }
  }

  String _name(List<int> bytes, int recordNumber, String side) {
    final last = _text(bytes, 9, 30, recordNumber, '$side surname (.cbp)');
    final first = _text(bytes, 39, 20, recordNumber, '$side given name (.cbp)');
    if (first.isEmpty) return last;
    if (last.isEmpty) return first;
    return '$last, $first';
  }

  String _text(
    List<int> bytes,
    int start,
    int width,
    int recordNumber,
    String field,
  ) {
    final end = bytes.indexOf(0, start);
    final actualEnd = end >= start && end < start + width ? end : start + width;
    final value = StringBuffer();
    for (var i = start; i < actualEnd; i++) {
      final byte = bytes[i];
      if (byte == 0x09) {
        _metadataWhitespaceRecords.add(recordNumber);
        // PGN tag text uses a printable space. The unmodified source record
        // remains available in CbhGameMetadata and its raw PGN archive tag.
        value.write(' ');
        continue;
      }
      if (byte < 0x20) {
        throw CbhFormatException(
          'Record $recordNumber: Unsupported control byte '
          '0x${byte.toRadixString(16).padLeft(2, '0')} in $field.',
        );
      }
      if (byte < 0x80 || byte >= 0xa0) {
        value.writeCharCode(byte);
      } else {
        final mapped = _windows1252[byte - 0x80];
        if (mapped == 0) {
          throw CbhFormatException(
            'Record $recordNumber: Unsupported text byte '
            '0x${byte.toRadixString(16).padLeft(2, '0')} in $field.',
          );
        }
        value.writeCharCode(mapped);
      }
    }
    return value.toString();
  }

  static CbhPartialDate _date(List<int> bytes, int start) {
    final packed =
        bytes[start] | (bytes[start + 1] << 8) | (bytes[start + 2] << 16);
    final month = (packed >> 5) & 15;
    if (month > 12) throw const CbhFormatException('Invalid metadata date.');
    return CbhPartialDate((packed >> 9) & 4095, month, packed & 31);
  }

  static const _windows1252 = <int>[
    0x20ac,
    0,
    0x201a,
    0x0192,
    0x201e,
    0x2026,
    0x2020,
    0x2021,
    0x02c6,
    0x2030,
    0x0160,
    0x2039,
    0x0152,
    0,
    0x017d,
    0,
    0,
    0x2018,
    0x2019,
    0x201c,
    0x201d,
    0x2022,
    0x2013,
    0x2014,
    0x02dc,
    0x2122,
    0x0161,
    0x203a,
    0x0153,
    0,
    0x017e,
    0x0178,
  ];
}

final class CbhPartialDate {
  const CbhPartialDate(this.year, this.month, this.day);
  final int year;
  final int month;
  final int day;
}

final class CbhGameMetadata {
  const CbhGameMetadata({
    required this.whiteRecord,
    required this.blackRecord,
    required this.eventRecord,
    required this.annotatorRecord,
    required this.sourceRecord,
    required this.white,
    required this.black,
    required this.event,
    required this.site,
    required this.eventDate,
    required this.annotator,
    required this.sourceTitle,
    required this.sourcePublisher,
    required this.sourceDate,
    required this.sourceVersionDate,
    required this.sourceVersion,
    required this.sourceQuality,
  });

  final List<int> whiteRecord;
  final List<int> blackRecord;
  final List<int> eventRecord;
  final List<int> annotatorRecord;
  final List<int> sourceRecord;
  final String white;
  final String black;
  final String event;
  final String site;
  final CbhPartialDate eventDate;
  final String annotator;
  final String sourceTitle;
  final String sourcePublisher;
  final CbhPartialDate sourceDate;
  final CbhPartialDate sourceVersionDate;
  final int sourceVersion;
  final int sourceQuality;
}
