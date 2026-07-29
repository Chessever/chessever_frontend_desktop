import "dart:convert";
import "dart:io";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/app_archive.dart";
import "package:desktop_updater/src/remote_file.dart";
import "package:path/path.dart" as p;

import "helper/copy.dart";

Future<String> getFileHash(File file) async {
  try {
    // Dosya içeriğini okuyun
    final List<int> fileBytes = await file.readAsBytes();

    // blake2s algoritmasıyla hash hesaplayın

    final hash = await Blake2b().hash(fileBytes);

    // Hash'i utf-8 base64'e dönüştürün ve geri döndürün
    return base64.encode(hash.bytes);
  } on Object catch (error) {
    stderr.writeln("Error reading file ${file.path}: $error");
    return "";
  }
}

Future<String?> genFileHashes({
  required String? path,
  bool includeFileLinks = false,
}) async {
  stdout.writeln("Generating file hashes for $path");

  if (path == null) {
    throw Exception("Desktop Updater: Executable path is null");
  }

  final dir = Directory(path);

  stdout.writeln("Directory path: ${dir.path}");

  // Eğer belirtilen yol bir dizinse
  if (await dir.exists()) {
    // temp dizinindeki dosyaları kopyala
    // dir + output.txt dosyası oluşturulur
    final outputFile = File("${dir.path}${Platform.pathSeparator}hashes.json");

    // ignore: prefer_final_locals
    var hashList = <FileHashModel>[];

    // Dizin içindeki tüm dosyaları döngüyle okuyoruz
    final archiveRoot = p.normalize(await dir.resolveSymbolicLinks());
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      File? hashableFile;
      if (entity is File) {
        hashableFile = entity;
      } else if (includeFileLinks && entity is Link) {
        final resolvedPath = p.normalize(await entity.resolveSymbolicLinks());
        if (!p.isWithin(archiveRoot, resolvedPath)) {
          throw StateError(
            "Desktop Updater: Archive link escapes its root: ${entity.path}",
          );
        }
        if (FileSystemEntity.typeSync(resolvedPath) ==
            FileSystemEntityType.file) {
          // Hash through the alias. The Linux publisher materializes the link
          // as a regular file after hashing, so legacy clients can download a
          // complete SONAME path without learning a new archive protocol.
          hashableFile = File(entity.path);
        }
      }

      if (hashableFile != null &&
          !entity.path.endsWith("hashes.json") &&
          !entity.path.endsWith(".DS_Store")) {
        // Dosyanın hash'ini al
        final hash = await getFileHash(hashableFile);
        final foundPath = normalizeArchivePath(
          entity.path.substring(dir.path.length + 1),
        );

        if (hash.isNotEmpty) {
          final hashObj = FileHashModel(
            filePath: foundPath,
            calculatedHash: hash,
            length: hashableFile.lengthSync(),
          );
          hashList.add(hashObj);
        }
      }
    }

    hashList.sort((a, b) => a.filePath.compareTo(b.filePath));
    await outputFile.writeAsString(
      const JsonEncoder.withIndent("  ").convert(hashList),
    );
    return outputFile.path;
  } else {
    throw Exception("Desktop Updater: Directory does not exist");
  }
}

bool _isSupportedArchivePlatform(String platform) {
  return platform == "macos" ||
      platform == "macos-arm64" ||
      platform == "macos-x64" ||
      platform == "windows" ||
      platform == "linux";
}

bool _isMacOsArchivePlatform(String platform) {
  return platform == "macos" ||
      platform == "macos-arm64" ||
      platform == "macos-x64";
}

/// Parse `name-1.2.3+4-macos-arm64` style directory basenames.
///
/// Dual macOS keys end with `-macos-arm64` / `-macos-x64`; a naive
/// `split("-").last` would yield only `arm64` / `x64`.
final _distFolderRe = RegExp(
  r'^(?:.+-)?(?<version>\d+\.\d+\.\d+)\+(?<build>\d+)-'
  r'(?<platform>macos(?:-arm64|-x64)?|windows|linux)$',
);

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      "PLATFORM must be specified: macos, macos-arm64, macos-x64, windows, linux",
    );
    exit(1);
  }

  final platform = args[0];

  if (!_isSupportedArchivePlatform(platform)) {
    stderr.writeln(
      "PLATFORM must be specified: macos, macos-arm64, macos-x64, windows, linux",
    );
    exit(1);
  }

  // Go to dist directory and get all folder names
  final distDir = Directory("dist");

  if (!await distDir.exists()) {
    stderr.writeln("dist folder could not be found");
    exit(1);
  }

  /// Sort folders by name, it will be the build number,
  /// and get the last one, biggest build number
  final folders = await distDir.list().toList();
  folders.sort((a, b) => a.path.compareTo(b.path));

  final lastBuildNumberFolder = folders.last;

  // Get all files in the last folder path
  final files = await Directory(lastBuildNumberFolder.path).list().toList();

  var platformFound = false;
  String? foundDirectory;
  String? foundVersion;
  String? foundBuildNumber;

  /// Check if there is a file in given platform
  for (final file in files) {
    if (file is Directory) {
      // chessever-20.25.1+264-macos-arm64
      final base = p.basename(file.path);
      final match = _distFolderRe.firstMatch(base);
      if (match == null) continue;
      final foundPlatform = match.namedGroup("platform")!;
      final version = match.namedGroup("version")!;
      final buildNumber = match.namedGroup("build")!;

      if (foundPlatform == platform) {
        platformFound = true;
        foundDirectory = file.path;
        foundVersion = version;
        foundBuildNumber = buildNumber;
      }
    }
  }

  if (!platformFound || foundDirectory == null) {
    stderr.writeln("File not found for platform: $platform");
    exit(1);
  } else {
    stdout.writeln("Using archive: $foundDirectory");
  }

  // Get current build name and number from pubspec.yaml
  final pubspec = File("pubspec.yaml");
  final pubspecContent = await pubspec.readAsString();
  final appNamePubspec = RegExp(
    r"name: (.+)",
  ).firstMatch(pubspecContent)!.group(1);

  if (platform == "windows") {
    await copyDirectory(
      Directory(foundDirectory),
      Directory(
        "${lastBuildNumberFolder.path}${Platform.pathSeparator}$foundVersion+$foundBuildNumber-$platform",
      ),
    );
  } else if (_isMacOsArchivePlatform(platform)) {
    await copyDirectory(
      Directory("$foundDirectory/$appNamePubspec.app/Contents"),
      Directory(
        "${lastBuildNumberFolder.path}${Platform.pathSeparator}$foundVersion+$foundBuildNumber-$platform",
      ),
    );
  } else if (platform == "linux") {
    await copyDirectory(
      Directory(foundDirectory),
      Directory(
        "${lastBuildNumberFolder.path}/$foundVersion+$foundBuildNumber-$platform",
      ),
    );
  }

  await genFileHashes(
    path:
        "${lastBuildNumberFolder.path}${Platform.pathSeparator}$foundVersion+$foundBuildNumber-$platform",
    includeFileLinks: platform == "linux",
  );

  return;
}
