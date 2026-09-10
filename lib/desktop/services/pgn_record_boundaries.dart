import 'dart:io';
import 'dart:typed_data';

const _kUtf8Bom = <int>[0xEF, 0xBB, 0xBF];

class PgnByteLine {
  const PgnByteLine({
    required this.startOffset,
    required this.contentStartOffset,
    required this.endOffset,
    required this.isHeader,
    required this.isBlank,
    required this.hasMoveHint,
    required this.maxMoveNumber,
  });

  final int startOffset;
  final int contentStartOffset;
  final int endOffset;
  final bool isHeader;
  final bool isBlank;
  final bool hasMoveHint;
  final int maxMoveNumber;
}

class PgnByteLineScanner {
  PgnByteLineScanner(this.onLine);

  final void Function(PgnByteLine line) onLine;

  int finalOffset = 0;
  int _offset = 0;
  int _lineStartOffset = 0;
  int _lineByteCount = 0;
  bool _pendingCr = false;
  bool _isFirstLine = true;
  bool _lineStartedInComment = false;
  bool _inComment = false;
  bool _lineHasNonWhitespace = false;
  bool _lineHasMoveHint = false;
  int? _lineMoveNumberCandidate;
  int _lineMaxMoveNumber = 0;
  int _variationDepth = 0;
  bool _lineStartsWithUtf8Bom = false;
  int? _firstNonWhitespaceByte;

  Future<void> scan(
    String path, {
    int? totalBytes,
    void Function(double fraction)? onProgress,
    bool Function()? shouldStop,
  }) async {
    var lastProgressOffset = 0;
    void emitProgress({bool force = false}) {
      if (onProgress == null || totalBytes == null || totalBytes <= 0) return;
      if (!force && _offset - lastProgressOffset < 1024 * 1024) return;
      lastProgressOffset = _offset;
      onProgress((_offset / totalBytes).clamp(0.0, 1.0).toDouble());
    }

    emitProgress(force: true);
    scanLoop:
    await for (final chunk in File(path).openRead()) {
      for (final byte in chunk) {
        _readByte(byte);
        if (shouldStop?.call() ?? false) break scanLoop;
      }
      emitProgress();
    }
    if (!(shouldStop?.call() ?? false)) {
      if (_pendingCr) {
        _flushLine(_offset);
        _pendingCr = false;
      }
      if (_lineByteCount > 0 || _offset == _lineStartOffset) {
        _flushLine(_offset);
      }
    }
    finalOffset = _offset;
    emitProgress(force: true);
  }

  void scanBytes(
    Uint8List bytes, {
    int? totalBytes,
    void Function(double fraction)? onProgress,
  }) {
    var lastProgressOffset = 0;
    void emitProgress({bool force = false}) {
      if (onProgress == null || totalBytes == null || totalBytes <= 0) return;
      if (!force && _offset - lastProgressOffset < 1024 * 1024) return;
      lastProgressOffset = _offset;
      onProgress((_offset / totalBytes).clamp(0.0, 1.0).toDouble());
    }

    emitProgress(force: true);
    for (final byte in bytes) {
      _readByte(byte);
      if (_offset - lastProgressOffset >= 1024 * 1024) {
        emitProgress();
      }
    }
    if (_pendingCr) {
      _flushLine(_offset);
      _pendingCr = false;
    }
    if (_lineByteCount > 0 || _offset == _lineStartOffset) {
      _flushLine(_offset);
    }
    finalOffset = _offset;
    emitProgress(force: true);
  }

  void _readByte(int byte) {
    if (_pendingCr) {
      if (byte == 0x0A) {
        _offset++;
        _flushLine(_offset);
        _pendingCr = false;
        return;
      }
      _flushLine(_offset);
      _pendingCr = false;
    }

    _offset++;
    if (byte == 0x0D) {
      _pendingCr = true;
      return;
    }
    if (byte == 0x0A) {
      _flushLine(_offset);
      return;
    }
    _readContentByte(byte);
  }

