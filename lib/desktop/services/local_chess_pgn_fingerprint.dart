import 'dart:convert';

import 'package:crypto/crypto.dart';

String localChessPgnFingerprint(String rawPgn) {
  final normalized = rawPgn.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final headers = <String, String>{};
  var headerEnd = 0;
  for (final match in _headerRegex.allMatches(normalized)) {
    final key = match.group(1)?.trim();
    final value = match.group(2)?.trim();
    if (key == null || key.isEmpty || value == null) continue;
    headers[key.toLowerCase()] = _normalizeHeaderValue(value);
    if (match.end > headerEnd) headerEnd = match.end;
  }

  final identity = <String>[
    for (final key in const <String>[
      'event',
      'site',
      'date',
      'round',
      'white',
      'black',
      'result',
      'fen',
      'setup',
    ])
      '$key=${headers[key] ?? ''}',
  ];
  final moves = _mainlineTokens(normalized.substring(headerEnd)).join(' ');
  return sha1
      .convert(utf8.encode('${identity.join('|')}|moves=$moves'))
      .toString();
}

final RegExp _headerRegex = RegExp(
  r'^\s*\[([A-Za-z0-9_]+)\s+"((?:\\.|[^"\\])*)"\]\s*$',
  multiLine: true,
);

String _normalizeHeaderValue(String value) {
  return value
      .replaceAll(r'\"', '"')
      .replaceAll(r'\\', r'\')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();
}

Iterable<String> _mainlineTokens(String movetext) sync* {
  var variationDepth = 0;
  var inBraceComment = false;
  var inLineComment = false;
  final token = StringBuffer();

  for (var i = 0; i <= movetext.length; i++) {
    final code = i < movetext.length ? movetext.codeUnitAt(i) : 0x20;

    if (inLineComment) {
      if (code == 0x0A) inLineComment = false;
      continue;
    }
    if (inBraceComment) {
      if (code == 0x7D) inBraceComment = false;
      continue;
    }

    if (code == 0x7B) {
      final cleaned = _cleanMoveToken(token.toString());
      token.clear();
      if (variationDepth == 0 && cleaned != null) yield cleaned;
      inBraceComment = true;
      continue;
    }
    if (code == 0x3B) {
      final cleaned = _cleanMoveToken(token.toString());
      token.clear();
      if (variationDepth == 0 && cleaned != null) yield cleaned;
      inLineComment = true;
      continue;
    }
    if (code == 0x28) {
      final cleaned = _cleanMoveToken(token.toString());
      token.clear();
      if (variationDepth == 0 && cleaned != null) yield cleaned;
      variationDepth++;
      continue;
    }
    if (code == 0x29) {
      if (variationDepth > 0) variationDepth--;
      token.clear();
      continue;
    }
    if (_isAsciiWhitespace(code)) {
      final cleaned = _cleanMoveToken(token.toString());
      token.clear();
      if (variationDepth == 0 && cleaned != null) yield cleaned;
      continue;
    }
    if (variationDepth > 0) continue;
    token.writeCharCode(code);
  }
}

String? _cleanMoveToken(String raw) {
  var token = raw.trim();
  if (token.isEmpty) return null;
  token = token.replaceAll(RegExp(r'^\d+\.(\.\.)?'), '');
  token = token.replaceAll(RegExp(r'^\.+'), '');
  token = token.replaceAll(RegExp(r'\$[0-9]+'), '');
  token = token.replaceAll(RegExp(r'[!?]+$'), '');
  token = token.replaceAll(RegExp(r'[+#]+$'), '');
  token = token.trim();
  if (token.isEmpty) return null;
  if (_resultTokens.contains(token)) return null;
  if (RegExp(r'^\d+$').hasMatch(token)) return null;
  return _normalizeMoveSpelling(token).toLowerCase();
}

bool _isAsciiWhitespace(int code) =>
    code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D;

const Set<String> _resultTokens = <String>{'1-0', '0-1', '1/2-1/2', '½-½', '*'};

String _normalizeMoveSpelling(String token) {
  final upper = token.toUpperCase();
  if (upper == '0-0') return 'O-O';
  if (upper == '0-0-0') return 'O-O-O';
  return token;
}
