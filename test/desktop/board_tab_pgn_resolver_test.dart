import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/board_tab_pgn_resolver.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';

void main() {
  group('resolveBoardTabPgn', () {
    test('keeps an initial PGN that already has moves', () async {
      var supabaseCalls = 0;
      var gamebaseCalls = 0;

      final resolved = await resolveBoardTabPgn(
        gameId: 'game-1',
        initialPgn: '1. e4 e5 *',
        fetchSupabasePgn: (_) async {
          supabaseCalls++;
          return null;
        },
        fetchGamebaseGameWithPgn: (_) async {
          gamebaseCalls++;
          return null;
        },
      );

      expect(resolved, '1. e4 e5 *');
      expect(supabaseCalls, 0);
      expect(gamebaseCalls, 0);
    });

    test('hydrates a header-only Gamebase tab from structured data', () async {
      final resolved = await resolveBoardTabPgn(
        gameId: 'gamebase-1',
        initialPgn: '[White "Alpha"]\n[Black "Beta"]\n\n*',
        fetchSupabasePgn: (_) async => throw Exception('not in Supabase'),
        fetchGamebaseGameWithPgn:
            (_) async => _gamebaseGame(
              data: const {
                'md': {'White': 'Alpha', 'Black': 'Beta', 'Result': '1-0'},
                'm': [
                  {'u': 'e2e4'},
                  {'u': 'e7e5'},
                  {'u': 'g1f3'},
                ],
              },
              pgn: null,
            ),
      );

      expect(pgnHasMoves(resolved), isTrue);
      expect(resolved, contains('1. e4 e5'));
      expect(resolved, contains('2. Nf3'));
    });

    test('uses Supabase PGN before Gamebase when Supabase has moves', () async {
      final resolved = await resolveBoardTabPgn(
        gameId: 'live-1',
        fetchSupabasePgn: (_) async => '1. d4 Nf6 *',
        fetchGamebaseGameWithPgn:
            (_) async => _gamebaseGame(
              data: const {
                'm': [
                  {'u': 'e2e4'},
                ],
              },
              pgn: null,
            ),
      );

      expect(resolved, '1. d4 Nf6 *');
    });

    test('returns the best header fallback when no source has moves', () async {
      final resolved = await resolveBoardTabPgn(
        gameId: 'gamebase-empty',
        initialPgn: '[White "Alpha"]\n[Black "Beta"]\n\n*',
        fetchSupabasePgn: (_) async => null,
        fetchGamebaseGameWithPgn:
            (_) async => _gamebaseGame(
              data: const {'m': <Object>[]},
              pgn: '[White "Gamma"]\n[Black "Delta"]\n\n*',
            ),
      );

      expect(resolved, '[White "Alpha"]\n[Black "Beta"]\n\n*');
      expect(pgnHasMoves(resolved), isFalse);
    });
  });
}

GamebaseGameWithPgn _gamebaseGame({
  required Map<String, dynamic>? data,
  required String? pgn,
}) {
  return GamebaseGameWithPgn(
    id: 'gamebase-1',
    date: DateTime(2024),
    result: GameResult.whiteWins,
    timeControl: TimeControl.classical,
    data: data,
    pgn: pgn,
  );
}
