import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:chessever/desktop/services/local_opening_tree_builder.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';

const String compactLocalTreeIndexFormat = 'ceti';
const int compactLocalTreeIndexVersion = 1;

const int _headerSize = 64;
const int _recordSize = 28;
const int _bucketCount = 64;
const int _bucketBufferSize = 64 * 1024;
const int _outputBufferSize = 1024 * 1024;
const int _noMove = 0xffff;
const int _unixEpochJulianDay = 2440588;

String compactLocalTreeIndexPath(String databasePath) => '$databasePath.ceti';

String compactLocalTreeGameIndexPath(String databasePath) =>
    '$databasePath.cetg';

String compactLocalTreeSnapshot(CompactLocalTreeIndexMetadata metadata) {
  return jsonEncode(<String, Object>{
    'format': compactLocalTreeIndexFormat,
    'version': metadata.version,
    'occurrences': metadata.occurrenceCount,
  });
}

bool isCompactLocalTreeSnapshot(Object? value) {
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty) return false;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map &&
        decoded['format'] == compactLocalTreeIndexFormat &&
        decoded['version'] == compactLocalTreeIndexVersion;
  } on FormatException {
    return false;
  }
}

class CompactLocalTreeIndexMetadata {
  const CompactLocalTreeIndexMetadata({
    required this.version,
    required this.gameCount,
    required this.positionCount,
    required this.occurrenceCount,
    required this.maxPly,
    required this.generatedAtMs,
  });

  final int version;
  final int gameCount;
  final int positionCount;
  final int occurrenceCount;
  final int maxPly;
  final int generatedAtMs;

  static CompactLocalTreeIndexMetadata? readSync(String path) {
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() < _headerSize) return null;
    final reader = file.openSync();
    try {
      final bytes = reader.readSync(_headerSize);
      if (bytes.length != _headerSize ||
          ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'CETI') {
        return null;
      }
      final data = ByteData.sublistView(bytes);
      final version = data.getUint32(4, Endian.little);
      final headerSize = data.getUint32(8, Endian.little);
      final recordSize = data.getUint32(12, Endian.little);
      if (version != compactLocalTreeIndexVersion ||
          headerSize != _headerSize ||
          recordSize != _recordSize) {
        return null;
      }
      final occurrenceCount = data.getUint64(24, Endian.little);
      final expectedLength = _headerSize + occurrenceCount * _recordSize;
      if (file.lengthSync() != expectedLength) return null;
      return CompactLocalTreeIndexMetadata(
        version: version,
        gameCount: data.getUint32(16, Endian.little),
        positionCount: data.getUint32(20, Endian.little),
        occurrenceCount: occurrenceCount,
        maxPly: data.getUint32(32, Endian.little),
        generatedAtMs: data.getInt64(40, Endian.little),
      );
    } finally {
      reader.closeSync();
    }
  }
}

class CompactLocalTreePositionMatch {
  const CompactLocalTreePositionMatch({
    required this.indexInFile,
    required this.ply,
    required this.result,
    required this.dateDays,
    this.nextUci,
  });

  final int indexInFile;
  final int ply;
  final int result;
  final int dateDays;
  final String? nextUci;

  DateTime? get date {
    if (dateDays <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (dateDays - _unixEpochJulianDay) * Duration.millisecondsPerDay,
      isUtc: true,
    );
  }
}

class CompactLocalTreeBuildResult {
  const CompactLocalTreeBuildResult({
    required this.metadata,
    required this.skippedGames,
  });

  final CompactLocalTreeIndexMetadata metadata;
  final int skippedGames;
}

class CompactLocalTreeIndexBuilder {
  CompactLocalTreeIndexBuilder({
    required this.targetPath,
    required this.maxPly,
  }) : _workingDirectory = Directory(
         '$targetPath.build-${DateTime.now().microsecondsSinceEpoch}',
       ) {
    _removeStaleBuildDirectories(targetPath);
    _workingDirectory.createSync(recursive: true);
    _bucketFiles = List<RandomAccessFile>.generate(_bucketCount, (index) {
      return File(
        '${_workingDirectory.path}${Platform.pathSeparator}bucket-$index.bin',
      ).openSync(mode: FileMode.writeOnly);
    });
    _bucketBuffers = List<BytesBuilder>.generate(
      _bucketCount,
      (_) => BytesBuilder(copy: false),
    );
  }

