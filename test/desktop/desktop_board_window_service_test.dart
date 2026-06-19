import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:country_picker/country_picker.dart';

import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/services/desktop_board_window_service.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/countrymen/provider/countrymen_mode_provider.dart';

void main() {
  test('board window payload round-trips serializable board args', () {
    final args = _args(
      gameId: 'game-1',
      pgn: '1. e4 e5 *',
      initialBoardFlipped: true,
      fenSeed: 'fen-seed',
      initialFen: 'initial-fen',
      viewSource: ChessboardView.favScorecard,
      gameListSelectedId: 'selected-1',
    );

    final decoded = DesktopBoardWindowPayload.decode(
      DesktopBoardWindowPayload.fromArgs(args).encode(),
    );

    expect(decoded.title, 'Carlsen vs Nakamura');
    expect(decoded.kind, TabKind.board);
    expect(decoded.args?.gameId, 'game-1');
    expect(decoded.args?.pgn, '1. e4 e5 *');
    expect(decoded.args?.whiteName, 'Carlsen');
    expect(decoded.args?.blackName, 'Nakamura');
    expect(decoded.args?.whiteFederation, 'NOR');
    expect(decoded.args?.blackFederation, 'USA');
    expect(decoded.args?.whiteFideId, 1503014);
    expect(decoded.args?.blackFideId, 2016192);
    expect(decoded.args?.initialBoardFlipped, isTrue);
    expect(decoded.args?.fenSeed, 'fen-seed');
    expect(decoded.args?.initialFen, 'initial-fen');
    expect(decoded.args?.viewSource, ChessboardView.favScorecard);
    expect(decoded.args?.gameListSelectedId, 'selected-1');
  });

  test('tab window payload round-trips non-board route identity', () {
    const tab = DesktopTab(
      id: 'tab-1',
      kind: TabKind.library,
      title: 'Library',
      subtitle: 'Databases',
    );

    final decoded = DesktopBoardWindowPayload.decode(
      DesktopBoardWindowPayload.fromTab(tab).encode(),
    );

    expect(decoded.kind, TabKind.library);
    expect(decoded.title, 'Library');
    expect(decoded.subtitle, 'Databases');
    expect(decoded.args, isNull);
  });

  test('opening a board window does not mutate main-window tabs', () async {
    late DesktopBoardWindowPayload captured;
    final container = ProviderContainer(
      overrides: [
        desktopBoardWindowServiceProvider.overrideWithValue(
          DesktopBoardWindowService(
            createWindow: (payload) async => captured = payload,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final before = container.read(desktopTabsProvider).tabs.length;

    await container
        .read(desktopBoardWindowServiceProvider)
        .openBoardGameWindow(_args(gameId: 'game-1'));

    expect(captured.args?.gameId, 'game-1');
    expect(container.read(desktopTabsProvider).tabs.length, before);
  });

  test(
    'detaching a board tab closes it after window creation succeeds',
    () async {
      final opened = <DesktopBoardWindowPayload>[];
      final container = ProviderContainer(
        overrides: [
          desktopBoardWindowServiceProvider.overrideWithValue(
            DesktopBoardWindowService(
              createWindow: (payload) async => opened.add(payload),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final tabId = openBoardGameTabFromContainer(
        container,
        _args(gameId: 'game-1'),
        reuseExisting: false,
      );

      final detached = await detachBoardTabToWindow(container, tabId);

      expect(detached, isTrue);
      expect(opened.single.kind, TabKind.board);
      expect(opened.single.args?.gameId, 'game-1');
      expect(
        container.read(desktopTabsProvider).tabs.any((tab) => tab.id == tabId),
        isFalse,
      );
    },
  );

  test('failed detach keeps the original board tab open', () async {
    final container = ProviderContainer(
      overrides: [
        desktopBoardWindowServiceProvider.overrideWithValue(
          DesktopBoardWindowService(
            createWindow: (_) async => throw StateError('window failed'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final tabId = openBoardGameTabFromContainer(
      container,
      _args(gameId: 'game-1'),
      reuseExisting: false,
    );

    await expectLater(
      detachBoardTabToWindow(container, tabId),
      throwsStateError,
    );

    expect(
      container.read(desktopTabsProvider).tabs.any((tab) => tab.id == tabId),
      isTrue,
    );
  });

  test('non-board tabs detach to a tab-content window', () async {
    final opened = <DesktopBoardWindowPayload>[];
    final container = ProviderContainer(
      overrides: [
        desktopBoardWindowServiceProvider.overrideWithValue(
          DesktopBoardWindowService(
            createWindow: (payload) async => opened.add(payload),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final tabId = container
        .read(desktopTabsProvider.notifier)
        .open(TabKind.library, reuseExisting: false);

    final detached = await detachDesktopTabToWindow(container, tabId);

    expect(detached, isTrue);
    expect(opened.single.kind, TabKind.library);
    expect(opened.single.args, isNull);
    expect(
      container.read(desktopTabsProvider).tabs.any((tab) => tab.id == tabId),
      isFalse,
    );
  });

  test(
    'countrymen tab window payload preserves selected country and mode',
    () async {
      late DesktopBoardWindowPayload captured;
      final container = ProviderContainer(
        overrides: [
          desktopBoardWindowServiceProvider.overrideWithValue(
            DesktopBoardWindowService(
              createWindow: (payload) async => captured = payload,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final india = CountryService().findByCode('IN');
      expect(india, isNotNull);
      container.read(temporaryCountryProvider.notifier).state = india;
      container.read(selectedCountrymenModeProvider.notifier).state =
          CountrymenScreenMode.events;
      final tabId = container
          .read(desktopTabsProvider.notifier)
          .open(TabKind.countrymen, reuseExisting: false);
      final tab = container
          .read(desktopTabsProvider)
          .tabs
          .firstWhere((tab) => tab.id == tabId);

      await container
          .read(desktopBoardWindowServiceProvider)
          .openDesktopTabWindow(container, tab);

      expect(captured.kind, TabKind.countrymen);
      expect(captured.metadata['countryCode'], 'IN');
      expect(captured.metadata['countryName'], india!.name);
      expect(
        captured.metadata['countrymenMode'],
        CountrymenScreenMode.events.name,
      );
    },
  );
}

BoardTabGameArgs _args({
  String? gameId,
  String pgn = '',
  bool initialBoardFlipped = false,
  String? fenSeed,
  String? initialFen,
  ChessboardView viewSource = ChessboardView.tour,
  String? gameListSelectedId,
}) {
  return BoardTabGameArgs(
    gameId: gameId,
    pgn: pgn,
    label: 'Carlsen vs Nakamura',
    whiteName: 'Carlsen',
    blackName: 'Nakamura',
    whiteFederation: 'NOR',
    blackFederation: 'USA',
    whiteTitle: 'GM',
    blackTitle: 'GM',
    whiteRating: 2830,
    blackRating: 2800,
    whiteFideId: 1503014,
    blackFideId: 2016192,
    initialBoardFlipped: initialBoardFlipped,
    fenSeed: fenSeed,
    initialFen: initialFen,
    viewSource: viewSource,
    gameListSelectedId: gameListSelectedId,
  );
}
