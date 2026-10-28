import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import 'package:chessever/desktop/services/local_path_reveal.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';

/// The single label every "reveal the database file" affordance uses, so the
/// Library row menu, the open database header and any future surface read the
/// same words.
const String kLocalDatabaseShowInFolderLabel = 'Show in folder';

/// Whether a database offers `Show in folder`.
///
/// Only a database that has a local file does. A cloud database has no file on
/// this computer, so its menus never offer the action — offering a button that
/// cannot work is worse than omitting it.
bool libraryDatabaseShowsShowInFolder({
  required bool isCloudDatabase,
  required String? localPath,
}) {
  if (isCloudDatabase) return false;
  return (localPath?.trim().isNotEmpty ?? false);
}

/// Builds the `Show in folder` context-menu entry for a database row.
///
/// Returns `null` when [libraryDatabaseShowsShowInFolder] is false, which lets
/// a menu include the action with a plain null check instead of a second
/// availability rule.
DesktopContextMenuItem<T>? localDatabaseShowInFolderMenuItem<T>({
  required T value,
  required String? localPath,
  bool isCloudDatabase = false,
}) {
  if (!libraryDatabaseShowsShowInFolder(
    isCloudDatabase: isCloudDatabase,
    localPath: localPath,
  )) {
    return null;
  }
  return DesktopContextMenuItem<T>(
    value: value,
    icon: Icons.folder_open_outlined,
    label: kLocalDatabaseShowInFolderLabel,
  );
}

/// Whether a local FOLDER offers `Show in folder`.
///
/// Same rule as [libraryDatabaseShowsShowInFolder]: a cloud folder has no
/// directory on this computer, so its menu never offers an action that cannot
/// work.
bool libraryFolderShowsShowInFolder({
  required bool isCloudFolder,
  required String? localPath,
}) {
  if (isCloudFolder) return false;
  return (localPath?.trim().isNotEmpty ?? false);
}

/// Builds the `Show in folder` context-menu entry for a local FOLDER row.
///
/// Returns `null` when [libraryFolderShowsShowInFolder] is false, so a menu can
/// include the action with a plain null check.
DesktopContextMenuItem<T>? localFolderShowInFolderMenuItem<T>({
  required T value,
  required String? localPath,
  bool isCloudFolder = false,
}) {
  if (!libraryFolderShowsShowInFolder(
    isCloudFolder: isCloudFolder,
    localPath: localPath,
  )) {
    return null;
  }
  return DesktopContextMenuItem<T>(
    value: value,
    icon: Icons.folder_open_outlined,
    label: kLocalDatabaseShowInFolderLabel,
  );
}

/// The single folder a group of local database records lives in, or `null` when
/// they do not share one.
///
/// Built only from the records' own stored paths — never a display name and
/// never a guess. A group whose records live in different folders has no single
/// folder, so the caller omits the action instead of opening an arbitrary
/// location.
String? localLibraryGroupFolderPath(Iterable<String> paths) {
  String? folder;
  var hasPath = false;
  for (final path in paths) {
    final parent = localLibraryPathParent(path);
    if (parent == null) return null;
    hasPath = true;
    if (folder == null) {
      folder = parent;
      continue;
    }
    if (folder.toLowerCase() != parent.toLowerCase()) return null;
  }
  return hasPath ? folder : null;
}

