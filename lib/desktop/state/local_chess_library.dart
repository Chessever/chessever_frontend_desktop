import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';

@immutable
class LocalChessLibraryState {
  const LocalChessLibraryState({
    this.source,
    this.selectedPath,
    this.isScanning = false,
    this.error,
  });

  final LocalChessSource? source;
  final String? selectedPath;
  final bool isScanning;
  final String? error;

  LocalChessNode? get selectedNode => source?.nodeForPath(selectedPath);
}

class LocalChessLibraryNotifier extends StateNotifier<LocalChessLibraryState> {
  LocalChessLibraryNotifier({this.registry})
    : super(const LocalChessLibraryState());

  /// Optional registry that records picked/opened local PGNs as persistent
  /// "local databases" the user can save into later. Tests can leave
  /// this null to avoid touching the DB.
  final LocalLibraryRegistryNotifier? registry;

  Object? _scanToken;

  Future<bool> pickFolder() async {
    _localLibraryLog('pickFolder dialog start');
    final directory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Browse local chess folder',
      lockParentWindow: true,
    );
    _localLibraryLog('pickFolder dialog returned directory=$directory');
    if (directory == null || directory.isEmpty) return false;
    return openPaths(<String>[directory]);
  }

  Future<bool> pickFiles() async {
    _localLibraryLog('pickFiles dialog start');
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Open chess files',
      type: FileType.custom,
      allowedExtensions: localChessPickerExtensions,
      allowMultiple: true,
      withData: false,
      lockParentWindow: true,
    );
    _localLibraryLog('pickFiles dialog returned count=${result?.files.length}');
    if (result == null || result.files.isEmpty) return false;
    final paths = result.files
        .map((file) => file.path)
        .whereType<String>()
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    if (paths.isEmpty) return false;
    return openPaths(paths, sourceLabel: paths.length == 1 ? null : 'Files');
  }

  Future<bool> openPaths(List<String> paths, {String? sourceLabel}) async {
    _localLibraryLog(
      'openPaths start count=${paths.length} sourceLabel=${sourceLabel ?? 'null'} paths=$paths',
    );
    final token = Object();
    _scanToken = token;
    _localLibraryLog('openPaths set isScanning=true');
    state = LocalChessLibraryState(
      source: state.source,
      selectedPath: state.selectedPath,
      isScanning: true,
    );
    try {
      _localLibraryLog('openPaths scan dispatch');
      final source = await scanLocalChessPaths(paths, sourceLabel: sourceLabel);
      _localLibraryLog(
        'openPaths scan returned label=${source.label} games=${source.root.gameCount} files=${source.root.fileCount}',
      );
      if (_scanToken != token) {
        _localLibraryLog('openPaths stale token after scan');
        return false;
      }
      _localLibraryLog('openPaths assigning state');
      state = LocalChessLibraryState(
        source: source,
        selectedPath: source.root.path,
      );
      _localLibraryLog('openPaths state assigned selected=${source.root.path}');
      await registry?.registerAll(paths);
      _localLibraryLog('openPaths registry complete');
      return true;
    } catch (e) {
      _localLibraryLog('openPaths failed error=$e');
      if (_scanToken != token) return false;
      state = LocalChessLibraryState(
        source: state.source,
        selectedPath: state.selectedPath,
        error: localChessOpenErrorMessage(e),
      );
      return false;
    }
  }

  Future<void> refresh() async {
    final source = state.source;
    if (source == null) return;
    await openPaths(source.paths, sourceLabel: source.label);
  }

  void selectPath(String path) {
    final source = state.source;
    if (source == null || source.nodeForPath(path) == null) return;
    state = LocalChessLibraryState(source: source, selectedPath: path);
  }

  void clear() {
    _scanToken = null;
    state = const LocalChessLibraryState();
  }
}

void _localLibraryLog(String message) {
  stdout.writeln(
    '[LOCAL_PGN_LIBRARY ${DateTime.now().toIso8601String()}] $message',
  );
}

final localChessLibraryProvider =
    StateNotifierProvider<LocalChessLibraryNotifier, LocalChessLibraryState>(
      (ref) => LocalChessLibraryNotifier(
        registry: ref.read(localLibraryRegistryProvider.notifier),
      ),
    );

@visibleForTesting
String localChessOpenErrorMessage(Object error) {
  if (error is ArgumentError) {
    final message = error.message;
    if (message != null) {
      final text = message.toString().trim();
      if (text.isNotEmpty) return text;
    }
  }

  if (error is FileSystemException) {
    final message = error.message.trim();
    final path = error.path?.trim();
    if (path == null || path.isEmpty) return message;
    return '$message: $path';
  }

  return error.toString();
}
