import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/local_chess_file_access.dart';
import 'package:chessever/desktop/state/active_board_game.dart';

/// Open the OS file dialog for picking a `.pgn`, read it from disk, and
/// open it as a detached Board tab.
///
/// Used by the command palette ("Open PGN on Board…", ⌘O) and any "Open
/// file" affordance the panes add later. Returns `true` if a file was loaded.
class PgnFilePicker {
  PgnFilePicker(this.ref, {this.onError});
  final WidgetRef ref;
  final void Function(String message)? onError;

  Future<bool> pickAndLoad() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Open PGN',
        type: FileType.custom,
        allowedExtensions: const ['pgn'],
        allowMultiple: false,
        // A browser hands over the file's bytes and never a path.
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) return false;
      final file = result.files.single;
      final path = kIsWeb ? file.name : file.path;
      if (path == null) return false;

      final pgn =
          kIsWeb
              ? _pgnTextFromBytes(file.bytes, path, onError: onError)
              : await loadPgnTextForBoard(path, onError: onError);
      if (pgn == null) return false;

      openDetachedPgnTab(
        ref,
        label: localChessFileNameFromPath(path),
        pgn: pgn,
      );
      return true;
    } catch (e) {
      onError?.call(
        'ChessEver couldn\'t open this PGN file. Please try again.',
      );
      if (kDebugMode) debugPrint('⚠️ PgnFilePicker.pickAndLoad: $e');
      return false;
    }
  }
}

@visibleForTesting
Future<String?> loadPgnTextForBoard(
  String path, {
  void Function(String message)? onError,
}) async {
  try {
    final bytes = await readStableLocalChessFileBytesInWorker(path);
    return _pgnTextFromBytes(bytes, path, onError: onError);
  } on LocalChessFileAccessException catch (e) {
    onError?.call(e.userMessage);
    if (kDebugMode) debugPrint('⚠️ loadPgnTextForBoard: $e');
    return null;
  } catch (e) {
    onError?.call('ChessEver couldn\'t open this PGN file. Please try again.');
    if (kDebugMode) debugPrint('⚠️ loadPgnTextForBoard: $e');
    return null;
  }
}

String? _pgnTextFromBytes(
  List<int>? bytes,
  String path, {
  void Function(String message)? onError,
}) {
  final pgn = bytes == null ? '' : utf8.decode(bytes, allowMalformed: true);
  if (pgn.trim().isEmpty) {
    onError?.call(
      'No playable PGN entries were found in '
      '"${localChessFileNameFromPath(path)}".',
    );
    return null;
  }
  return pgn;
}