/// The containing directory of a stored local path, or `null` when the value
/// has no safe parent (a bare name, or a root-relative `\name`).
///
/// Handles both separator styles so a record written on either desktop platform
/// resolves the same folder. The path itself is never rewritten.
String? localLibraryPathParent(String path) {
  var value = path.trim();
  while (value.length > 1 && (value.endsWith(r'\') || value.endsWith('/'))) {
    value = value.substring(0, value.length - 1);
  }
  final back = value.lastIndexOf(r'\');
  final forward = value.lastIndexOf('/');
  final slash = back > forward ? back : forward;
  if (slash <= 0) return null;
  final directory = value.substring(0, slash);
  // A bare drive (`C:\x.pgn`) must keep its separator: `C:\` not `C:`.
  if (directory.length == 2 && directory.endsWith(':')) return '$directory\\';
  return directory;
}

/// Reveals a local FOLDER itself (the directory, not a selection inside it) and
/// reports the outcome through a desktop toast when it could not be opened.
Future<LocalPathRevealResult> revealLocalFolderPath(
  BuildContext context,
  String path, {
  bool? isWindows,
  bool? isMacOS,
  bool? isLinux,
  String? currentDirectory,
  Future<bool> Function(String path)? pathExists,
  Future<bool> Function(LocalPathRevealCommand command)? runCommand,
  bool Function(WindowsRevealRequest request)? runWindowsReveal,
}) {
  return _revealLocalPath(
    context,
    path,
    target: LocalPathRevealTarget.directory,
    isWindows: isWindows,
    isMacOS: isMacOS,
    isLinux: isLinux,
    currentDirectory: currentDirectory,
    pathExists: pathExists,
    runCommand: runCommand,
    runWindowsReveal: runWindowsReveal,
  );
}

/// Reveals a stored local record with the semantics its own path implies: a
/// directory opens that folder, anything else opens its folder with the file
/// selected.
///
/// [isDirectory] is injectable so the decision is testable; by default the path
/// itself is inspected, and an uninspectable path keeps the file behaviour.
Future<LocalPathRevealResult> revealLocalRecordPath(
  BuildContext context,
  String path, {
  bool Function(String path)? isDirectory,
  bool? isWindows,
  bool? isMacOS,
  bool? isLinux,
  String? currentDirectory,
  Future<bool> Function(String path)? pathExists,
  Future<bool> Function(LocalPathRevealCommand command)? runCommand,
  bool Function(WindowsRevealRequest request)? runWindowsReveal,
}) {
  return _revealLocalPath(
    context,
    path,
    target: localRevealTargetForPath(path, isDirectory: isDirectory),
    isWindows: isWindows,
    isMacOS: isMacOS,
    isLinux: isLinux,
    currentDirectory: currentDirectory,
    pathExists: pathExists,
    runCommand: runCommand,
    runWindowsReveal: runWindowsReveal,
  );
}

/// Shared reveal + toast for every local `Show in folder` entry point.
Future<LocalPathRevealResult> _revealLocalPath(
  BuildContext context,
  String path, {
  required LocalPathRevealTarget target,
  bool? isWindows,
  bool? isMacOS,
  bool? isLinux,
  String? currentDirectory,
  Future<bool> Function(String path)? pathExists,
  Future<bool> Function(LocalPathRevealCommand command)? runCommand,
  bool Function(WindowsRevealRequest request)? runWindowsReveal,
}) async {
  final result = await revealLocalPathInFileManager(
    path,
    isWindows: isWindows,
    isMacOS: isMacOS,
    isLinux: isLinux,
    target: target,
    currentDirectory: currentDirectory,
    pathExists: pathExists,
    runCommand: runCommand,
    runWindowsReveal: runWindowsReveal,
  );
  if (!context.mounted) return result;
  final message = result.message;
  if (message != null && message.isNotEmpty) {
    showDesktopToast(context, message, error: true);
  }
  return result;
}

/// Reveals a local database's file in the OS file manager and reports the
/// outcome through a desktop toast when it could not be shown.
///
/// The reveal itself runs off the UI thread. A missing file names the exact
/// path in the toast; the caller keeps the result so it can stay testable.
Future<LocalPathRevealResult> revealLocalDatabasePath(
  BuildContext context,
  String path, {
  bool? isWindows,
  bool? isMacOS,
  bool? isLinux,
  Future<bool> Function(String path)? pathExists,
  Future<bool> Function(LocalPathRevealCommand command)? runCommand,
  bool Function(WindowsRevealRequest request)? runWindowsReveal,
}) async {
  final result = await revealLocalPathInFileManager(
    path,
    isWindows: isWindows,
    isMacOS: isMacOS,
    isLinux: isLinux,
    pathExists: pathExists,
    runCommand: runCommand,
    runWindowsReveal: runWindowsReveal,
  );
  if (!context.mounted) return result;
  final message = result.message;
  if (message != null && message.isNotEmpty) {
    showDesktopToast(context, message, error: true);
  }
  return result;
}
