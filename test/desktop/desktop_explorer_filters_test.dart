import 'package:chessever/desktop/widgets/desktop_explorer_filters.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
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

Widget _desktopExplorerFiltersHarness(BuildContext context) {
  ResponsiveHelper.init(context);
  return const SizedBox(
    width: 360,
    height: 560,
    child: DesktopExplorerFilters(),
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
