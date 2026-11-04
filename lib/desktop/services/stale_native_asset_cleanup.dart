import 'dart:io';

import 'package:chessever/desktop/services/mac_app_store.dart';
import 'package:chessever/utils/host_platform.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;

/// Native-asset frameworks that earlier macOS releases shipped and this one
/// no longer contains.
///
/// When a framework leaves the app, the in-app updater deletes its regular
/// files (they are missing from the new release's file list) but leaves its
/// directories and symlinks, because the updater only tracks regular files.
/// The leftover skeleton is never loaded, yet it sits outside the new bundle's
/// code seal, so `codesign --verify --strict` (and any Gatekeeper
/// re-assessment of the app) rejects an updated install that a fresh DMG
/// install passes. Removing it makes the updated bundle match the release.
///
/// `resqlite.framework` left with the switch to package:sqlite3 (22.21.0).
/// Only add frameworks here that no build at or after this one loads.
const List<String> staleMacFrameworks = <String>['resqlite.framework'];

enum StaleNativeAssetCleanupOutcome {
  /// Not a direct-download macOS app bundle; nothing was examined.
  skipped,

  /// The bundle holds none of [staleMacFrameworks].
  clean,

  /// At least one stale framework was removed and none failed.
  removed,

  /// A stale framework is present but could not be removed (for example a
  /// bundle the current user cannot write to). Retried on the next launch.
  failed,
}

/// Startup housekeeping for direct-download macOS release builds: removes
/// [staleMacFrameworks] left in this app bundle by an in-app update.
///
/// Best effort and idempotent: it costs one directory probe when there is
/// nothing to do, never throws, and never touches anything outside
/// `Contents/Frameworks/<stale framework>`. The Mac App Store edition is
/// skipped (the App Store replaces the whole sealed bundle), as are Windows
/// and Linux (their updater and installers remove whole files).
Future<StaleNativeAssetCleanupOutcome> removeStaleMacNativeAssets({
  void Function(String message)? log,
}) async {
  if (kIsWeb || !hostIsMacOS || isMacAppStore) {
    return StaleNativeAssetCleanupOutcome.skipped;
  }
  final String contentsPath;
  try {
    contentsPath = File(Platform.resolvedExecutable).parent.parent.path;
  } on Object {
    return StaleNativeAssetCleanupOutcome.skipped;
  }
  return removeStaleMacFrameworksInBundle(contentsPath, log: log);
}

/// The testable core of [removeStaleMacNativeAssets]: [contentsPath] must be
/// the `Contents` directory of an `.app` bundle, or nothing is touched.
Future<StaleNativeAssetCleanupOutcome> removeStaleMacFrameworksInBundle(
  String contentsPath, {
  List<String> frameworks = staleMacFrameworks,
  void Function(String message)? log,
}) async {
  final contents = p.normalize(contentsPath);
  if (p.basename(contents) != 'Contents' ||
      p.extension(p.dirname(contents)) != '.app') {
    return StaleNativeAssetCleanupOutcome.skipped;
  }
  var removed = false;
  var failed = false;
  for (final name in frameworks) {
    // Only bare `<name>.framework` entries directly under Frameworks.
    if (name.isEmpty ||
        name != p.basename(name) ||
        p.extension(name) != '.framework') {
      continue;
    }
    final path = p.join(contents, 'Frameworks', name);
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      switch (type) {
        case FileSystemEntityType.notFound:
          continue;
        case FileSystemEntityType.link:
          await Link(path).delete();
        case FileSystemEntityType.directory:
          // Recursive deletion removes symlinks inside the framework without
          // following them, so nothing outside it can be affected.
          await Directory(path).delete(recursive: true);
        default:
          await File(path).delete();
      }
      removed = true;
      log?.call('removed stale native asset $path');
    } on Object catch (error) {
      failed = true;
      log?.call('could not remove stale native asset $path: $error');
    }
  }
  if (failed) return StaleNativeAssetCleanupOutcome.failed;
  return removed
      ? StaleNativeAssetCleanupOutcome.removed
      : StaleNativeAssetCleanupOutcome.clean;
}