  void _readContentByte(int byte) {
    if (_isFirstLine &&
        _lineByteCount < _kUtf8Bom.length &&
        byte == _kUtf8Bom[_lineByteCount]) {
      if (_lineByteCount == _kUtf8Bom.length - 1) {
        _lineStartsWithUtf8Bom = true;
      }
      _lineByteCount++;
      return;
    }

    _lineByteCount++;
    if (!_isWhitespaceByte(byte)) {
      _lineHasNonWhitespace = true;
      _firstNonWhitespaceByte ??= byte;
    }

    if (byte == 0x7B) {
      _inComment = true;
      _lineMoveNumberCandidate = null;
      return;
    } else if (byte == 0x7D) {
      _inComment = false;
      _lineMoveNumberCandidate = null;
      return;
    }
    if (_inComment) {
      _lineMoveNumberCandidate = null;
      return;
    }
    if (byte == 0x28) {
      _variationDepth++;
      _lineMoveNumberCandidate = null;
      return;
    }
    if (byte == 0x29) {
      if (_variationDepth > 0) _variationDepth--;
      _lineMoveNumberCandidate = null;
      return;
    }
    if (_variationDepth > 0) {
      _lineMoveNumberCandidate = null;
      return;
    }

    if (byte >= 0x30 && byte <= 0x39) {
      final digit = byte - 0x30;
      _lineMoveNumberCandidate = (_lineMoveNumberCandidate ?? 0) * 10 + digit;
    } else if (byte == 0x2E && _lineMoveNumberCandidate != null) {
      _lineHasMoveHint = true;
      if (_lineMoveNumberCandidate! > _lineMaxMoveNumber) {
        _lineMaxMoveNumber = _lineMoveNumberCandidate!;
      }
      _lineMoveNumberCandidate = null;
    } else {
      _lineMoveNumberCandidate = null;
    }
  }

  void _flushLine(int endOffset) {
    if (_lineByteCount == 0 && endOffset == _lineStartOffset) return;
    final startsWithBom = _isFirstLine && _startsWithUtf8Bom();
    onLine(
      PgnByteLine(
        startOffset: _lineStartOffset,
        contentStartOffset:
            startsWithBom
                ? _lineStartOffset + _kUtf8Bom.length
                : _lineStartOffset,
        endOffset: endOffset,
        isHeader: !_lineStartedInComment && _firstNonWhitespaceByte == 0x5B,
        isBlank: !_lineHasNonWhitespace,
        hasMoveHint: _lineHasMoveHint,
        maxMoveNumber: _lineMaxMoveNumber,
      ),
    );
    _lineStartOffset = endOffset;
    _lineByteCount = 0;
    _lineHasNonWhitespace = false;
    _lineHasMoveHint = false;
    _lineMoveNumberCandidate = null;
    _lineMaxMoveNumber = 0;
    _lineStartsWithUtf8Bom = false;
    _firstNonWhitespaceByte = null;
    _lineStartedInComment = _inComment;
    _isFirstLine = false;
  }

  bool _startsWithUtf8Bom() {
    return _lineStartOffset == 0 && _lineStartsWithUtf8Bom;
  }
}

bool _isWhitespaceByte(int byte) {
  return byte == 0x20 ||
      byte == 0x09 ||
      byte == 0x0A ||
      byte == 0x0D ||
      byte == 0x0B ||
      byte == 0x0C;
}

/// Boundary state shared by streaming import and exact-snapshot mutations.
class PgnRecordBoundaryTracker {
  bool hasCurrent = false;
  bool sawMovetext = false;
  bool hasHeader = false;
  bool hasMoveHint = false;
  bool startsNewRecord(PgnByteLine line) =>
      line.isHeader && sawMovetext && hasCurrent;
  bool get isRecord => hasCurrent && (hasHeader || hasMoveHint);
  void reset() {
    hasCurrent = false;
    sawMovetext = false;
    hasHeader = false;
    hasMoveHint = false;
  }

  bool add(PgnByteLine line) {
    if (!hasCurrent && line.isBlank) return false;
    hasCurrent = true;
    hasHeader |= line.isHeader;
    hasMoveHint |= line.hasMoveHint;
    if (!line.isBlank && !line.isHeader) sawMovetext = true;
    return true;
  }
}
