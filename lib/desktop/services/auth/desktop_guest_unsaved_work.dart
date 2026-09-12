import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/board_unsaved_analysis_guard.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;

/// A board tab holding analysis that has not been saved anywhere yet.
@immutable
class DesktopUnsavedBoard {
  const DesktopUnsavedBoard({
    required this.tabId,
    required this.title,
    required this.pgn,
  });

  final String tabId;
  final String title;
  final String pgn;
}

/// Collects every board tab with unsaved analysis, preferring the mounted
/// pane's live reader because the retained session can lag the latest edit.
///
/// Read-only: nothing here closes a tab or clears a session.
List<DesktopUnsavedBoard> collectDesktopUnsavedBoards({
  required Map<String, BoardPaneSession> retainedSessions,
  required Map<String, ({Object? seed, BoardPaneSession session}) Function()>
  liveReaders,
  required Map<String, String> titlesByTabId,
}) {
  final tabIds = <String>{...retainedSessions.keys, ...liveReaders.keys};
  final result = <DesktopUnsavedBoard>[];
  for (final tabId in tabIds) {
    BoardPaneSession? session;
    final reader = liveReaders[tabId];
    if (reader != null) {
      try {
        session = reader().session;
      } catch (_) {
        session = null;
      }
    }
    session ??= retainedSessions[tabId];
    if (!boardSessionHasUnsavedAnalysis(session)) continue;
    final pgn = exportGameToPgn(session!.game).trim();
    if (pgn.isEmpty) continue;
    final title = titlesByTabId[tabId]?.trim();
    result.add(
      DesktopUnsavedBoard(
        tabId: tabId,
        title: title == null || title.isEmpty ? 'Board' : title,
        pgn: pgn,
      ),
    );
  }
  return result;
}

/// One PGN file holding every unsaved board, games separated by a blank line.
String combineDesktopUnsavedBoardsPgn(List<DesktopUnsavedBoard> boards) {
  return '${boards.map((board) => board.pgn.trim()).join('\n\n')}\n';
}

/// Asks where to write the unsaved boards and writes them. Returns the written
/// path, or `null` when the user cancelled the save dialog.
Future<String?> exportDesktopUnsavedBoards(
  List<DesktopUnsavedBoard> boards,
) async {
  if (boards.isEmpty) return null;
  final destination = await FilePicker.platform.saveFile(
    dialogTitle: 'Export unsaved analysis as PGN',
    fileName: 'chessever-unsaved-analysis.pgn',
    type: FileType.custom,
    allowedExtensions: const ['pgn'],
  );
  if (destination == null) return null;
  final outPath =
      destination.toLowerCase().endsWith('.pgn')
          ? destination
          : '$destination.pgn';
  await File(
    outPath,
  ).writeAsString(combineDesktopUnsavedBoardsPgn(boards), flush: true);
  return outPath;
}
