import 'package:flutter/widgets.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/event_info_popover.dart';

/// Right-click → "Game info" on a local database row: shows every PGN tag the
/// import kept for [game], reusing the board's event-info body so both
/// surfaces render headers identically.
Future<void> showLocalGameInfoDialog(
  BuildContext context,
  LocalChessGame game,
) {
  final headers = <String, String>{
    for (final entry in game.game.metadata.entries)
      entry.key: entry.value?.toString() ?? '',
  };
  return showDesktopDialog<void>(
    context,
    child: Center(
      child: SingleChildScrollView(child: EventInfoBody(headers: headers)),
    ),
  );
}
