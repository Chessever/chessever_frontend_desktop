import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'cbh_index_reader.dart';

/// Reads unencrypted CBV archives into a private temporary directory.
///
/// The block layout and bit coding were documented by Antoni Boucher's
/// GPL-3.0 uncbv project (https://github.com/antoyo/uncbv). This independent
/// Dart implementation keeps strict input/output bounds and refuses archive
/// paths that could escape [destination].
final class CbvArchiveReader {
  static const _maximumArchiveBytes = 512 * 1024 * 1024;
  static const _maximumExpandedBytes = 512 * 1024 * 1024;

  static Future<String> extractDatabase(
    File archive,
    Directory destination,
  ) async {
    final length = await archive.length();
    if (length < 8 || length > _maximumArchiveBytes) {
      throw const CbhFormatException('Invalid or oversized CBV archive.');
    }
    final bytes = await archive.readAsBytes();
    if (bytes[0] != 8 || bytes[1] != 0) {
      throw const CbhFormatException('Unsupported CBV archive signature.');
    }
    final count = _le16(bytes, 2);
    final width = bytes[4];
    if (count == 0 ||
        count > 256 ||
        width < 140 ||
        8 + count * width > bytes.length) {
      throw const CbhFormatException('Invalid CBV file table.');
    }
    var cursor = 8 + count * width;
    var expanded = 0;
    final names = <String>{};
    String? indexPath;
    for (var i = 0; i < count; i++) {
      final entry = 8 + i * width;
      final endOfName = bytes.indexOf(0, entry);
      if (endOfName < 0 || endOfName >= entry + 132) {
        throw const CbhFormatException('Invalid CBV member name.');
      }
      final name = _filename(bytes.sublist(entry, endOfName));
      final relative = p.normalize(name.replaceAll('\\', '/'));
      if (relative.isEmpty ||
          relative == '.' ||
          p.isAbsolute(relative) ||
          relative == '..' ||
          relative.startsWith('../') ||
          relative
              .split('/')
              .any((part) => part == '.' || part == '..' || part.isEmpty) ||
          !names.add(relative.toLowerCase())) {
        throw const CbhFormatException('Unsafe or duplicate CBV member path.');
      }
      final compressedSize = _le32(bytes, entry + 132);
      final decompressedSize = _le32(bytes, entry + 136);
      if (compressedSize < 0 ||
          decompressedSize < 0 ||
          cursor + compressedSize > bytes.length ||
          expanded + decompressedSize > _maximumExpandedBytes) {
        throw const CbhFormatException('Invalid CBV member length.');
      }
      final memberEnd = cursor + compressedSize;
      final output = BytesBuilder(copy: false);
      while (cursor < memberEnd) {
        if (memberEnd - cursor < 5) {
          throw const CbhFormatException('Truncated CBV block.');
        }
        final blockSize = _le16(bytes, cursor);
        cursor += 4;
        if (blockSize < 1 || cursor + blockSize > memberEnd) {
          throw const CbhFormatException('Invalid CBV block length.');
        }
        final flag = bytes[cursor];
        if (flag > 3) {
          throw const CbhFormatException('Unknown CBV compression mode.');
        }
        final encoded = Uint8List.sublistView(
          bytes,
          cursor + 1,
          cursor + blockSize,
        );
        final decoded = flag & 2 != 0 ? _huffman(encoded) : encoded;
        final plain = flag & 1 != 0 ? _decompress(decoded) : decoded;
        if (output.length + plain.length > decompressedSize) {
          throw const CbhFormatException('CBV member exceeds declared size.');
        }
        output.add(plain);
        cursor += blockSize;
      }
      if (output.length != decompressedSize) {
        throw const CbhFormatException('CBV member size mismatch.');
      }
      expanded += decompressedSize;
      final target = File(p.join(destination.path, relative));
      if (!p.isWithin(destination.absolute.path, target.absolute.path)) {
        throw const CbhFormatException('Unsafe CBV member path.');
      }
      await target.parent.create(recursive: true);
      await target.writeAsBytes(output.takeBytes(), flush: true);
      if (p.extension(target.path).toLowerCase() == '.cbh') {
        if (indexPath != null) {
          throw const CbhFormatException(
            'CBV archive contains multiple databases.',
          );
        }
        indexPath = target.path;
      }
    }
    if (cursor != bytes.length || indexPath == null) {
      throw const CbhFormatException(
        'CBV archive has no complete CBH database.',
      );
    }
    return indexPath;
  }

