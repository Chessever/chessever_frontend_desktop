import 'package:chessever/desktop/widgets/desktop_explorer_filters.dart';
import 'package:chessever/desktop/widgets/editable_aware_shortcut_activator.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets(
    'scoped player tree keeps the player fixed and exposes all axes',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              backgroundColor: kBackgroundColor,
              body: Builder(builder: _scopedDesktopExplorerFiltersHarness),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('GM Matthias Bluebaum'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Search opponents (min 2 chars)'), findsOneWidget);
      for (final label in <String>[
        'TIME CONTROL',
        'LEVEL',
        'RESULT',
        'FORMAT',
        'PLAYED AS',
        'RATING RANGE',
        'YEAR RANGE',
        'PLAYER',
        'OPPONENT',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    },
  );

  testWidgets('opponent search typing does not invoke background shortcuts', (
    tester,
  ) async {
    var engineToggleCount = 0;
    final repository = _FakeGamebaseRepository(players: const []);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [gamebaseRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          home: Shortcuts(
            shortcuts: editableAwareShortcuts(const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.keyE): _EngineToggleIntent(),
            }),
            child: Actions(
              actions: <Type, Action<Intent>>{
                _EngineToggleIntent: CallbackAction<_EngineToggleIntent>(
                  onInvoke: (_) {
                    engineToggleCount++;
                    return null;
                  },
                ),
              },
              child: const Scaffold(
                backgroundColor: kBackgroundColor,
                body: Builder(builder: _scopedDesktopExplorerFiltersHarness),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.ensureVisible(find.byType(TextField));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    expect(focusedContext, isNotNull);
    expect(
      focusedContext!.findAncestorStateOfType<EditableTextState>(),
      isNotNull,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pump();

    expect(engineToggleCount, 0);
  });

  testWidgets('scoped opponent can be selected and Clear all removes it', (
    tester,
  ) async {
    final repository = _FakeGamebaseRepository(
      players: const <GamebasePlayer>[
        GamebasePlayer(
          id: 'magnus',
          fideId: '1503014',
          name: 'Carlsen, Magnus',
          gender: PlayerGender.male,
          fed: 'NOR',
          title: 'GM',
          ratingClassical: 2830,
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [gamebaseRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          home: Scaffold(
            backgroundColor: kBackgroundColor,
            body: Builder(builder: _scopedDesktopExplorerFiltersHarness),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'ma');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();
    await tester.ensureVisible(find.text('GM Magnus Carlsen'));
    await tester.tap(find.text('GM Magnus Carlsen'));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(DesktopExplorerFilters)),
    );
    expect(container.read(gamebaseExplorerProvider).filters.playerIds, <String>[
      'bluebaum',
      'magnus',
    ]);
    expect(find.text('Clear all'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(container.read(gamebaseExplorerProvider).filters.playerIds, <String>[
      'bluebaum',
    ]);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ma');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();
    await tester.ensureVisible(find.text('GM Magnus Carlsen'));
    await tester.tap(find.text('GM Magnus Carlsen'));
    await tester.pump();

    container
        .read(gamebaseExplorerProvider.notifier)
        .toggleTimeControl(TimeControl.rapid);
    await tester.pump();
    await tester.tap(find.text('Clear all'));
    await tester.pump();

    final cleared = container.read(gamebaseExplorerProvider).filters;
    expect(cleared.playerIds, <String>['bluebaum']);
    expect(cleared.selectedPlayers.single.id, 'bluebaum');
    expect(cleared.timeControls, isEmpty);
    expect(find.text('GM Matthias Bluebaum'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Clear all'), findsNothing);
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('player search debounces and shows a pending state', (
    tester,
  ) async {
    final repository = _FakeGamebaseRepository(
      players: const [
        GamebasePlayer(
          id: 'magnus',
          fideId: '1503014',
          name: 'Carlsen, Magnus',
          gender: PlayerGender.male,
          fed: 'NOR',
          title: 'GM',
          ratingClassical: 2830,
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [gamebaseRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          home: Scaffold(
            backgroundColor: kBackgroundColor,
            body: Builder(builder: _desktopExplorerFiltersHarness),
          ),
        ),
      ),
    );

    expect(find.text('PLAYER'), findsOneWidget);
    expect(find.text('Sort games'), findsNothing);
    expect(find.text('TIME CONTROL'), findsOneWidget);
    expect(find.text('RATING RANGE'), findsOneWidget);
    expect(find.byIcon(Icons.tune_outlined), findsNothing);
    expect(find.byIcon(Icons.hourglass_top_rounded), findsNothing);
    expect(tester.getBottomRight(find.text('PLAYER')).dy, lessThan(560));

    await tester.enterText(find.byType(TextField), 'ma');
    await tester.pump();

    expect(repository.playerQueries, isEmpty);
    expect(find.text('Searching players...'), findsOneWidget);
    expect(find.text('No players found'), findsNothing);

    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();

    expect(repository.playerQueries, ['ma']);
    expect(find.text('GM Magnus Carlsen'), findsOneWidget);

    await tester.ensureVisible(find.text('GM Magnus Carlsen'));
    await tester.pump();
    await tester.tap(find.text('GM Magnus Carlsen'));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(DesktopExplorerFilters)),
    );
    expect(container.read(gamebaseExplorerProvider).filters.playerIds, [
      'magnus',
    ]);
  });
}

class _EngineToggleIntent extends Intent {
  const _EngineToggleIntent();
}

Widget _desktopExplorerFiltersHarness(BuildContext context) {
  ResponsiveHelper.init(context);
  return const SizedBox(
    width: 360,
    height: 560,
    child: DesktopExplorerFilters(),
  );
}

Widget _scopedDesktopExplorerFiltersHarness(BuildContext context) {
  ResponsiveHelper.init(context);
  return const SizedBox(
    width: 360,
    height: 560,
    child: DesktopExplorerFilters(
      scopedPlayer: GamebasePlayer(
        id: 'bluebaum',
        fideId: '24651516',
        name: 'Bluebaum, Matthias',
        gender: PlayerGender.male,
        fed: 'GER',
        title: 'GM',
        ratingClassical: 2670,
      ),
    ),
  );
}

class _FakeGamebaseRepository extends GamebaseRepository {
  _FakeGamebaseRepository({required this.players})
    : super(Dio(), baseUrl: 'http://localhost');

  final List<GamebasePlayer> players;
  final List<String> playerQueries = [];

  @override
  Future<List<GamebasePlayer>> getPlayers({
    String? name,
    String? fideId,
    int pageNumber = 0,
    int pageSize = 20,
  }) async {
    final query = name?.trim().toLowerCase() ?? '';
    playerQueries.add(query);
    return players
        .where((player) {
          return player.name.toLowerCase().contains(query) ||
              player.displayName.toLowerCase().contains(query) ||
              player.titleAndName.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }
}