  final String targetPath;
  final int maxPly;
  final Directory _workingDirectory;
  late final List<RandomAccessFile> _bucketFiles;
  late final List<BytesBuilder> _bucketBuffers;
  final Map<String, String?> _transitionCache = <String, String?>{};

  int _indexedGames = 0;
  int _skippedGames = 0;
  int _occurrenceCount = 0;
  bool _closed = false;

  List<String>? addGame(LocalOpeningTreeGameInput input) {
    if (_closed) throw StateError('Compact tree builder is already closed.');
    try {
      final events = localOpeningTreePositionEventsForGame(
        input,
        maxPly: maxPly,
        transitionCache: _transitionCache,
      );
      final result = _resultCode(input.metadata['Result']);
      final dateDays = _dateDays(input.metadata);
      final seen = <String>{};
      for (final event in events) {
        if (!seen.add(event.fenKey)) continue;
        final hash = _positionHash(event.fenKey);
        final bucket = hash[0] >> 2;
        final record = ByteData(_recordSize);
        record.buffer.asUint8List().setRange(0, 16, hash);
        record.setUint32(16, input.indexInFile, Endian.little);
        record.setUint16(20, _encodeUci(event.nextUci), Endian.little);
        record.setUint8(22, event.ply.clamp(0, 255));
        record.setUint8(23, result);
        record.setUint32(24, dateDays, Endian.little);
        _bucketBuffers[bucket].add(record.buffer.asUint8List());
        _occurrenceCount++;
        if (_bucketBuffers[bucket].length >= _bucketBufferSize) {
          _flushBucket(bucket);
        }
      }
      _indexedGames++;
      return <String>[
        for (final event in events)
          if (event.nextUci != null) event.nextUci!,
      ];
    } on LocalOpeningTreeGameException {
      _skippedGames++;
    } on FormatException {
      _skippedGames++;
    } on ArgumentError {
      _skippedGames++;
    }
    return null;
  }

  CompactLocalTreeBuildResult finish() {
    if (_closed) throw StateError('Compact tree builder is already closed.');
    _closed = true;
    for (var bucket = 0; bucket < _bucketCount; bucket++) {
      _flushBucket(bucket);
      _bucketFiles[bucket].closeSync();
    }

    final generatedAtMs = DateTime.now().millisecondsSinceEpoch;
    final temporaryOutput = File('${_workingDirectory.path}.ceti.tmp');
    final output = temporaryOutput.openSync(mode: FileMode.writeOnly);
    final outputBuffer = BytesBuilder(copy: false);
    var positionCount = 0;
    Uint8List? previousHash;
    try {
      output.writeFromSync(Uint8List(_headerSize));
      for (var bucket = 0; bucket < _bucketCount; bucket++) {
        final bucketFile = File(
          '${_workingDirectory.path}${Platform.pathSeparator}bucket-$bucket.bin',
        );
        if (!bucketFile.existsSync() || bucketFile.lengthSync() == 0) continue;
        final bytes = bucketFile.readAsBytesSync();
        final records = <Uint8List>[];
        for (var offset = 0; offset < bytes.length; offset += _recordSize) {
          records.add(
            Uint8List.sublistView(bytes, offset, offset + _recordSize),
          );
        }
        records.sort(_compareRecords);
        for (final record in records) {
          if (previousHash == null ||
              _compareRecordHash(previousHash, record) != 0) {
            positionCount++;
            previousHash = Uint8List.fromList(record.sublist(0, 16));
          }
          outputBuffer.add(record);
          if (outputBuffer.length >= _outputBufferSize) {
            output.writeFromSync(outputBuffer.takeBytes());
          }
        }
      }
      if (outputBuffer.isNotEmpty) {
        output.writeFromSync(outputBuffer.takeBytes());
      }
      final header = ByteData(_headerSize);
      header.buffer.asUint8List().setRange(0, 4, ascii.encode('CETI'));
      header.setUint32(4, compactLocalTreeIndexVersion, Endian.little);
      header.setUint32(8, _headerSize, Endian.little);
      header.setUint32(12, _recordSize, Endian.little);
      header.setUint32(16, _indexedGames, Endian.little);
      header.setUint32(20, positionCount, Endian.little);
      header.setUint64(24, _occurrenceCount, Endian.little);
      header.setUint32(32, maxPly, Endian.little);
      header.setInt64(40, generatedAtMs, Endian.little);
      output.setPositionSync(0);
      output.writeFromSync(header.buffer.asUint8List());
      output.flushSync();
    } finally {
      output.closeSync();
    }

    final target = File(targetPath);
    final backup = File('$targetPath.previous');
    try {
      if (backup.existsSync()) backup.deleteSync();
      if (target.existsSync()) target.renameSync(backup.path);
      temporaryOutput.renameSync(target.path);
      if (backup.existsSync()) backup.deleteSync();
    } catch (_) {
      if (!target.existsSync() && backup.existsSync()) {
        backup.renameSync(target.path);
      }
      rethrow;
    } finally {
      if (temporaryOutput.existsSync()) temporaryOutput.deleteSync();
      if (_workingDirectory.existsSync()) {
        _workingDirectory.deleteSync(recursive: true);
      }
    }

    return CompactLocalTreeBuildResult(
      metadata: CompactLocalTreeIndexMetadata(
        version: compactLocalTreeIndexVersion,
        gameCount: _indexedGames,
        positionCount: positionCount,
        occurrenceCount: _occurrenceCount,
        maxPly: maxPly,
        generatedAtMs: generatedAtMs,
      ),
      skippedGames: _skippedGames,
    );
  }

