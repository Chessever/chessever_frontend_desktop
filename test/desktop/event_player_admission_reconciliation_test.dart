import 'dart:io';
import 'package:chessever/desktop/panes/board_pane.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:flutter_test/flutter_test.dart';

import 'event_player_board_scope_test.dart' as fixture;

void main() {
  test('source-only favorites do not silently acquire event history', () {
    expect(boardPlayerHistoryKey(
      eventKey: null, eventGames: const [], playerName: 'Player', fideId: null,
      ownerId: 'favorites', sourceGame: fixture.model(1),
    ), isNull);
    expect(boardPlayerHistoryKey(
      eventKey: null, eventGames: const [], playerName: 'Player', fideId: null,
      ownerId: 'event', sourceGame: fixture.model(1), allowSourceFallback: true,
    ), isNotNull);
  });

  test('restored scope and keyboard activation stay wired', () {
    final board = File('lib/desktop/panes/board_pane.dart').readAsStringSync();
    final hover = File('lib/desktop/widgets/player_hover_preview.dart').readAsStringSync();
    expect(board, contains('args.eventPlayerScope != null ||'));
    expect(board, contains('allowSourceFallback: _canOpenEventPlayerGames'));
    expect(hover, contains('FocusableActionDetector('));
    expect(hover, contains('SingleActivator(LogicalKeyboardKey.enter)'));
    expect(hover, contains('SingleActivator(LogicalKeyboardKey.space)'));
  });

  test('ordinary event-player subset stays broadcast, not global profile', () {
    final args = buildTournamentBoardTabArgs(
      fixture.model(1), 'Event A', eventPlayerScope: fixture.scope(),
    );
    expect(args.admissionContext.feature, DesktopFeature.broadcast);
    expect(args.admissionContext.origin, DesktopDiscoveryOrigin.broadcast);
    expect(args.eventGamesKey, isNull);
  });

  test('paid provenance and player scope survive copy and detach together', () {
    const paid = DesktopAccessContext(
      feature: DesktopFeature.countrymen,
      action: DesktopAction.openContent,
      origin: DesktopDiscoveryOrigin.countrymen,
    );
    final args = buildTournamentBoardTabArgs(
      fixture.model(1), 'Event A', eventPlayerScope: fixture.scope(),
      accessContext: paid,
    ).copyWith(label: 'Player · Event A');
    final payload = DesktopBoardWindowPayload(
      title: args.label, kind: TabKind.board, args: args,
    );
    final restored = DesktopBoardWindowPayload.fromJson(payload.toJson()).args!;
    expect(restored.admissionContext.feature, DesktopFeature.countrymen);
    expect(restored.sourceAccessContext.ownedDocument, isFalse);
    expect(restored.eventPlayerScope.toString(), args.eventPlayerScope.toString());
  });

  test('compact and full card source propagation stays explicit', () {
    final board = File('lib/desktop/panes/board_pane.dart').readAsStringSync();
    final card = File('lib/desktop/widgets/player_score_card_view.dart').readAsStringSync();
    expect(board, contains('accessContext: args.sourceAccessContext'));
    expect(board, contains('accessContext: boardArgs?.sourceAccessContext'));
    expect(card, contains('accessContext: tabContext?.accessContext'));
    expect(card, contains('accessContext: widget.tabContext?.accessContext'));
  });
}
