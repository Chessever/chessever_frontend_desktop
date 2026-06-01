import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:chessever/desktop/services/desktop_updater_state.dart';

class DesktopUpdateInstallMarker {
  const DesktopUpdateInstallMarker({
    required this.platform,
    required this.fromVersion,
    required this.targetVersion,
    required this.stagingPath,
    required this.createdAt,
  });

  factory DesktopUpdateInstallMarker.fromJson(Map<String, dynamic> json) {
    return DesktopUpdateInstallMarker(
      platform: json['platform'] as String? ?? '',
      fromVersion: json['fromVersion'] as String? ?? '',
      targetVersion: json['targetVersion'] as String? ?? '',
      stagingPath: json['stagingPath'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  final String platform;
  final String fromVersion;
  final String targetVersion;
  final String stagingPath;
  final DateTime createdAt;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'platform': platform,
      'fromVersion': fromVersion,
      'targetVersion': targetVersion,
      'stagingPath': stagingPath,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  bool isSatisfiedBy(String currentVersion) {
    return DesktopUpdateState.isAtLeast(currentVersion, targetVersion);
  }
}

class DesktopUpdateRecoveryMarkerStore {
  DesktopUpdateRecoveryMarkerStore({Directory? baseDirectory})
    : _baseDirectory = baseDirectory;

  final Directory? _baseDirectory;

  Future<DesktopUpdateInstallMarker?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return DesktopUpdateInstallMarker.fromJson(decoded);
    } catch (_) {
      await clear();
      return null;
    }
  }

  Future<void> write(DesktopUpdateInstallMarker marker) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(marker.toJson()),
      flush: true,
    );
  }

  Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<File> _file() async {
    final base = _baseDirectory ?? await getApplicationSupportDirectory();
    return File(p.join(base.path, 'desktop_update_install_marker.json'));
  }
}

class DesktopUpdateStagedDownloadMarker {
  const DesktopUpdateStagedDownloadMarker({
    required this.platform,
    required this.fromVersion,
    required this.targetVersion,
    required this.stagingPath,
    required this.removedFiles,
    required this.releaseNotes,
    required this.createdAt,
  });

  factory DesktopUpdateStagedDownloadMarker.fromJson(
    Map<String, dynamic> json,
  ) {
    final removed = json['removedFiles'];
    return DesktopUpdateStagedDownloadMarker(
      platform: json['platform'] as String? ?? '',
      fromVersion: json['fromVersion'] as String? ?? '',
      targetVersion: json['targetVersion'] as String? ?? '',
      stagingPath: json['stagingPath'] as String? ?? '',
      removedFiles:
          removed is List
              ? removed.whereType<String>().toList(growable: false)
              : const <String>[],
      releaseNotes: json['releaseNotes'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  final String platform;
  final String fromVersion;
  final String targetVersion;
  final String stagingPath;
  final List<String> removedFiles;
  final String releaseNotes;
  final DateTime createdAt;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'platform': platform,
      'fromVersion': fromVersion,
      'targetVersion': targetVersion,
      'stagingPath': stagingPath,
      'removedFiles': removedFiles,
      'releaseNotes': releaseNotes,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  bool isSatisfiedBy(String currentVersion) {
    return DesktopUpdateState.isAtLeast(currentVersion, targetVersion);
  }

  Future<bool> hasCompleteStagingDirectory() async {
    if (stagingPath.trim().isEmpty) return false;
    final dir = Directory(stagingPath);
    if (!await dir.exists()) return false;

    var hasFile = false;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.part')) return false;
      hasFile = true;
    }
    return hasFile;
  }
}

class DesktopUpdateStagedDownloadMarkerStore {
  DesktopUpdateStagedDownloadMarkerStore({Directory? baseDirectory})
    : _baseDirectory = baseDirectory;

  final Directory? _baseDirectory;

  Future<DesktopUpdateStagedDownloadMarker?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return DesktopUpdateStagedDownloadMarker.fromJson(decoded);
    } catch (_) {
      await clear();
      return null;
    }
  }

  Future<void> write(DesktopUpdateStagedDownloadMarker marker) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(marker.toJson()),
      flush: true,
    );
  }

  Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<File> _file() async {
    final base = _baseDirectory ?? await getApplicationSupportDirectory();
    return File(p.join(base.path, 'desktop_update_staged_download.json'));
  }
}

class DesktopUpdateStageDirectoryCleaner {
  DesktopUpdateStageDirectoryCleaner({Directory? tempDirectory})
    : _tempDirectory = tempDirectory;

  static const String stagePrefix = 'desktop_updater_stage_';

  final Directory? _tempDirectory;

  Future<void> deleteOrphaned({
    String? keepPath,
    Duration minimumAge = const Duration(minutes: 10),
    DateTime? now,
  }) async {
    final root = _tempDirectory ?? Directory.systemTemp;
    if (!await root.exists()) return;

    final keep = keepPath == null ? null : p.normalize(keepPath);
    final referenceTime = now ?? DateTime.now();

    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      if (!p.basename(entity.path).startsWith(stagePrefix)) continue;
      if (keep != null && p.equals(p.normalize(entity.path), keep)) continue;

      try {
        final stat = await entity.stat();
        if (referenceTime.difference(stat.modified) < minimumAge) continue;
        await entity.delete(recursive: true);
      } catch (_) {
        // Best-effort cleanup only; updater safety must not depend on this.
      }
    }
  }

  Future<void> deleteIfStageDirectory(String path) async {
    if (path.trim().isEmpty) return;
    final dir = Directory(path);
    if (!p.basename(dir.path).startsWith(stagePrefix)) return;
    if (!await dir.exists()) return;
    await dir.delete(recursive: true);
  }
}
