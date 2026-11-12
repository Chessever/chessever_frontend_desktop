import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:chessever/desktop/services/desktop_like_actions.dart';
import 'package:flutter/services.dart';
import 'package:chessever/providers/auth_state_provider.dart';
import 'package:chessever/repository/authentication/model/app_user.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/screens/chessboard/models/like_tag.dart';
import 'package:chessever/repository/liked_games/liked_games_provider.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

GamesTourModel _game(String id) => GamesTourModel(
  gameId: id,
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

SavedAnalysis _row(String id, {List<String> tags = const []}) => SavedAnalysis(
  id: 'row-$id',
  userId: 'user-1',
  folderId: 'likes',
  title: 'Carlsen vs Caruana',
  sourceGameId: id,
  chessGame: ChessGame.fromPgn(id, '1. e4 e5 2. Nf3 Nc6 *'),
  analysisState: const {},
  variationComments: const {},
  lastViewedPosition: -1,
  tags: tags,
  isFavorite: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

class _Likes extends LikedGamesNotifier {
  _Likes({this.initial = const [], this.failLike = false});
  final List<SavedAnalysis> initial;
  final bool failLike;
  final writes = <(String, List<String>)>[];
  bool failTags = false;
  bool throwTags = false;
  Completer<bool>? tagsGate;

  void seedTags(String id, List<String> tags) {
    state = AsyncData([
      for (final row in state.requireValue)
        if (row.sourceGameId == id) row.copyWith(tags: tags) else row,
    ]);
  }

  @override
  Future<List<SavedAnalysis>> build() async => initial;

  @override
  Future<bool> toggle(GamesTourModel game) async {
    final had = isLiked(game.likeId);
    if (failLike) return had;
    state = AsyncData(
      had
          ? state.requireValue
              .where((r) => r.sourceGameId != game.likeId)
              .toList()
          : [_row(game.likeId), ...state.requireValue],
    );
    return !had;
  }

  @override
  Future<bool> setTagsForLikeId(String id, List<String> tags) async {
    writes.add((id, List.of(tags)));
    if (throwTags) throw StateError('Tag write unavailable');
    if (failTags) return false;
    if (tagsGate != null && !await tagsGate!.future) return false;
    state = AsyncData([
      for (final r in state.requireValue)
        if (r.sourceGameId == id) r.copyWith(tags: tags) else r,
    ]);
    return true;
  }
}

final _captureKey = GlobalKey();

Future<ProviderContainer> _pump(WidgetTester tester, _Likes likes) async {
  final container = ProviderContainer(
    overrides: [
      currentUserProvider.overrideWithValue(
        AppUser(id: 'user-1', createdAt: DateTime(2026)),
      ),
      likedGamesProvider.overrideWith(() => likes),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _captureKey,
      child: UncontrolledProviderScope(
        container: container,
        child: FTheme(
          data: FThemes.zinc.dark,
          child: FToaster(
            child: MaterialApp(
              theme: ThemeData.dark().copyWith(
                textTheme: ThemeData.dark().textTheme.apply(
                  fontFamily: FThemes.zinc.dark.typography.defaultFontFamily,
                ),
              ),
              home: Scaffold(
                body: Consumer(
                  builder:
                      (context, ref, _) => Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final id in ['g1', 'g2'])
                              TextButton(
                                onPressed:
                                    () => toggleDesktopGameLike(
                                      context: context,
                                      ref: ref,
                                      game: _game(id),
                                    ),
                                child: Text('like $id'),
                              ),
                          ],
                        ),
                      ),
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
  return container;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _cleanup(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
}

void main() {
  testWidgets('two-column picker shows every larger tag without scrolling', (
    tester,
  ) async {
    final likes = _Likes();
    await _pump(tester, likes);
    await tester.tap(find.text('like g1'));
    await _settle(tester);
    await tester.tap(find.text('Tag this game'));
    await _settle(tester);
    final choices = find.byType(FCheckbox);
    final first = tester.getRect(choices.at(0));
    final second = tester.getRect(choices.at(1));
    final third = tester.getRect(choices.at(2));
    expect(second.top, closeTo(first.top, 1));
    expect(second.left, greaterThan(first.right));
    expect(third.left, closeTo(first.left, 1));
    expect(third.top, greaterThan(first.bottom));
    final picker = tester.getRect(
      find.byKey(const ValueKey('like-tag-picker')),
    );
    for (final tag in kLikeTags) {
      final label = find.text(tag.label);
      expect(label.hitTestable(), findsOneWidget);
      final rect = tester.getRect(label);
      expect(picker.contains(rect.topLeft), isTrue);
      expect(picker.contains(rect.bottomRight), isTrue);
      final checkboxFinder = find.ancestor(of: label, matching: choices);
      final checkbox = tester.widget<FCheckbox>(checkboxFinder);
      expect(
        (checkbox.label! as Text).style!.fontSize,
        greaterThanOrEqualTo(14),
      );
      final style =
          checkbox.style?.call(FThemes.zinc.dark.checkboxStyle) ??
          FThemes.zinc.dark.checkboxStyle;
      expect(style.size, greaterThanOrEqualTo(20));
      expect(tester.getSize(checkboxFinder).height, greaterThanOrEqualTo(40));
    }
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('like-tag-picker')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.maxScrollExtent, 0);
    expect(find.text('Save').hitTestable(), findsOneWidget);
    expect(find.text('Cancel').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _cleanup(tester);
  });

  testWidgets('tag choices use text labels without decorative pictures', (
    tester,
  ) async {
    final likes = _Likes();
    await _pump(tester, likes);
    await tester.tap(find.text('like g1'));
    await _settle(tester);
    await tester.tap(find.text('Tag this game'));
    await _settle(tester);
    final choices =
        tester.widgetList<FCheckbox>(find.byType(FCheckbox)).toList();
    expect(choices, hasLength(kLikeTags.length));
    for (final choice in choices) {
      expect(choice.label, isA<Text>());
    }
    expect(
      choices.map((choice) => (choice.label! as Text).data),
      kLikeTags.map((tag) => tag.label),
    );
    expect(likes.writes, isEmpty);
    await _cleanup(tester);
  });

  setUpAll(() async {
    final font = FontLoader(FThemes.zinc.dark.typography.defaultFontFamily)
      ..addFont(
        rootBundle.load('packages/forui/assets/fonts/inter/Inter-Regular.ttf'),
      );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final foruiIcons = FontLoader('packages/forui_assets/ForuiLucideIcons')
      ..addFont(rootBundle.load('packages/forui_assets/assets/lucide.ttf'));
    await foruiIcons.load();
  });

  testWidgets(
    'ignoring the offer expires without changing the like or its tags',
    (tester) async {
      final likes = _Likes();
      await _pump(tester, likes);
      await tester.tap(find.text('like g1'));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 6));
      await _settle(tester);
      expect(find.text('Tag this game'), findsNothing);
      expect(likes.isLiked('g1'), isTrue);
      expect(likes.writes, isEmpty);
      await _cleanup(tester);
    },
  );

  testWidgets('a failed like never offers tagging', (tester) async {
    final likes = _Likes(failLike: true);
    await _pump(tester, likes);
    await tester.tap(find.text('like g1'));
    await _settle(tester);
    expect(find.text('Tag this game'), findsNothing);
    expect(find.text("Couldn't like this game."), findsOneWidget);
    await _cleanup(tester);
  });

  testWidgets('unliking keeps the original feedback without a new tag offer', (
    tester,
  ) async {
    final likes = _Likes(
      initial: [
        _row('g1', tags: ['Opening']),
      ],
    );
    await _pump(tester, likes);
    await tester.tap(find.text('like g1'));
    await _settle(tester);
    expect(find.text('Removed from My Likes'), findsOneWidget);
    expect(find.text('Tag this game'), findsNothing);
    expect(likes.writes, isEmpty);
    await _cleanup(tester);
  });

  testWidgets(
    'existing and legacy tags are read at open and Cancel writes nothing',
    (tester) async {
      final likes = _Likes();
      await _pump(tester, likes);
      await tester.tap(find.text('like g1'));
      await _settle(tester);
      likes.seedTags('g1', ['Opening', 'Legacy tag']);
      await tester.tap(find.text('Tag this game'));
      await _settle(tester);
      expect(
        tester.widget<FCheckbox>(find.byType(FCheckbox).first).value,
        isTrue,
      );
      await tester.tap(find.text('Wild Game'));
      await tester.tap(find.text('Cancel'));
      await _settle(tester);
      expect(likes.writes, isEmpty);
      expect(likes.state.requireValue.single.tags, ['Opening', 'Legacy tag']);
      expect(find.text('Save'), findsNothing);
      await _cleanup(tester);
    },
  );

  testWidgets(
    'Save preserves unknown legacy labels and can clear selected official tags',
    (tester) async {
      final likes = _Likes();
      await _pump(tester, likes);
      await tester.tap(find.text('like g1'));
      await _settle(tester);
      likes.seedTags('g1', ['Opening', 'Legacy tag']);
      await tester.tap(find.text('Tag this game'));
      await _settle(tester);
      await tester.tap(find.text('Opening'));
      await tester.tap(find.text('Save'));
      await _settle(tester);
      expect(likes.writes.single.$2, ['Legacy tag']);
      await _cleanup(tester);
    },
  );

  testWidgets('an empty selection is saved as a deliberate clear', (
    tester,
  ) async {
    final likes = _Likes();
    await _pump(tester, likes);
    await tester.tap(find.text('like g1'));
    await _settle(tester);
    likes.seedTags('g1', ['Opening']);
    await tester.tap(find.text('Tag this game'));
    await _settle(tester);
    await tester.tap(find.text('Opening'));
    await tester.tap(find.text('Save'));
    await _settle(tester);
    expect(likes.writes.single.$2, isEmpty);
    await _cleanup(tester);
  });

  testWidgets(
    'false save result keeps a retryable draft and never reports success',
    (tester) async {
      final likes = _Likes()..failTags = true;
      await _pump(tester, likes);
      await tester.tap(find.text('like g1'));
      await _settle(tester);
      await tester.tap(find.text('Tag this game'));
      await _settle(tester);
      await tester.tap(find.text('Opening'));
      await tester.tap(find.text('Save'));
      await _settle(tester);
      expect(find.text("Couldn't save tags. Try again."), findsOneWidget);
      expect(find.text('Tags saved'), findsNothing);
      likes.failTags = false;
      await tester.tap(find.text('Save'));
      await _settle(tester);
      expect(likes.writes.last.$2, ['Opening']);
      await _cleanup(tester);
    },
  );

  testWidgets(
    'editing and a slow Save outlive the offer timeout and deduplicate clicks',
    (tester) async {
      final gate = Completer<bool>();
      final likes = _Likes()..tagsGate = gate;
      await _pump(tester, likes);
      await tester.tap(find.text('like g1'));
      await _settle(tester);
      await tester.tap(find.text('Tag this game'));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 8));
      expect(find.text('Save'), findsOneWidget);
      await tester.tap(find.text('Opening'));
      await tester.tap(find.text('Save'));
      await _settle(tester);
      expect(find.text('Saving…'), findsOneWidget);
      await tester.tap(find.text('Saving…'));
      await tester.pump(const Duration(seconds: 8));
      expect(likes.writes, hasLength(1));
      gate.complete(true);
      await _settle(tester);
      expect(find.text('Tags saved'), findsOneWidget);
      await _cleanup(tester);
    },
  );

  testWidgets('Escape dismisses keyboard-selected draft without saving', (
    tester,
  ) async {
    final likes = _Likes();
    await _pump(tester, likes);
    await tester.tap(find.text('like g1'));
    await _settle(tester);
    await tester.tap(find.text('Tag this game'));
    await _settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await _settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _settle(tester);
    expect(
      tester.widgetList<FCheckbox>(find.byType(FCheckbox)).any((c) => c.value),
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.text('Save'), findsNothing);
    expect(likes.writes, isEmpty);
    await _cleanup(tester);
  });

  testWidgets('short narrow view keeps Save visible and every tag scrollable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final likes = _Likes();
    await _pump(tester, likes);
    await tester.tap(find.text('like g1'));
    await _settle(tester);
    await tester.tap(find.text('Tag this game'));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    final rect = tester.getRect(find.byKey(const ValueKey('like-tag-picker')));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(360));
    expect(rect.bottom, lessThanOrEqualTo(320));
    expect(find.text('Save').hitTestable(), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('Blunder'),
      find.byType(SingleChildScrollView),
      const Offset(0, -80),
    );
    await tester.tap(find.text('Blunder'));
    await tester.tap(find.text('Save'));
    await _settle(tester);
    expect(likes.writes.single.$2, ['Blunder']);
    await _cleanup(tester);
  });

  testWidgets(
    'a later like and picker save still target the exact original game id',
    (tester) async {
      // Keep the unrelated game's trigger outside the wider popover.
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final likes = _Likes();
      await _pump(tester, likes);
      await tester.tap(find.text('like g1'));
      await _settle(tester);
      await tester.tap(find.text('Tag this game'));
      await _settle(tester);
      await tester.tap(find.text('like g2'));
      await _settle(tester);
      await tester.tap(find.text('Tag this game'));
      await _settle(tester);
      await tester.tap(find.text('Opening'));
      await tester.tap(find.text('Save'));
      await _settle(tester);
      expect(likes.writes.single.$1, 'g2');
      expect(
        likes.state.requireValue.firstWhere((r) => r.sourceGameId == 'g1').tags,
        isEmpty,
      );
      await _cleanup(tester);
    },
  );

  testWidgets('render source widget preview', (tester) async {
    final output = Platform.environment['CHESSEVER_LIKE_TAG_PREVIEW_DIR'];
    if (output == null) return;
    final likes = _Likes();
    await _pump(tester, likes);
    await tester.tap(find.text('like g1'));
    await _settle(tester);
    await tester.tap(find.text('Tag this game'));
    await _settle(tester);
    await tester.tap(find.text('Opening'));
    await tester.tap(find.text('Wild Game'));
    await _settle(tester);
    final boundary =
        _captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$output/like-tags-source-widget.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await _cleanup(tester);
  });

  testWidgets(
    'a thrown tag failure is shown and can be retried without losing the draft',
    (tester) async {
      final likes = _Likes()..throwTags = true;
      await _pump(tester, likes);
      await tester.tap(find.text('like g1'));
      await _settle(tester);
      await tester.tap(find.text('Tag this game'));
      await _settle(tester);
      await tester.tap(find.text('Opening'));
      await tester.tap(find.text('Save'));
      await _settle(tester);
      expect(find.text("Couldn't save tags. Try again."), findsOneWidget);
      expect(find.text('Tags saved'), findsNothing);
      likes.throwTags = false;
      await tester.tap(find.text('Save'));
      await _settle(tester);
      expect(likes.writes.last.$2, ['Opening']);
      expect(find.text('Tags saved'), findsOneWidget);
      await _cleanup(tester);
    },
  );

  testWidgets('an open picker closes when the account changes', (tester) async {
    final likes = _Likes();
    final container = await _pump(tester, likes);
    await tester.tap(find.text('like g1'));
    await _settle(tester);
    await tester.tap(find.text('Tag this game'));
    await _settle(tester);
    expect(find.text('Save'), findsOneWidget);
    container.updateOverrides([
      currentUserProvider.overrideWithValue(
        AppUser(id: 'user-2', createdAt: DateTime(2026)),
      ),
      likedGamesProvider.overrideWith(() => likes),
    ]);
    await _settle(tester);
    expect(find.text('Save'), findsNothing);
    expect(likes.writes, isEmpty);
    await _cleanup(tester);
  });

  testWidgets('an open picker closes when its game is unliked elsewhere', (
    tester,
  ) async {
    final likes = _Likes();
    await _pump(tester, likes);
    await tester.tap(find.text('like g1'));
    await _settle(tester);
    await tester.tap(find.text('Tag this game'));
    await _settle(tester);
    await likes.toggle(_game('g1'));
    await _settle(tester);
    expect(find.text('Save'), findsNothing);
    expect(likes.writes, isEmpty);
    await _cleanup(tester);
  });

  testWidgets('the picker keeps multiple choices as a draft until Save', (
    tester,
  ) async {
    final likes = _Likes();
    await _pump(tester, likes);
    await tester.tap(find.text('like g1'));
    await _settle(tester);
    await tester.tap(find.text('Tag this game'));
    await _settle(tester);
    await tester.tap(find.text('Opening'));
    await _settle(tester);
    expect(likes.writes, isEmpty);
    expect(find.text('Save'), findsOneWidget);
    await tester.tap(find.text('Wild Game'));
    await _settle(tester);
    await tester.tap(find.text('Save'));
    await _settle(tester);
    expect(likes.writes, hasLength(1));
    expect(likes.writes.single.$1, 'g1');
    expect(likes.writes.single.$2, ['Opening', 'Wild Game']);
    expect(find.text('Tags saved'), findsOneWidget);
    await _cleanup(tester);
  });

  testWidgets(
    'a successful like offers optional tagging without opening the picker',
    (tester) async {
      final likes = _Likes();
      await _pump(tester, likes);
      await tester.tap(find.text('like g1'));
      await _settle(tester);
      expect(find.text('Added to My Likes'), findsOneWidget);
      expect(find.text('Tag this game'), findsOneWidget);
      expect(find.text('Sacrifice'), findsNothing);
      expect(likes.writes, isEmpty);
      await _cleanup(tester);
    },
  );
}
