import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/tournament_games.dart';

void main() {
  test('detached Board and rail retain independent exact revisions', () {
    const origin = BoardTabLibrarySaveOrigin.localPgnFile(
      sourcePath: 'fixture.pgn',
      sourceIndex: 0,
      sourceFileGameCount: 2,
      sourcePgnFingerprint: 'dedupe',
      sourceRecordRevision: 'exact-original',
      title: 'Fixture',
    );
    const args = BoardTabGameArgs(
      pgn: '1. e4 *',
      label: 'Fixture',
      whiteName: 'White',
      blackName: 'Black',
      librarySaveOrigin: origin,
      databaseGames: [
        TournamentGameSummary(
          id: 'neighbor',
          name: 'Neighbor',
          whitePlayer: 'White',
          blackPlayer: 'Black',
          hasPgn: true,
          localPgnSource: TournamentGameLocalPgnSource(
            sourcePath: 'fixture.pgn',
            sourceIndex: 1,
            sourceFileGameCount: 2,
            pgnFingerprint: 'dedupe',
            recordRevision: 'exact-neighbor',
            title: 'Neighbor',
          ),
        ),
      ],
    );
    final payload = DesktopBoardWindowPayload.fromArgs(args);
    final restored =
        DesktopBoardWindowPayload.fromJson(
          Map<String, Object?>.from(jsonDecode(payload.encode()) as Map),
        ).args!;
    expect(restored.librarySaveOrigin!.sourceRecordRevision, 'exact-original');
    expect(
      restored.databaseGames.single.localPgnSource!.recordRevision,
      'exact-neighbor',
    );
    const changed = BoardTabLibrarySaveOrigin.localPgnFile(
      sourcePath: 'fixture.pgn',
      sourceIndex: 0,
      sourceFileGameCount: 2,
      sourcePgnFingerprint: 'dedupe',
      sourceRecordRevision: 'exact-new',
      title: 'Fixture',
    );
    expect(
      shouldAcceptRefreshedLocalPgnOrigin(
        updatingOrigin: origin,
        currentSourceOrigin: changed,
        currentAttachedOrigin: null,
      ),
      isFalse,
    );
  });
}
