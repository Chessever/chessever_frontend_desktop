import 'package:hooks_riverpod/hooks_riverpod.dart';

/// A browser history/direct-link cursor request, consumed once by the board.
class DesktopWebBoardPosition {
  const DesktopWebBoardPosition({this.ply, this.fen, this.flipped = false});
  final int? ply;
  final String? fen;
  final bool flipped;
}

final desktopWebBoardPositionByTabIdProvider =
    StateProvider<Map<String, DesktopWebBoardPosition>>((_) => {});

/// Restore complete local board hooks when browser history revisits a page.
final desktopWebBoardRestorationEpochProvider = StateProvider<Map<String, int>>(
  (_) => {},
);
