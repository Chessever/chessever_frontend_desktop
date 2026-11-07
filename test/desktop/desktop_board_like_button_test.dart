import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/panes/board_pane.dart'
    show
        desktopLikeableBoardGame,
        boardSecondaryToolbarActionsForTesting,
        boardGameToolbarActionsForTesting;
import 'package:chessever/desktop/state/game_like_count.dart';
import 'package:chessever/desktop/widgets/board_like_button.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/desktop/services/likes/community_likes_models.dart'
    show compactLikeCount;
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
  int? Function()? readCount,
  double? railWidth,
}) async {
  final likes = _FakeLikes(liked);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUserProvider.overrideWithValue(user),
        likedGamesProvider.overrideWith(() => likes),
        desktopGameLikeCountProvider.overrideWith(
          (ref, id) async => readCount != null ? readCount() : count,
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child:
                railWidth == null
                    ? DesktopBoardLikeButton(game: _game())
                    : SizedBox(
                      key: const ValueKey('count-test-rail'),
                      width: railWidth,
                      child: boardToolbarForTesting(
                        canGoBack: true,
                        canGoForward: true,
                        onFirst: () {},
                        onPrevious: () {},
                        onNext: () {},
                        onLast: () {},
                        onPlayPause: () {},
                        onPreviousGame: () {},
                        onNextGame: () {},
                        leadingActions: DesktopBoardLikeButton(game: _game()),
                        secondaryActions:
                            boardSecondaryToolbarActionsForTesting(
                              onFlipBoard: () {},
                              onShareGame: () {},
                            ),
                        trailingActions: boardGameToolbarActionsForTesting(
                          onSaveGame: () {},
                          onPlayFromHere: () {},
                        ),
                      ),
                    ),
          ),
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
  testWidgets(
    'Like stays borderless at rest and on hover in both liked states',
    (tester) async {
      for (final liked in [false, true]) {
        await _pump(
          tester,
          user: _member,
          count: 99,
          liked: liked ? [_liked('game-1')] : [],
        );
        final target = find.byKey(const ValueKey('board-like-button'));
        expect(tester.widget<AnimatedContainer>(target).decoration, isNull);
        expect(tester.getSize(target), const Size(40, 40));
        final pointer = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await pointer.addPointer(location: Offset.zero);
        await pointer.moveTo(tester.getCenter(target));
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.widget<AnimatedContainer>(target).decoration, isNull);
        await pointer.removePointer();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      }
    },
  );
  for (final liked in [false, true]) {
    for (final count in [null, 0, 1, 9, 10, 99, 100, 101, 999, 1000, 1000000]) {
      testWidgets('count $count placement with liked=$liked', (tester) async {
        await _pump(
          tester,
          user: _member,
          count: count,
          liked: liked ? [_liked('game-1')] : [],
        );
        await tester.pump(const Duration(milliseconds: 200));
        final heartFinder = find.byIcon(
          liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        );
        final heart = tester.getRect(heartFinder);
        final button = tester.getRect(
          find.byKey(const ValueKey('board-like-button')),
        );
        expect(button.height, 40);
        expect(button.width, greaterThanOrEqualTo(40));
        if (count == null || count == 0) {
          expect(find.byType(Text), findsNothing);
          expect(button.width, 40);
        } else {
          final number = find.text(compactLikeCount(count));
          expect(number, findsOneWidget);
          final bounds = tester.getRect(number);
          if (count < 100) {
            expect(bounds.left, greaterThanOrEqualTo(heart.left));
            expect(bounds.right, lessThanOrEqualTo(heart.right));
            expect(bounds.top, greaterThanOrEqualTo(heart.top));
            expect(bounds.bottom, lessThanOrEqualTo(heart.bottom));
            expect(bounds.center.dx, closeTo(heart.center.dx, 0.1));
            expect(button.width, 40);
          } else {
            expect(bounds.left, greaterThan(heart.right));
            expect(bounds.right, lessThan(button.right));
          }
          final semantics = tester.getSemantics(
            find.byType(DesktopBoardLikeButton),
          );
          expect(semantics.value, count == 1 ? '1 like' : '$count likes');
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      });
    }
  }

  testWidgets(
    'server count crosses 99 and 100 in both directions without recreating the button',
    (tester) async {
      var count = 99;
      await _pump(tester, user: _member, readCount: () => count);
      final button = find.byType(DesktopBoardLikeButton);
      final state = tester.state(button);
      final container = ProviderScope.containerOf(tester.element(button));
      for (final next in [100, 99, 0, 1]) {
        count = next;
        container.invalidate(desktopGameLikeCountProvider('game-1'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.state(button), same(state));
        if (next == 0) {
          expect(find.byType(Text), findsNothing);
        } else {
          final bounds = tester.getRect(find.text('$next'));
          final heart = tester.getRect(
            find.byIcon(Icons.favorite_border_rounded),
          );
          if (next < 100) {
            expect(bounds.center.dx, closeTo(heart.center.dx, 0.1));
          } else {
            expect(bounds.left, greaterThan(heart.right));
          }
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'real Like count fits narrow and wide two-row toolbars with existing utilities',
    (tester) async {
      for (final width in [240.0, 320.0, 400.0, 580.0, 700.0]) {
        for (final count in [99, 100, 1000000]) {
          await _pump(tester, user: _member, count: count, railWidth: width);
          await tester.pump(const Duration(milliseconds: 200));
          final rail = tester.getRect(
            find.byKey(const ValueKey('count-test-rail')),
          );
          final bounds = tester.getRect(
            find.byKey(const ValueKey('board-like-button')),
          );
          expect(bounds.left, greaterThanOrEqualTo(rail.left));
          expect(bounds.right, lessThanOrEqualTo(rail.right));
          expect(find.byIcon(FIcons.bookmarkPlus), findsOneWidget);
          expect(find.byIcon(Icons.sports_esports_outlined), findsOneWidget);
          expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'two-digit like count sits inside the heart without widening its target',
    (tester) async {
      await _pump(tester, user: _member, count: 99);
      final heart = tester.getRect(find.byIcon(Icons.favorite_border_rounded));
      final count = tester.getRect(find.text('99'));
      final button = tester.getRect(
        find.byKey(const ValueKey('board-like-button')),
      );
      expect(count.left, greaterThanOrEqualTo(heart.left));
      expect(count.right, lessThanOrEqualTo(heart.right));
      expect(count.center.dx, closeTo(heart.center.dx, 0.1));
      expect(button.size, const Size(40, 40));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
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
