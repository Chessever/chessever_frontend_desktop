import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const _archiveUrl = 'https://chessever.com/updates/desktop/app-archive.json';

Future<void> main() async {
  final current = _readPubspecVersion();
  final client = http.Client();
  final errors = <String>[];

  try {
    final archive = await _fetchJson(client, Uri.parse(_archiveUrl));
    final items = (archive['items'] as List<dynamic>? ?? const []);
    for (final platform in const ['macos', 'windows']) {
      final latest = _latestForPlatform(items, platform);
      if (latest == null) {
        errors.add('$platform: app-archive.json has no item');
        continue;
      }

      final version = latest['version']?.toString() ?? '';
      final build = latest['shortVersion'];
      final releaseVersion = '$version+$build';
      if (releaseVersion != current.fullVersion) {
        errors.add(
          '$platform: latest $releaseVersion does not match pubspec '
          '${current.fullVersion}',
        );
      }

      final url = latest['url']?.toString() ?? '';
      if (!url.contains('/desktop/archive/')) {
        errors.add('$platform: item URL is not a desktop archive URL: $url');
        continue;
      }
      final hashesUri = Uri.parse(
        url.endsWith('/') ? '${url}hashes.json' : '$url/hashes.json',
      );
      final hashesRes = await client.get(hashesUri);
      if (hashesRes.statusCode != 200) {
        errors.add('$platform: hashes.json HTTP ${hashesRes.statusCode}');
        continue;
      }
      final hashes = jsonDecode(hashesRes.body);
      if (hashes is! List || hashes.isEmpty) {
        errors.add('$platform: hashes.json must be a non-empty list');
        continue;
      }
      final paths = <String>{};
      for (final entry in hashes) {
        if (entry is! Map<String, dynamic>) {
          errors.add('$platform: hashes.json has a non-object entry');
          continue;
        }
        final path = entry['path']?.toString() ?? '';
        final hash = entry['calculatedHash']?.toString() ?? '';
        final length = entry['length'];
        if (path.isEmpty || path.contains('..') || path.startsWith('/')) {
          errors.add('$platform: unsafe hash path $path');
        }
        if (hash.isEmpty) {
          errors.add('$platform: hash missing for $path');
        }
        if (length is! int || length < 0) {
          errors.add('$platform: invalid length for $path');
        }
        paths.add(path);
      }
      if (platform == 'macos' && !paths.contains('Info.plist')) {
        errors.add('macos: archive should contain Contents/Info.plist payload');
      }
      if (platform == 'windows' && !paths.contains('Chessever.exe')) {
        errors.add('windows: archive should contain Chessever.exe');
      }
      stdout.writeln(
        '$platform: latest=$releaseVersion files=${paths.length} url=$url',
      );
    }
  } finally {
    client.close();
  }

  if (errors.isNotEmpty) {
    stderr.writeln('\nDesktop app archive verification failed:');
    for (final error in errors) {
      stderr.writeln('- $error');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln('Desktop app archive matches pubspec and latest archives.');
}

Future<Map<String, dynamic>> _fetchJson(http.Client client, Uri uri) async {
  final res = await client.get(uri);
  if (res.statusCode != 200) {
    throw HttpException('HTTP ${res.statusCode}', uri: uri);
  }
  return jsonDecode(res.body) as Map<String, dynamic>;
}

Map<String, dynamic>? _latestForPlatform(List<dynamic> items, String platform) {
  final platformItems =
      items
          .whereType<Map<String, dynamic>>()
          .where((item) => item['platform'] == platform)
          .toList();
  if (platformItems.isEmpty) return null;
  platformItems.sort((a, b) {
    final aBuild = a['shortVersion'];
    final bBuild = b['shortVersion'];
    final aInt = aBuild is int ? aBuild : int.tryParse('$aBuild') ?? 0;
    final bInt = bBuild is int ? bBuild : int.tryParse('$bBuild') ?? 0;
    return bInt.compareTo(aInt);
  });
  return platformItems.first;
}

_PubspecVersion _readPubspecVersion() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final raw = RegExp(
    r'^version:\s*(\S+)',
    multiLine: true,
  ).firstMatch(pubspec)?.group(1);
  if (raw == null || raw.isEmpty) {
    throw StateError('pubspec.yaml version is missing');
  }
  final parts = raw.split('+');
  if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) {
    throw StateError('pubspec.yaml version must include +build, got $raw');
  }
  return _PubspecVersion(parts[0], parts[1]);
}

class _PubspecVersion {
  const _PubspecVersion(this.version, this.build);

  final String version;
  final String build;

  String get fullVersion => '$version+$build';
}
