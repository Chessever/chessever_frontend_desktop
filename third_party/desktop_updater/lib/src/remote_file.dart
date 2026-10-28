import "dart:async";
import "dart:io";

import "package:http/http.dart" as http;
import "package:path/path.dart" as path;

/// How long a request may wait for the server's first answer.
const Duration remoteConnectTimeout = Duration(seconds: 30);

/// How long a transfer may go without receiving a single byte. A slow
/// connection keeps sending and never trips this; a dead socket (sleep, a
/// dropped Wi-Fi) does, and the caller gets an error it can retry instead of
/// a download that never ends.
const Duration remoteIdleTimeout = Duration(seconds: 60);

String normalizeArchivePath(String filePath) {
  final normalized = filePath.replaceAll("\\", "/");
  final segments = normalized
      .split("/")
      .where((segment) => segment.isNotEmpty && segment != ".")
      .toList(growable: false);

  if (segments.any((segment) => segment == "..") ||
      normalized.startsWith("/") ||
      RegExp(r"^[a-zA-Z]:").hasMatch(normalized)) {
    throw FormatException("Unsafe update path: $filePath");
  }

  return segments.join("/");
}

String localPathForArchivePath(String root, String filePath) {
  final normalized = normalizeArchivePath(filePath);
  return path.joinAll([root, ...normalized.split("/")]);
}

Uri resolveRemoteFileUri(String base, String relativePath) {
  final normalized = normalizeArchivePath(relativePath);
  final segments = normalized.split("/");

  if (_looksLikeLocalPath(base)) {
    return Uri.file(path.joinAll([base, ...segments]));
  }

  final baseUri = Uri.parse(base.endsWith("/") ? base : "$base/");
  if (baseUri.scheme.isEmpty) {
    return Uri.file(path.joinAll([base, ...segments]));
  }

  final escapedRelative = segments.map(Uri.encodeComponent).join("/");
  return baseUri.resolve(escapedRelative);
}

Uri resolveSourceUri(String source) {
  if (_looksLikeLocalPath(source)) {
    return Uri.file(source);
  }

  final uri = Uri.parse(source);
  if (uri.scheme.isEmpty) {
    return Uri.file(source);
  }

  return uri;
}

Future<void> downloadUriToFile(
  String source,
  File destination, {
  void Function(int receivedBytes, int? totalBytes)? onProgress,
  Duration connectTimeout = remoteConnectTimeout,
  Duration idleTimeout = remoteIdleTimeout,
}) async {
  await _writeUriToFile(
    resolveSourceUri(source),
    destination,
    onProgress: onProgress,
    connectTimeout: connectTimeout,
    idleTimeout: idleTimeout,
  );
}

Future<void> downloadRemoteFileTo({
  required String base,
  required String relativePath,
  required File destination,
  void Function(int receivedBytes, int? totalBytes)? onProgress,
}) async {
  await _writeUriToFile(
    resolveRemoteFileUri(base, relativePath),
    destination,
    onProgress: onProgress,
  );
}

Future<void> _writeUriToFile(
  Uri uri,
  File destination, {
  void Function(int receivedBytes, int? totalBytes)? onProgress,
  Duration connectTimeout = remoteConnectTimeout,
  Duration idleTimeout = remoteIdleTimeout,
}) async {
  await destination.parent.create(recursive: true);
  final partial = File("${destination.path}.part");

  if (await partial.exists()) {
    await partial.delete();
  }

  try {
    if (uri.scheme == "http" || uri.scheme == "https") {
      await _downloadHttpUri(
        uri,
        partial,
        onProgress: onProgress,
        connectTimeout: connectTimeout,
        idleTimeout: idleTimeout,
      );
    } else if (uri.scheme == "file") {
      await _copyLocalFile(
        File(uri.toFilePath(windows: Platform.isWindows)),
        partial,
        onProgress: onProgress,
      );
    } else {
      throw UnsupportedError("Unsupported update URL scheme: ${uri.scheme}");
    }

    if (await destination.exists()) {
      await destination.delete();
    }
    await partial.rename(destination.path);
  } catch (_) {
    if (await partial.exists()) {
      await partial.delete();
    }
    rethrow;
  }
}

Future<void> _downloadHttpUri(
  Uri uri,
  File destination, {
  void Function(int receivedBytes, int? totalBytes)? onProgress,
  Duration connectTimeout = remoteConnectTimeout,
  Duration idleTimeout = remoteIdleTimeout,
}) async {
  final client = http.Client();

  try {
    final request = http.Request("GET", uri);
    // Closing the client in `finally` aborts whatever a timeout left open.
    final response = await client.send(request).timeout(connectTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        "Failed to download $uri: HTTP ${response.statusCode}",
        uri: uri,
      );
    }

    await _writeStream(
      response.stream.timeout(idleTimeout),
      destination,
      totalBytes: response.contentLength,
      onProgress: onProgress,
    );
  } finally {
    client.close();
  }
}

Future<void> _copyLocalFile(
  File source,
  File destination, {
  void Function(int receivedBytes, int? totalBytes)? onProgress,
}) async {
  if (!await source.exists()) {
    throw FileSystemException("Update file not found", source.path);
  }

  await _writeStream(
    source.openRead(),
    destination,
    totalBytes: await source.length(),
    onProgress: onProgress,
  );
}

Future<void> _writeStream(
  Stream<List<int>> stream,
  File destination, {
  required int? totalBytes,
  void Function(int receivedBytes, int? totalBytes)? onProgress,
}) async {
  final sink = destination.openWrite();
  var receivedBytes = 0;

  try {
    await for (final chunk in stream) {
      receivedBytes += chunk.length;
      sink.add(chunk);
      onProgress?.call(receivedBytes, totalBytes);
    }
  } finally {
    await sink.close();
  }
}

bool _looksLikeLocalPath(String value) {
  return value.startsWith("/") ||
      value.startsWith("./") ||
      value.startsWith("../") ||
      (Platform.isWindows && RegExp(r"^[a-zA-Z]:[\\/]").hasMatch(value));
}