  void abort() {
    if (_closed) return;
    _closed = true;
    for (var bucket = 0; bucket < _bucketFiles.length; bucket++) {
      try {
        _bucketFiles[bucket].closeSync();
      } on FileSystemException {
        // Best effort cleanup after a failed build.
      }
    }
    if (_workingDirectory.existsSync()) {
      _workingDirectory.deleteSync(recursive: true);
    }
  }

  void _flushBucket(int bucket) {
    final buffer = _bucketBuffers[bucket];
    if (buffer.isEmpty) return;
    _bucketFiles[bucket].writeFromSync(buffer.takeBytes());
  }
}

List<CompactLocalTreePositionMatch> readCompactLocalTreePositionMatchesSync({
  required String indexPath,
  required String fen,
}) {
  final metadata = CompactLocalTreeIndexMetadata.readSync(indexPath);
  if (metadata == null || metadata.occurrenceCount <= 0) {
    return const <CompactLocalTreePositionMatch>[];
  }
  final target = _positionHash(playerOpeningTreeFenKey(fen));
  final file = File(indexPath).openSync();
  try {
    var low = 0;
    var high = metadata.occurrenceCount;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      final comparison = _compareHashAt(file, middle, target);
      if (comparison < 0) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final first = low;
    if (first >= metadata.occurrenceCount ||
        _compareHashAt(file, first, target) != 0) {
      return const <CompactLocalTreePositionMatch>[];
    }
    high = metadata.occurrenceCount;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      final comparison = _compareHashAt(file, middle, target);
      if (comparison <= 0) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final count = low - first;
    file.setPositionSync(_headerSize + first * _recordSize);
    final bytes = file.readSync(count * _recordSize);
    final matches = <CompactLocalTreePositionMatch>[];
    for (var offset = 0; offset < bytes.length; offset += _recordSize) {
      final record = ByteData.sublistView(bytes, offset, offset + _recordSize);
      matches.add(
        CompactLocalTreePositionMatch(
          indexInFile: record.getUint32(16, Endian.little),
          nextUci: _decodeUci(record.getUint16(20, Endian.little)),
          ply: record.getUint8(22),
          result: record.getUint8(23),
          dateDays: record.getUint32(24, Endian.little),
        ),
      );
    }
    return List<CompactLocalTreePositionMatch>.unmodifiable(matches);
  } finally {
    file.closeSync();
  }
}

