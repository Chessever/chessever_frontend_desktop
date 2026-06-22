import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bitmap image renderers declare bounded decode sizes', () {
    final failures = <String>[];
    final files =
        Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      final source = file.readAsStringSync();
      failures.addAll(_boundedConstructorFailures(file.path, source));
    }

    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}

List<String> _boundedConstructorFailures(String path, String source) {
  final failures = <String>[];

  for (final invocation in _invocations(source, 'CachedNetworkImage(')) {
    _requireFields(failures, path, source, invocation, const [
      'memCacheWidth',
      'memCacheHeight',
    ]);
  }

  for (final constructor in const [
    'Image.asset(',
    'Image.file(',
    'Image.memory(',
    'Image.network(',
  ]) {
    for (final invocation in _invocations(source, constructor)) {
      _requireFields(failures, path, source, invocation, const [
        'cacheWidth',
        'cacheHeight',
      ]);
    }
  }

  for (final invocation in _rawImageInvocations(source)) {
    final body = invocation.body;
    if (!body.contains('image:')) continue;
    if (body.contains('ResizeImage.resizeIfNeeded(')) continue;
    if (body.contains('imageProvider')) continue;

    failures.add(
      '${_location(path, source, invocation.start)}: '
      'Image(image:) must wrap its provider in ResizeImage.resizeIfNeeded',
    );
  }

  for (final invocation in _invocations(source, 'DecorationImage(')) {
    final body = invocation.body;
    if (!body.contains('image:')) continue;
    if (body.contains('ResizeImage.resizeIfNeeded(')) continue;
    if (body.contains('imageProvider')) continue;

    failures.add(
      '${_location(path, source, invocation.start)}: '
      'DecorationImage image provider must be ResizeImage-bounded',
    );
  }

  return failures;
}

void _requireFields(
  List<String> failures,
  String path,
  String source,
  _Invocation invocation,
  List<String> fields,
) {
  final missing = fields.where((field) => !invocation.body.contains(field));
  if (missing.isEmpty) return;

  failures.add(
    '${_location(path, source, invocation.start)}: '
    '${invocation.constructorName} missing ${missing.join(', ')}',
  );
}

Iterable<_Invocation> _invocations(
  String source,
  String constructorName,
) sync* {
  var start = 0;
  while (true) {
    final index = source.indexOf(constructorName, start);
    if (index < 0) break;
    final openParen = index + constructorName.length - 1;
    final end = _matchingParen(source, openParen);
    if (end < 0) {
      start = openParen + 1;
      continue;
    }

    yield _Invocation(
      constructorName: constructorName.substring(0, constructorName.length - 1),
      start: index,
      body: source.substring(index, end + 1),
    );
    start = end + 1;
  }
}

Iterable<_Invocation> _rawImageInvocations(String source) sync* {
  var start = 0;
  while (true) {
    final index = source.indexOf('Image(', start);
    if (index < 0) break;

    final previous = index == 0 ? '' : source[index - 1];
    if (_isIdentifierOrAccessor(previous)) {
      start = index + 1;
      continue;
    }

    final openParen = index + 'Image'.length;
    final end = _matchingParen(source, openParen);
    if (end < 0) {
      start = openParen + 1;
      continue;
    }

    yield _Invocation(
      constructorName: 'Image',
      start: index,
      body: source.substring(index, end + 1),
    );
    start = end + 1;
  }
}

int _matchingParen(String source, int openParen) {
  var depth = 0;
  String? quote;
  var escaped = false;

  for (var i = openParen; i < source.length; i++) {
    final char = source[i];

    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }

    if (char == "'" || char == '"') {
      quote = char;
      continue;
    }

    if (char == '(') depth++;
    if (char == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

bool _isIdentifierOrAccessor(String value) {
  if (value == '.' || value == '_') return true;
  if (value.isEmpty) return false;
  final code = value.codeUnitAt(0);
  return (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122);
}

String _location(String path, String source, int index) {
  final line = '\n'.allMatches(source.substring(0, index)).length + 1;
  return '$path:$line';
}

class _Invocation {
  const _Invocation({
    required this.constructorName,
    required this.start,
    required this.body,
  });

  final String constructorName;
  final int start;
  final String body;
}
