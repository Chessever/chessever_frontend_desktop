import 'dart:io';
import 'dart:typed_data';

import 'cbh_index_reader.dart';

/// Bounded binary frame reader. It performs no move or annotation rendering.
final class CbhFrameReader {
  CbhFrameReader(this.files);

  final CbhFileSet files;
  static const _maximumFrameBytes = 16 * 1024 * 1024;

  Future<CbhGameFrame> game(CbhIndexRecord record) async {
    final file = files.file('.cbg');
    final header = await _read(file, record.gameOffset, 4);
    final size = (header[1] << 16) | (header[2] << 8) | header[3];
    if (size < 4 || size > _maximumFrameBytes) {
      throw CbhFormatException(
        'Record ${record.ordinal + 1}: invalid game frame length.',
      );
    }
    final raw = await _read(file, record.gameOffset, size);
    final flags = raw[0];
    if ((flags & ~0x4a) != 0) {
      throw CbhFormatException(
        'Record ${record.ordinal + 1}: unsupported game encoding.',
      );
    }
    final chess960 = (flags & 0x0a) != 0;
    final hasStartPosition = (flags & 0x40) != 0;
    final startPositionBytes = hasStartPosition ? (chess960 ? 36 : 28) : 0;
    if (raw.length < 4 + startPositionBytes) {
      throw CbhFormatException(
        'Record ${record.ordinal + 1}: truncated starting position.',
      );
    }
    return CbhGameFrame(
      raw: raw,
      chess960: chess960,
      startingPosition:
          hasStartPosition
              ? Uint8List.sublistView(raw, 4, 4 + startPositionBytes)
              : null,
      moveBytes: Uint8List.sublistView(raw, 4 + startPositionBytes),
    );
  }

  Future<CbhAnnotationFrame> annotations(CbhIndexRecord record) async {
    if (record.annotationOffset == 0) {
      return CbhAnnotationFrame(Uint8List(0), const []);
    }
    final file = files.file('.cba');
    final header = await _read(file, record.annotationOffset, 14);
    final size =
        (header[10] << 24) |
        (header[11] << 16) |
        (header[12] << 8) |
        header[13];
    if (size < 14 || size > _maximumFrameBytes) {
      throw CbhFormatException(
        'Record ${record.ordinal + 1}: invalid annotation frame length.',
      );
    }
    final raw = await _read(file, record.annotationOffset, size);
    final entries = <CbhAnnotationEntry>[];
    var offset = 14;
    while (offset < raw.length) {
      if (raw.length - offset < 6) {
        throw CbhFormatException(
          'Record ${record.ordinal + 1}: truncated annotation entry.',
        );
      }
      final length = (raw[offset + 4] << 8) | raw[offset + 5];
      if (length < 6 || length > raw.length - offset) {
        throw CbhFormatException(
          'Record ${record.ordinal + 1}: invalid annotation entry length.',
        );
      }
      entries.add(
        CbhAnnotationEntry(
          moveAddress:
              (raw[offset] << 16) | (raw[offset + 1] << 8) | raw[offset + 2],
          type: raw[offset + 3],
          payload: Uint8List.sublistView(raw, offset + 6, offset + length),
        ),
      );
      offset += length;
    }
    return CbhAnnotationFrame(raw, List.unmodifiable(entries));
  }

  static Future<Uint8List> _read(File file, int offset, int length) async {
    if (offset < 0 || length < 0 || length > _maximumFrameBytes) {
      throw const CbhFormatException('Invalid CBH frame bounds.');
    }
    final handle = await file.open();
    try {
      if (offset + length > await handle.length()) {
        throw const CbhFormatException('Truncated CBH frame.');
      }
      await handle.setPosition(offset);
      final bytes = await handle.read(length);
      if (bytes.length != length) {
        throw const CbhFormatException('Truncated CBH frame.');
      }
      return bytes;
    } finally {
      await handle.close();
    }
  }
}

final class CbhGameFrame {
  const CbhGameFrame({
    required this.raw,
    required this.chess960,
    required this.startingPosition,
    required this.moveBytes,
  });

  final Uint8List raw;
  final bool chess960;
  final Uint8List? startingPosition;
  final Uint8List moveBytes;
}

final class CbhAnnotationFrame {
  const CbhAnnotationFrame(this.raw, this.entries);
  final Uint8List raw;
  final List<CbhAnnotationEntry> entries;
}

final class CbhAnnotationEntry {
  const CbhAnnotationEntry({
    required this.moveAddress,
    required this.type,
    required this.payload,
  });

  final int moveAddress;
  final int type;
  final Uint8List payload;
}
