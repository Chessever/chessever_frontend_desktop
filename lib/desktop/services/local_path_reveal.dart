import 'dart:io';

import 'package:collection/collection.dart';

import 'package:chessever/desktop/services/windows_shell_reveal.dart';

/// Where a local database lives, resolved for the operating system's file
/// manager.
///
/// "Show in folder" is deliberately read-only: it never reads, writes, moves or
/// rewrites the PGN it points at. It only asks the OS file manager to open the
/// containing folder with that exact file selected.
///
/// This file stays Flutter-free so the real reveal path can be executed by a
/// plain `dart run` probe during verification.

/// A POSIX reveal invocation: an executable plus its argv.
///
/// macOS and Linux take a real argv list, so the path can never be re-split or
/// re-interpreted by a shell. Windows cannot use this shape — see
/// [WindowsRevealRequest].
class LocalPathRevealCommand {
  const LocalPathRevealCommand({
    required this.executable,
    required this.arguments,
  });

  /// The program to start (`open`, `xdg-open`).
  final String executable;

  /// Arguments passed as an argv list — never concatenated into a shell string,
  /// so spaces and unicode in the path can never be re-interpreted by a shell.
  final List<String> arguments;

  @override
  String toString() => '$executable ${arguments.join(' ')}';

  @override
  bool operator ==(Object other) =>
      other is LocalPathRevealCommand &&
      other.executable == executable &&
      const ListEquality<String>().equals(other.arguments, arguments);

  @override
  int get hashCode => Object.hash(executable, Object.hashAll(arguments));
}

/// A Windows reveal request: the shell's `open` verb plus a command-line
/// fragment.
///
/// [parameters] is deliberately a STRING, not an argv list: Explorer re-parses
/// its own command line and only honors `/select,"<path>"` with literal quotes.
/// Dart's `Process.start` escaping rewrites `"` as `\"` and wraps the whole
/// argument, and both escaped forms were measured on Windows 11 to open a
/// Documents window instead of the database's folder. The string is handed to
/// the shell verbatim, never through a shell.
class WindowsRevealRequest {
  const WindowsRevealRequest({
    required this.executable,
    required this.parameters,
  });

  final String executable;

  /// Example: `/select,"C:\Users\Vasif\My Databases\Club Games.pgn"`.
  final String parameters;

  @override
  String toString() => '$executable $parameters';

  @override
  bool operator ==(Object other) =>
      other is WindowsRevealRequest &&
      other.executable == executable &&
      other.parameters == parameters;

  @override
  int get hashCode => Object.hash(executable, parameters);
}

enum LocalPathRevealOutcome {
  /// The file manager was asked to open the folder and select the file.
  revealed,

  /// The record's path no longer exists on this computer.
  missingFile,

  /// No local path, or a platform combination we cannot reveal on.
  unavailable,

  /// The OS command was resolved but could not be started.
  failed,
}

/// What a reveal points at.
///
/// A file is revealed as "its folder, with the file selected"; a directory is
/// revealed as "this folder itself" — no `/select,` semantics.
enum LocalPathRevealTarget { file, directory }

class LocalPathRevealResult {
  const LocalPathRevealResult({
    required this.outcome,
    required this.path,
    this.message,
  });

  final LocalPathRevealOutcome outcome;

  /// The absolute path the reveal was attempted for.
  final String path;

  /// User-facing wording for the non-`revealed` outcomes.
  final String? message;

  bool get revealed => outcome == LocalPathRevealOutcome.revealed;

  @override
  String toString() => 'LocalPathRevealResult($outcome, $path)';
}

/// The Windows reveal request for [path]: `explorer.exe` + the `/select,"…"`
/// fragment with literal quotes.
WindowsRevealRequest windowsRevealRequest(String path) => WindowsRevealRequest(
  executable: 'explorer.exe',
  parameters: '/select,"${windowsRevealPath(path)}"',
);

/// The Windows reveal request for a DIRECTORY: `explorer.exe "<absolute path>"`.
///
/// No `/select,` fragment: the user asked to open this folder, so the folder
/// itself is the target and there is no selection to make. Measured on
/// Windows 11: `explorer.exe "C:\dir with spaces"` opens that folder in a new
/// window, while passing a file path this way opens nothing — which is why the
/// file case keeps [windowsRevealRequest].
WindowsRevealRequest windowsDirectoryRevealRequest(String path) =>
    WindowsRevealRequest(
      executable: 'explorer.exe',
      parameters: '"${windowsRevealPath(path)}"',
    );