void deleteCompactLocalTreeIndexBestEffort(String databasePath) {
  for (final path in <String>[
    compactLocalTreeIndexPath(databasePath),
    '${compactLocalTreeIndexPath(databasePath)}.previous',
    compactLocalTreeGameIndexPath(databasePath),
    '${compactLocalTreeGameIndexPath(databasePath)}.previous',
  ]) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Cache cleanup must not make source deletion fail.
    }
  }
}

Uint8List _positionHash(String fenKey) {
  return Uint8List.fromList(md5.convert(utf8.encode(fenKey)).bytes);
}

int _compareHashAt(RandomAccessFile file, int index, Uint8List target) {
  file.setPositionSync(_headerSize + index * _recordSize);
  final bytes = file.readSync(16);
  if (bytes.length != 16) throw const FormatException('Truncated CETI index.');
  return _compareBytes(bytes, target);
}

int _compareRecords(Uint8List left, Uint8List right) {
  for (var index = 0; index < 16; index++) {
    final comparison = left[index].compareTo(right[index]);
    if (comparison != 0) return comparison;
  }
  final leftData = ByteData.sublistView(left);
  final rightData = ByteData.sublistView(right);
  return leftData
      .getUint32(16, Endian.little)
      .compareTo(rightData.getUint32(16, Endian.little));
}

int _compareRecordHash(Uint8List hash, Uint8List record) {
  for (var index = 0; index < 16; index++) {
    final comparison = hash[index].compareTo(record[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

int _compareBytes(Uint8List left, Uint8List right) {
  for (var index = 0; index < left.length; index++) {
    final comparison = left[index].compareTo(right[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

int _encodeUci(String? rawUci) {
  final uci = rawUci?.trim().toLowerCase() ?? '';
  if (uci.length < 4) return _noMove;
  final from = _squareIndex(uci.substring(0, 2));
  final to = _squareIndex(uci.substring(2, 4));
  if (from < 0 || to < 0) return _noMove;
  final promotion =
      uci.length < 5
          ? 0
          : switch (uci[4]) {
            'n' => 1,
            'b' => 2,
            'r' => 3,
            'q' => 4,
            _ => 0,
          };
  return from | (to << 6) | (promotion << 12);
}

String? _decodeUci(int encoded) {
  if (encoded == _noMove) return null;
  final from = encoded & 0x3f;
  final to = (encoded >> 6) & 0x3f;
  final promotion = switch ((encoded >> 12) & 0x7) {
    1 => 'n',
    2 => 'b',
    3 => 'r',
    4 => 'q',
    _ => '',
  };
  return '${_squareName(from)}${_squareName(to)}$promotion';
}

int _squareIndex(String square) {
  if (square.length != 2) return -1;
  final file = square.codeUnitAt(0) - 97;
  final rank = square.codeUnitAt(1) - 49;
  if (file < 0 || file > 7 || rank < 0 || rank > 7) return -1;
  return rank * 8 + file;
}

String _squareName(int square) {
  return '${String.fromCharCode(97 + (square & 7))}${1 + (square >> 3)}';
}

int _resultCode(String? result) {
  return switch (result?.trim()) {
    '1-0' => 1,
    '0-1' => 2,
    _ => 3,
  };
}

int _dateDays(Map<String, String> metadata) {
  final raw = (metadata['UTCDate'] ?? metadata['Date'] ?? '').trim();
  if (raw.isEmpty || raw.contains('?')) return 0;
  final parts = raw.replaceAll('-', '.').split('.');
  if (parts.length < 3) return 0;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return 0;
  final date = DateTime.tryParse(
    '${year.toString().padLeft(4, '0')}-'
    '${month.toString().padLeft(2, '0')}-'
    '${day.toString().padLeft(2, '0')}T00:00:00Z',
  );
  if (date == null) return 0;
  return _unixEpochJulianDay +
      date.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
}

void _removeStaleBuildDirectories(String targetPath) {
  final target = File(targetPath);
  final parent = target.parent;
  if (!parent.existsSync()) return;
  final prefix = '${target.path}.build-';
  for (final entity in parent.listSync(followLinks: false)) {
    if (entity is! Directory || !entity.path.startsWith(prefix)) continue;
    try {
      entity.deleteSync(recursive: true);
    } on FileSystemException {
      // Another build may still own the directory.
    }
  }
}
