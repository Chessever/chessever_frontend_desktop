import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/state/my_prep_profile.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/desktop/widgets/play_post_game_brief.dart';

void main() {
  group('my prep pointer', () {
    ProviderContainer scope(List<PlayerWorkspacePlayer> players, String id) {
      final container = ProviderContainer(
        overrides: [
          myPrepPlayerIdProvider.overrideWith((ref) => _Pointer(id)),
          playerWorkspaceProvider.overrideWith((ref) => _Workspace(players)),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a profile with a source left is the own profile', () {
      final container = scope([
        const PlayerWorkspacePlayer(
          id: 'me',
          displayName: 'Berkay Can',
          createdAtMs: 0,
          accounts: {
            PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
              source: PlayerWorkspaceSource.lichess,
              username: 'devberkay',
            ),
          },
        ),
      ], 'me');
      expect(container.read(myPrepPlayerIdIfPresentProvider), 'me');
    });

    test('a profile emptied of every source reads as unlinked', () {
      // Picked by mistake (a GM's ChessEver record), then detached: the
      // shell keeps his name, but must not stay pinned as the reader's own.
      final container = scope([
        const PlayerWorkspacePlayer(
          id: 'gm',
          displayName: 'Vasif Durarbayli',
          createdAtMs: 0,
          title: 'GM',
        ),
      ], 'gm');
      expect(container.read(myPrepPlayerIdIfPresentProvider), isNull);
    });
  });

  group('post-game brief', () {
    const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    const blackFirst =
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

    test('a move belongs to the side that made it', () {
      expect(playBriefIsHumanMove(0, start, Side.white), isTrue);
      expect(playBriefIsHumanMove(1, start, Side.white), isFalse);
      // From a black-to-move start, the first move is Black's.
      expect(playBriefIsHumanMove(0, blackFirst, Side.black), isTrue);
      expect(playBriefIsHumanMove(1, blackFirst, Side.black), isFalse);
    });

    test('only the player\'s own marks are counted', () {
      final counts = playBriefMarkCounts(
        const {
          0: GameMoveClassification.bookMove,
          1: GameMoveClassification.bookMove,
          2: GameMoveClassification.blunder,
          4: GameMoveClassification.brilliant,
          5: GameMoveClassification.mistake,
        },
        startingFen: start,
        humanSide: Side.white,
      );
      expect(counts, {
        GameMoveClassification.bookMove: 1,
        GameMoveClassification.blunder: 1,
        GameMoveClassification.brilliant: 1,
      });
    });

    test('the rating change is read from the rating before the game', () {
      const rating = PlayFinishedRating(
        ladder: 'Blitz',
        before: 1500,
        after: 1484,
      );
      expect(rating.delta, -16);
    });
  });
}

class _Pointer extends StateNotifier<AsyncValue<String?>>
    implements MyPrepPlayerIdNotifier {
  _Pointer(String id) : super(AsyncValue.data(id));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Workspace extends StateNotifier<PlayerWorkspaceState>
    implements PlayerWorkspaceNotifier {
  _Workspace(List<PlayerWorkspacePlayer> players)
    : super(PlayerWorkspaceState(players: players));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