/// Whether a stored local path is a directory, so the reveal can open the
/// folder itself instead of selecting a file inside it.
///
/// Injectable (with a filesystem-backed default) so the decision is testable
/// without touching disk. A path that cannot be inspected counts as a file:
/// the shipped file behaviour is the safer default.
bool localRevealPathIsDirectory(
  String path, {
  bool Function(String path)? isDirectory,
}) {
  final probe = isDirectory ?? _defaultIsDirectory;
  try {
    return probe(path.trim());
  } on Object {
    return false;
  }
}

bool _defaultIsDirectory(String path) =>
    FileSystemEntity.isDirectorySync(path);

/// The reveal target for a stored local record: a directory reveals the folder
/// itself, anything else reveals the containing folder with the file selected.
LocalPathRevealTarget localRevealTargetForPath(
  String path, {
  bool Function(String path)? isDirectory,
}) {
  final type = path.trim();
  if (type.isEmpty) return LocalPathRevealTarget.file;
  return localRevealPathIsDirectory(type, isDirectory: isDirectory)
      ? LocalPathRevealTarget.directory
      : LocalPathRevealTarget.file;
}

/// Pure, platform-parameterised builder for the POSIX reveal commands.
///
/// The platforms are parameters (not `Platform.isX` lookups) so every branch —
/// including its quoting rules — is unit-testable on any host.
///
/// - macOS: `open -R "<absolute path>"` (reveal = select in Finder).
/// - Linux: best effort — `xdg-open "<parent directory>"`, because no
///   file-selecting API is available without a new package/DBus dependency.
///
/// Windows uses [windowsRevealRequest] instead and therefore yields no command
/// here.
List<LocalPathRevealCommand> localPathRevealCommands({
  required String path,
  required bool isWindows,
  required bool isMacOS,
  required bool isLinux,
}) {
  final target = path.trim();
  if (target.isEmpty || isWindows) return const <LocalPathRevealCommand>[];

  if (isMacOS) {
    return <LocalPathRevealCommand>[
      LocalPathRevealCommand(
        executable: 'open',
        arguments: <String>['-R', target],
      ),
    ];
  }
  if (isLinux) {
    return <LocalPathRevealCommand>[
      LocalPathRevealCommand(
        executable: 'xdg-open',
        arguments: <String>[posixParentDirectory(target)],
      ),
    ];
  }
  return const <LocalPathRevealCommand>[];
}

/// The reveal command for a DIRECTORY on the POSIX platforms.
///
/// - macOS: `open "<absolute directory>"`
/// - Linux: `xdg-open "<absolute directory>"`
///
/// Windows returns no command: the directory is opened through the shell
/// (`windowsDirectoryRevealRequest`), the same way the file case works.
/// The directory stays exactly one argv element, so spaces, unicode and shell
/// metacharacters in it can never be re-split or re-interpreted.
List<LocalPathRevealCommand> localPathDirectoryRevealCommands({
  required String path,
  required bool isWindows,
  required bool isMacOS,
  required bool isLinux,
}) {
  final target = path.trim();
  if (target.isEmpty || isWindows) return const <LocalPathRevealCommand>[];

  if (isMacOS) {
    return <LocalPathRevealCommand>[
      LocalPathRevealCommand(executable: 'open', arguments: <String>[target]),
    ];
  }
  if (isLinux) {
    return <LocalPathRevealCommand>[
      LocalPathRevealCommand(
        executable: 'xdg-open',
        arguments: <String>[target],
      ),
    ];
  }
  return const <LocalPathRevealCommand>[];
}

