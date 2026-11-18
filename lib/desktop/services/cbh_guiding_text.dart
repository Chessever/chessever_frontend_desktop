import 'dart:typed_data';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'cbh_index_reader.dart';
import 'cbh_utf8.dart';

/// The version 3 container used by classic CBH. Like the reference converter
/// in tools/cbh_converter/preservation.py, this renders text only and archives
/// the full container separately. It never loads embedded resources.
String decodeCbhGuidingText(Uint8List raw, int recordNumber) {
  Never fail(String reason) =>
      throw CbhFormatException('Record $recordNumber: $reason.');
  if (raw.length < 11 ||
      raw[0] != 0x80 ||
      ((raw[1] << 16) | (raw[2] << 8) | raw[3]) != raw.length) {
    fail('invalid guiding text frame');
  }
  var cursor = 4;
  Uint8List take(int size) {
    if (size < 0 || size > raw.length - cursor) {
      fail('truncated guiding text entry');
    }
    final part = Uint8List.sublistView(raw, cursor, cursor + size);
    cursor += size;
    return part;
  }

  int number(int width) {
    final part = take(width);
    var value = 0;
    for (var i = width - 1; i >= 0; i--) {
      value = (value << 8) | part[i];
    }
    return value;
  }

  String text(int size) {
    final bytes = take(size);
    try {
      return decodeCbhUtf8(bytes);
    } on FormatException {
      fail('unsupported guiding text encoding');
    }
  }

  if (number(2) != 3) fail('unsupported guiding text version');
  final sections = <String>[];
  final titleCount = number(2);
  for (var i = 0; i < titleCount; i++) {
    final language = number(2);
    final title = _pgnText(text(number(2)));
    if (title.isNotEmpty) sections.add('Title (language $language): $title');
  }
  if (number(1) != 1) fail('unsupported guiding text flag');
  final bodyCount = number(2);
  for (var i = 0; i < bodyCount; i++) {
    final language = number(2);
    final markup = text(number(4));
    if (number(4) != 0) fail('unsupported guiding text trailer');
    final document = html.parse(markup);
    final output = StringBuffer();
    final pending = <(Node, bool)>[(document.body!, false)];
    const blocks = {'p', 'div', 'br', 'li', 'tr', 'td', 'h1', 'h2', 'h3'};
    while (pending.isNotEmpty) {
      final (node, after) = pending.removeLast();
      if (after) {
        output.write(' ');
      } else if (node is Text) {
        output.write(node.data);
      } else if (node is Element) {
        final tag = node.localName;
        if (const {'script', 'style', 'template', 'iframe'}.contains(tag)) {
          continue;
        }
        if (blocks.contains(tag)) {
          output.write(' ');
          pending.add((node, true));
        }
        final alt = tag == 'img' ? node.attributes['alt'] : null;
        if (alt != null) {
          output.write(' [Image: $alt] ');
        }
        for (final child in node.nodes.reversed) {
          pending.add((child, false));
        }
      }
    }
    final body = _pgnText(output.toString());
    if (body.isNotEmpty) sections.add('Language $language: $body');
  }
  if (cursor != raw.length) fail('unconsumed guiding text content');
  return sections.isEmpty
      ? 'ChessBase guiding text: empty bodies.'
      : sections.join('\n');
}

String _pgnText(String text) =>
    text
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAllMapped(
          RegExp(r'[\x00-\x1f\x7f]'),
          (m) => '[0x${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(2, '0')}]',
        )
        .replaceAll('{', '&#123;')
        .replaceAll('}', '&#125;')
        .trim();
