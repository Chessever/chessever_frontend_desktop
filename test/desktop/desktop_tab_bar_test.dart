import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/shell/desktop_tab_bar.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/screens/chessboard/provider/current_eval_provider.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';
import 'package:chessever/widgets/federation_flag.dart';

const _fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

void main() {
  test('player profile args default to TWIC', () {
    const args = PlayerProfileArgs(playerName: 'Erigaisi,Arjun');

    expect(args.dataSource, PlayerProfileDataSource.twic);
  });

  testWidgets('tab bar lays out many tabs in a narrow strip', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Consumer(
                  builder: (context, ref, _) {
                    return TextButton(
                      onPressed: () {
                        final tabs = ref.read(desktopTabsProvider.notifier);
                        for (var i = 0; i < 5; i++) {
                          tabs.open(TabKind.library, reuseExisting: false);
                          openBoardGameTab(
                            ref,
                            _args('game-$i'),
                            reuseExisting: false,
                          );
                        }
                      },
                      child: const Text('seed'),
                    );
                  },
                ),
                const SizedBox(width: 360, height: 46, child: DesktopTabBar()),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('seed'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);
  });

  testWidgets('wide game tabs keep player flags beside names', (tester) async {
    await _pumpSeededGameTabBar(tester, width: 480);

    expect(find.text('Carlsen'), findsOneWidget);
    expect(find.text('Nakamura'), findsOneWidget);
    expect(find.byType(FederationFlag), findsNWidgets(2));
  });

  testWidgets('wide game tabs reserve backfilled flags from FIDE ids', (
    tester,
  ) async {
    await _pumpSeededGameTabBar(
      tester,
      width: 480,
      whiteFederation: 'FIDE',
      blackFederation: '',
      whiteFideId: 13603415,
      blackFideId: 30920019,
    );

    expect(find.text('Carlsen'), findsOneWidget);
    expect(find.text('Nakamura'), findsOneWidget);
    expect(find.byType(BackfilledFederationFlag), findsNWidgets(2));
  });

  testWidgets('narrow game tabs drop flags before player names', (
    tester,
  ) async {
    await _pumpSeededGameTabBar(tester, width: 280);

    expect(find.text('Carlsen'), findsOneWidget);
    expect(find.text('Nakamura'), findsOneWidget);
    expect(find.byType(FederationFlag), findsNothing);
    expect(tester.getSize(find.text('Carlsen')).width, greaterThan(30));
    expect(tester.getSize(find.text('Nakamura')).width, greaterThan(30));
  });

  testWidgets('game tabs place both player titles before names', (
    tester,
  ) async {
    await _pumpSeededGameTabBar(
      tester,
      width: 520,
      whiteName: 'Erigaisi, Arjun',
      blackName: 'Radjabov, Teimour',
      whiteTitle: 'GM',
      blackTitle: 'GM',
    );

    final whiteTitleX = tester.getTopLeft(find.text('GM').first).dx;
    final whiteNameX = tester.getTopLeft(find.text('Erigaisi')).dx;
    final blackTitleX = tester.getTopLeft(find.text('GM').last).dx;
    final blackNameX = tester.getTopLeft(find.text('Radjabov')).dx;

    expect(whiteTitleX, lessThan(whiteNameX));
    expect(blackTitleX, lessThan(blackNameX));
  });

  testWidgets(
    'player profile tabs show flag title and last name without icon',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  Consumer(
                    builder: (context, ref, _) {
                      return TextButton(
                        onPressed: () {
                          openPlayerProfile(
                            ref,
                            const PlayerProfileArgs(
                              playerName: 'Erigaisi,Arjun',
                              fideId: 35009192,
                              title: 'GM',
                              federation: 'IND',
                            ),
                          );
                          ref
                              .read(desktopTabsProvider.notifier)
                              .close('tournaments-default');
                        },
                        child: const Text('seed-profile'),
                      );
                    },
                  ),
                  const SizedBox(
                    width: 260,
                    height: 46,
                    child: DesktopTabBar(),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('seed-profile'));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('GM'), findsOneWidget);
      expect(find.text('Erigaisi'), findsOneWidget);
      expect(find.text('Erigaisi,Arjun'), findsNothing);
      expect(find.byType(FederationFlag), findsOneWidget);
      expect(find.byIcon(Icons.person_outline_rounded), findsNothing);
    },
  );

  testWidgets('game tab eval strip never starts Stockfish fallback', (
    tester,
  ) async {
    var fallbackCalls = 0;
    var cacheOnlyCalls = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gameCardEvalWithStockfishFallbackProvider.overrideWith((ref, fen) {
            fallbackCalls++;
            return _cloudEval(120);
          }),
          gameCardEvalCacheOnlyProvider.overrideWith((ref, fen) {
            cacheOnlyCalls++;
            return _cloudEval(80);
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Consumer(
                  builder: (context, ref, _) {
                    return TextButton(
                      onPressed: () {
                        openBoardGameTab(
                          ref,
                          _args(
                            'game-eval',
                            whiteName: 'Magnus Carlsen',
                            blackName: 'Nakamura, Hikaru',
                            fenSeed: _fen,
                          ),
                          reuseExisting: false,
                        );
                      },
                      child: const Text('seed-eval'),
                    );
                  },
                ),
                const SizedBox(width: 480, height: 46, child: DesktopTabBar()),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('seed-eval'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(cacheOnlyCalls, greaterThan(0));
    expect(fallbackCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tab strip back and forward buttons navigate route history', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Consumer(
                  builder: (context, ref, _) {
                    return TextButton(
                      onPressed: () {
                        final tabs = ref.read(desktopTabsProvider.notifier);
                        tabs.navigateActive(TabKind.library);
                        tabs.navigateActive(TabKind.players);
                      },
                      child: const Text('seed-routes'),
                    );
                  },
                ),
                const SizedBox(width: 420, height: 46, child: DesktopTabBar()),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('seed-routes'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward_rounded), findsOneWidget);
    expect(find.text('Players'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('desktop-tab-back-button')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Library'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('desktop-tab-forward-button')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Players'), findsOneWidget);
  });
}

Future<void> _pumpSeededGameTabBar(
  WidgetTester tester, {
  required double width,
  String whiteName = 'Magnus Carlsen',
  String blackName = 'Nakamura, Hikaru',
  String whiteTitle = '',
  String blackTitle = '',
  String whiteFederation = 'NOR',
  String blackFederation = 'USA',
  int? whiteFideId,
  int? blackFideId,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Consumer(
                builder: (context, ref, _) {
                  return TextButton(
                    onPressed: () {
                      openBoardGameTab(
                        ref,
                        _args(
                          'game-feature',
                          whiteName: whiteName,
                          blackName: blackName,
                          whiteFederation: whiteFederation,
                          blackFederation: blackFederation,
                          whiteTitle: whiteTitle,
                          blackTitle: blackTitle,
                          whiteFideId: whiteFideId,
                          blackFideId: blackFideId,
                        ),
                        reuseExisting: false,
                      );
                      ref
                          .read(desktopTabsProvider.notifier)
                          .close('tournaments-default');
                    },
                    child: const Text('seed-game'),
                  );
                },
              ),
              SizedBox(width: width, height: 46, child: const DesktopTabBar()),
            ],
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('seed-game'));
  await tester.pump(const Duration(milliseconds: 200));
}

BoardTabGameArgs _args(
  String gameId, {
  String whiteName = 'White',
  String blackName = 'Black',
  String whiteFederation = '',
  String blackFederation = '',
  String whiteTitle = '',
  String blackTitle = '',
  int? whiteFideId,
  int? blackFideId,
  String? fenSeed,
}) {
  return BoardTabGameArgs(
    gameId: gameId,
    pgn: '1. e4 e5 *',
    label: '$whiteName vs $blackName',
    whiteName: whiteName,
    blackName: blackName,
    whiteFederation: whiteFederation,
    blackFederation: blackFederation,
    whiteTitle: whiteTitle,
    blackTitle: blackTitle,
    whiteFideId: whiteFideId,
    blackFideId: blackFideId,
    fenSeed: fenSeed,
  );
}

Future<CloudEval> _cloudEval(int cp) async {
  return CloudEval(
    fen: _fen,
    knodes: 0,
    depth: 12,
    pvs: [Pv(moves: 'e7e5', cp: cp)],
    requestedMultiPv: 1,
  );
}