  static Uint8List _huffman(Uint8List encoded) {
    if (encoded.length < 2) {
      throw const CbhFormatException('Truncated CBV Huffman block.');
    }
    final expected = (encoded[0] << 8) | encoded[1];
    if (expected > 65535) {
      throw const CbhFormatException('Invalid CBV Huffman size.');
    }
    final bits = _BitReader(encoded, 16);
    final root = _HuffmanNode();
    for (var symbol = 0; symbol < 256; symbol++) {
      final length = bits.read(4);
      if (length == 0) continue;
      final code = bits.read(length);
      var node = root;
      for (var shift = length - 1; shift >= 0; shift--) {
        if (node.symbol != null) {
          throw const CbhFormatException('Invalid CBV Huffman tree.');
        }
        if ((code >> shift) & 1 == 0) {
          node = node.left ??= _HuffmanNode();
        } else {
          node = node.right ??= _HuffmanNode();
        }
      }
      if (node.symbol != null || node.left != null || node.right != null) {
        throw const CbhFormatException('Duplicate CBV Huffman code.');
      }
      node.symbol = symbol;
    }
    final result = Uint8List(expected);
    for (var i = 0; i < expected; i++) {
      var node = root;
      while (node.symbol == null) {
        node =
            bits.read(1) == 0
                ? node.left ?? _invalidTree()
                : node.right ?? _invalidTree();
      }
      result[i] = node.symbol!;
    }
    return result;
  }

  static _HuffmanNode _invalidTree() =>
      throw const CbhFormatException('Invalid CBV Huffman code.');

  static Uint8List _decompress(Uint8List input) {
    final output = BytesBuilder(copy: false);
    final expanded = <int>[];
    var cursor = 0;
    while (cursor < input.length) {
      if (input.length - cursor < 2) {
        throw const CbhFormatException('Truncated CBV compressed block.');
      }
      var flags = _le16(input, cursor);
      cursor += 2;
      for (var i = 0; i < 16 && cursor < input.length; i++) {
        if (flags & 0x8000 == 0) {
          expanded.add(input[cursor++]);
        } else {
          final first = input[cursor++];
          final high = first >> 4;
          final low = first & 15;
          if (high <= 1) {
            final size =
                high == 0
                    ? low + 3
                    : low +
                        0x13 +
                        (cursor < input.length
                            ? input[cursor++] << 4
                            : _truncated());
            if (cursor >= input.length) _truncated();
            final value = input[cursor++];
            for (var j = 0; j < size; j++) {
              expanded.add(value);
            }
          } else {
            if (cursor >= input.length) _truncated();
            final offset = (input[cursor++] << 4) + low + 3;
            final size =
                high == 2
                    ? (cursor < input.length
                        ? input[cursor++] + 0x10
                        : _truncated())
                    : high;
            if (offset > expanded.length) {
              throw const CbhFormatException('Invalid CBV backward reference.');
            }
            for (var j = 0; j < size; j++) {
              expanded.add(expanded[expanded.length - offset]);
            }
          }
        }
        if (expanded.length > 65536) {
          throw const CbhFormatException('Oversized CBV decompressed block.');
        }
        flags = (flags << 1) & 0xffff;
      }
    }
    output.add(expanded);
    return output.takeBytes();
  }

  static Never _truncated() =>
      throw const CbhFormatException('Truncated CBV compression code.');

  static int _le16(List<int> bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int _le32(List<int> bytes, int offset) =>
      _le16(bytes, offset) | (_le16(bytes, offset + 2) << 16);

  static String _filename(List<int> bytes) {
    // CBV member names use the same Windows-1252 profile as CBH metadata.
    const high = <int, String>{
      0x80: '€',
      0x82: '‚',
      0x83: 'ƒ',
      0x84: '„',
      0x85: '…',
      0x86: '†',
      0x87: '‡',
      0x88: 'ˆ',
      0x89: '‰',
      0x8a: 'Š',
      0x8b: '‹',
      0x8c: 'Œ',
      0x8e: 'Ž',
      0x91: '‘',
      0x92: '’',
      0x93: '“',
      0x94: '”',
      0x95: '•',
      0x96: '–',
      0x97: '—',
      0x98: '˜',
      0x99: '™',
      0x9a: 'š',
      0x9b: '›',
      0x9c: 'œ',
      0x9e: 'ž',
      0x9f: 'Ÿ',
    };
    final out = StringBuffer();
    for (final byte in bytes) {
      if (byte < 32 ||
          byte == 127 ||
          (byte >= 0x80 && byte <= 0x9f && !high.containsKey(byte))) {
        throw const CbhFormatException('Invalid CBV member name encoding.');
      }
      out.write(high[byte] ?? String.fromCharCode(byte));
    }
    return out.toString();
  }
}

final class _BitReader {
  _BitReader(this.bytes, this.bit);
  final Uint8List bytes;
  int bit;

  int read(int width) {
    if (bit + width > bytes.length * 8) {
      throw const CbhFormatException('Truncated CBV Huffman stream.');
    }
    var value = 0;
    for (var i = 0; i < width; i++) {
      value = (value << 1) | ((bytes[bit ~/ 8] >> (7 - bit % 8)) & 1);
      bit++;
    }
    return value;
  }
}

final class _HuffmanNode {
  _HuffmanNode? left;
  _HuffmanNode? right;
  int? symbol;
}
