import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_board_game.dart';

/// Open the OS file dialog for picking a `.pgn`, read it from disk, and
/// open it as a detached Board tab.
///
/// Used by the command palette ("Open PGN on Board…", ⌘O) and any "Open
/// file" affordance the panes add later. Returns `true` if a file was loaded.
class PgnFilePicker {
  PgnFilePicker(this.ref);
  final WidgetRef ref;

  Future<bool> pickAndLoad() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Open PGN',
        type: FileType.custom,
        allowedExtensions: const ['pgn'],
        allowMultiple: false,
        withData: false,
      );
      if (result == null || result.files.isEmpty) return false;
      final path = result.files.single.path;
      if (path == null) return false;

      final pgn = await File(path).readAsString();
      if (pgn.trim().isEmpty) return false;

      openDetachedPgnTab(ref, label: _fileName(path), pgn: pgn);
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ PgnFilePicker.pickAndLoad: $e');
      return false;
    }
  }
}

String _fileName(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  return parts.isEmpty ? path : parts.last;
}