/// Normalizes a stored path for the Windows `/select,"…"` fragment.
///
/// Only Windows-shaped absolute paths (drive-letter or UNC) are converted to
/// backslashes: a forward slash is meaningful in a relative/POSIX-looking value
/// and must not be rewritten into a Windows separator.
String windowsRevealPath(String path) {
  final value = path.trim();
  if (value.startsWith(r'\\')) return value.replaceAll('/', r'\');
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) {
    return value.replaceAll('/', r'\');
  }
  return value;
}

/// The containing directory of a POSIX path, used by the Linux fallback.
String posixParentDirectory(String path) {
  var value = path.trim();
  while (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  final slash = value.lastIndexOf('/');
  if (slash < 0) return '.';
  if (slash == 0) return '/';
  return value.substring(0, slash);
}

/// The containing directory of a Windows path, used when a stored record or a
/// row group needs its folder.
///
/// Returns an empty string when no safe parent exists (a bare file name, or a
/// root-relative `\name` value), so a caller skips an unusable command instead
/// of opening an unrelated location.
String windowsParentDirectory(String path) {
  var value = windowsRevealPath(path);
  while (value.length > 1 && value.endsWith(r'\')) {
    value = value.substring(0, value.length - 1);
  }
  final slash = value.lastIndexOf(r'\');
  if (slash <= 0) return '';
  final directory = value.substring(0, slash);
  // A bare drive (`C:\x.pgn`) must keep its separator: `C:\` not `C:`.
  if (directory.length == 2 && directory.endsWith(':')) return '$directory\\';
  return directory;
}

/// Resolves a stored local path for the file manager.
///
/// An already absolute path is returned unchanged — the reveal must never
/// rewrite the path the user opened; only separator normalization happens
/// later, in [windowsRevealPath]. Only a relative record is joined to
/// [currentDirectory], which is the process working directory in production and
/// an explicit value in tests. Pure and platform-parameterised so both branches
/// are testable on any host.
String resolveLocalRevealPath(
  String path, {
  required bool isWindows,
  String currentDirectory = '',
}) {
  final value = path.trim();
  if (value.isEmpty) return value;

  final isAbsolute = isWindows
      ? RegExp(r'^([A-Za-z]:[\\/]|\\\\)').hasMatch(value)
      : value.startsWith('/');
  if (isAbsolute) return value;

  final base = currentDirectory.trim();
  if (base.isEmpty) return value;

  final separator = isWindows ? r'\' : '/';
  var root = base;
  while (root.length > 1 && (root.endsWith('/') || root.endsWith(r'\'))) {
    root = root.substring(0, root.length - 1);
  }
  return '$root$separator$value';
}

String _currentDirectoryPath() {
  try {
    return Directory.current.path;
  } on Object {
    return '';
  }
}

/// Message shown when the database file is gone. It always names the exact path
/// so the user can tell which database went missing instead of being dropped
/// into an unrelated folder.
String localPathRevealMissingMessage(String path) =>
    'That database file is no longer on this computer: ${path.trim()}';

/// Message shown when a revealed FOLDER is gone. Same shape as
/// [localPathRevealMissingMessage]: it names the exact path instead of dropping
/// the user into an unrelated folder.
String localPathRevealMissingDirectoryMessage(String path) =>
    'That folder is no longer on this computer: ${path.trim()}';

/// The missing-path message for [target].
String localPathRevealMissingMessageFor(
  LocalPathRevealTarget target,
  String path,
) => target == LocalPathRevealTarget.directory
    ? localPathRevealMissingDirectoryMessage(path)
    : localPathRevealMissingMessage(path);

/// Message shown when the file exists but the OS file manager could not be
/// started.
String localPathRevealFailureMessage(String path) =>
    'Could not open the folder for ${path.trim()}.';

/// Message shown for a row that has no local file at all (for example a cloud
/// database).
String localPathRevealUnavailableMessage() =>
    'This database has no file on this computer.';

/// Reveals [path] in the OS file manager without blocking the UI.
///
/// The caller never waits on a UI-owned resource: existence is checked with
/// `FileSystemEntity.type`, the POSIX file manager is started with a detached
/// `Process.start`, and the Windows shell call is fast and non-blocking (it
/// asks the shell to open a window and returns).
///
/// [target] chooses the semantics. A `file` (the default, and the shipped
/// behaviour) opens the containing folder with the file selected; a
/// `directory` opens that folder itself. Windows uses the same verified shell
/// helper for both — `/select,"<path>"` for the file, `"<path>"` for the
/// folder.
///
/// The stored value is resolved to an absolute path first (separator
/// normalization and relative resolution only, so an absolute record is passed
/// through unchanged). A path that is gone returns [missingFile] with a message
/// naming the exact path — never a silent drop into an unrelated folder.
Future<LocalPathRevealResult> revealLocalPathInFileManager(
  String path, {
  bool? isWindows,
  bool? isMacOS,
  bool? isLinux,
  LocalPathRevealTarget target = LocalPathRevealTarget.file,
  String? currentDirectory,
  Future<bool> Function(String path)? pathExists,
  Future<bool> Function(LocalPathRevealCommand command)? runCommand,
  bool Function(WindowsRevealRequest request)? runWindowsReveal,
}) async {
  final raw = path.trim();
  if (raw.isEmpty) {
    return LocalPathRevealResult(
      outcome: LocalPathRevealOutcome.unavailable,
      path: '',
      message: localPathRevealUnavailableMessage(),
    );
  }

  final windows = isWindows ?? Platform.isWindows;
  final macos = isMacOS ?? Platform.isMacOS;
  final linux = isLinux ?? (!windows && !macos);

  if (!windows && !macos && !linux) {
    return LocalPathRevealResult(
      outcome: LocalPathRevealOutcome.unavailable,
      path: raw,
      message: localPathRevealUnavailableMessage(),
    );
  }

  // A stored record may be relative; the file manager needs an absolute path.
  final resolved = resolveLocalRevealPath(
    raw,
    isWindows: windows,
    currentDirectory: currentDirectory ?? _currentDirectoryPath(),
  );

  final exists = await (pathExists ?? defaultLocalPathExists)(resolved);
  if (!exists) {
    return LocalPathRevealResult(
      outcome: LocalPathRevealOutcome.missingFile,
      path: resolved,
      message: localPathRevealMissingMessageFor(target, resolved),
    );
  }

  if (windows) {
    final request = target == LocalPathRevealTarget.directory
        ? windowsDirectoryRevealRequest(resolved)
        : windowsRevealRequest(resolved);
    final started = (runWindowsReveal ?? _executeWindowsReveal)(request);
    if (started) {
      return LocalPathRevealResult(
        outcome: LocalPathRevealOutcome.revealed,
        path: resolved,
      );
    }
    return LocalPathRevealResult(
      outcome: LocalPathRevealOutcome.failed,
      path: resolved,
      message: localPathRevealFailureMessage(resolved),
    );
  }

  final commands = target == LocalPathRevealTarget.directory
      ? localPathDirectoryRevealCommands(
          path: resolved,
          isWindows: false,
          isMacOS: macos,
          isLinux: linux,
        )
      : localPathRevealCommands(
          path: resolved,
          isWindows: false,
          isMacOS: macos,
          isLinux: linux,
        );
  if (commands.isEmpty) {
    return LocalPathRevealResult(
      outcome: LocalPathRevealOutcome.unavailable,
      path: resolved,
      message: localPathRevealUnavailableMessage(),
    );
  }

  final run = runCommand ?? startLocalPathRevealCommand;
  for (final command in commands) {
    if (await run(command)) {
      return LocalPathRevealResult(
        outcome: LocalPathRevealOutcome.revealed,
        path: resolved,
      );
    }
  }

  return LocalPathRevealResult(
    outcome: LocalPathRevealOutcome.failed,
    path: resolved,
    message: localPathRevealFailureMessage(resolved),
  );
}

bool _executeWindowsReveal(WindowsRevealRequest request) =>
    executeWindowsShellOpen(
      executable: request.executable,
      parameters: request.parameters,
    );

/// Existence check that treats a directory entry as revealable too: some local
/// database records point at a folder the user registered rather than a single
/// `.pgn`.
Future<bool> defaultLocalPathExists(String path) async {
  final type = await FileSystemEntity.type(path);
  return type != FileSystemEntityType.notFound;
}

/// Starts one POSIX reveal command, detached, and reports whether it launched.
///
/// The child is never routed through a shell, so the path cannot be
/// re-interpreted, and nothing is redirected: the OS file manager owns its own
/// window.
Future<bool> startLocalPathRevealCommand(LocalPathRevealCommand command) async {
  try {
    await Process.start(
      command.executable,
      command.arguments,
      mode: ProcessStartMode.detached,
    );
    return true;
  } on ProcessException {
    return false;
  } on UnsupportedError {
    return false;
  }
}
