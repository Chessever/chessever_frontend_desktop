import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/board_pane.dart'
    show desktopLikeableBoardGame;
import 'package:chessever/desktop/state/game_like_count.dart';
import 'package:chessever/desktop/widgets/board_like_button.dart';
import 'package:chessever/providers/auth_state_provider.dart';
import 'package:chessever/repository/authentication/model/app_user.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/repository/liked_games/liked_games_provider.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

const _pgn =
    '[White "Carlsen, Magnus"]\n[Black "Caruana, Fabiano"]\n'
    '[Result "1-0"]\n\n1. e4 e5 2. Nf3 1-0\n';

GamesTourModel _game({
  String id = 'game-1',
  GameSource source = GameSource.supabase,
}) => GamesTourModel(
  gameId: id,
  source: source,
  whitePlayer: PlayerCard(
    name: 'Carlsen, Magnus',
    federation: 'NOR',
    title: 'GM',
    rating: 2830,
    countryCode: 'NOR',
    team: null,
  ),
  blackPlayer: PlayerCard(
    name: 'Caruana, Fabiano',
    federation: 'USA',
    title: 'GM',
    rating: 2800,
    countryCode: 'USA',
    team: null,
  ),
  whiteTimeDisplay: '--:--',
  blackTimeDisplay: '--:--',
  whiteClockCentiseconds: 0,
  blackClockCentiseconds: 0,
  gameStatus: GameStatus.whiteWins,
  roundId: 'r',
  tourId: 't',
);

SavedAnalysis _liked(String likeId) => SavedAnalysis(
  id: 'row-$likeId',
  userId: 'user-1',
  folderId: 'likes',
  title: 'Carlsen vs Caruana',
  sourceGameId: likeId,
  chessGame: ChessGame.fromPgn(likeId, _pgn),
  analysisState: const <String, dynamic>{},
  variationComments: const <String, String>{},
  lastViewedPosition: -1,
  tags: const <String>[],
  isFavorite: false,
  createdAt: DateTime(2026, 11, 4),
  updatedAt: DateTime(2026, 11, 4),
);

/// Likes kept in memory; [toggle] flips one game the way the real notifier
/// leaves its state.
class _FakeLikes extends LikedGamesNotifier {
  _FakeLikes([this._initial = const []]);

  final List<SavedAnalysis> _initial;
  int toggles = 0;

  @override
  Future<List<SavedAnalysis>> build() async => _initial;

  @override
  Future<bool> toggle(GamesTourModel game) async {
    toggles++;
    final list = [...state.requireValue];
    final had = list.any((a) => a.sourceGameId == game.likeId);
    if (had) {
      list.removeWhere((a) => a.sourceGameId == game.likeId);
    } else {
      list.insert(0, _liked(game.likeId));
    }
    state = AsyncValue.data(list);
    return !had;
  }
}

Future<_FakeLikes> _pump(
  WidgetTester tester, {
  AppUser? user,
  List<SavedAnalysis> liked = const [],
  int? count,
}) async {
  final likes = _FakeLikes(liked);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUserProvider.overrideWithValue(user),
        likedGamesProvider.overrideWith(() => likes),
        desktopGameLikeCountProvider.overrideWith((ref, id) async => count),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(child: DesktopBoardLikeButton(game: _game())),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return likes;
}

final _member = AppUser(id: 'user-1', createdAt: DateTime(2026));

void main() {
  testWidgets('Tab, Enter and Space can operate the board like', (
    tester,
  ) async {
    final likes = await _pump(tester, user: _member);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(likes.toggles, 1);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(likes.toggles, 2);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a signed-in member likes and unlikes from the board', (
    tester,
  ) async {
    final likes = await _pump(tester, user: _member, count: 41);

    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(find.text('41'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('board-like-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(likes.toggles, 1);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('board-like-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(likes.toggles, 2);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an already liked game reads as liked', (tester) async {
    await _pump(tester, user: _member, liked: [_liked('game-1')]);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    // No count yet: a plain heart, no number.
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('a guest is asked to sign in and nothing is written', (
    tester,
  ) async {
    final likes = await _pump(
      tester,
      user: AppUser(id: 'anon-1', createdAt: DateTime(2026), isAnonymous: true),
    );

    await tester.tap(find.byKey(const ValueKey('board-like-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Sign in to like games'), findsOneWidget);
    expect(likes.toggles, 0);

    await tester.tap(find.text('Not now'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(likes.toggles, 0);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  test('like count parses numbers and numeric strings', () {
    expect(parseDesktopGameLikeCount(12), 12);
    expect(parseDesktopGameLikeCount('7'), 7);
    expect(parseDesktopGameLikeCount(3.0), 3);
    expect(parseDesktopGameLikeCount(-1), isNull);
    expect(parseDesktopGameLikeCount('x'), isNull);
    expect(parseDesktopGameLikeCount(null), isNull);
  });

  test('only the phone-likeable sources get a board Like', () {
    for (final source in [
      GameSource.supabase,
      GameSource.gamebase,
      GameSource.twic,
      GameSource.savedAnalysis,
    ]) {
      expect(desktopLikeableBoardGame(_game(source: source)), isNotNull);
    }
    for (final source in [GameSource.boardEditor, GameSource.openingExplorer]) {
      expect(desktopLikeableBoardGame(_game(source: source)), isNull);
    }
    expect(desktopLikeableBoardGame(null), isNull);
  });
}
