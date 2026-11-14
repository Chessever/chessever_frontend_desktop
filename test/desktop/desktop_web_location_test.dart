import 'package:chessever/desktop/state/desktop_calendar_location.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/state/desktop_web_board_position.dart';

import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/desktop_deep_link_router.dart';
import 'package:chessever/desktop/services/desktop_web_location.dart';
import 'package:chessever/desktop/services/desktop_web_navigation.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/community_likes_providers.dart';
import 'package:chessever/desktop/state/desktop_smart_games.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/collections/collection_actions.dart';

BoardTabGameArgs game(String id) => BoardTabGameArgs(
  gameId: id,
  pgn: '1. e4 e5 *',
  label: id,
  whiteName: 'White',
  blackName: 'Black',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every desktop surface owns a non-root URL', () {
    for (final kind in TabKind.values) {
      final path = desktopWebBasePath(kind);
      expect(path, startsWith('/'), reason: kind.name);
      expect(path, isNot('/'), reason: kind.name);
      expect(Uri.parse(path).hasFragment, false, reason: kind.name);
    }
  });

  test('reserved list/tool URLs win over game and broadcast ids', () {
    for (final entry
        in {
          '/broadcast/settings': TabKind.settings,
          '/broadcast/settings?section=board': TabKind.boardSettings,
          '/broadcast/hubs': TabKind.tournaments,
          '/games/search': TabKind.smartGames,
          '/analysis?editor=1': TabKind.boardEditor,
          '/analysis?explorer=1': TabKind.openingExplorer,
          '/collections': TabKind.collections,
          '/databases': TabKind.library,
          '/learn': TabKind.howToUse,
          '/app/inbox': TabKind.inbox,
        }.entries) {
      expect(desktopWebListKind(Uri.parse(entry.key)), entry.value);
    }
    expect(desktopWebListKind(Uri.parse('/games/EjfscMGB-1ct01mo')), null);
    expect(desktopWebListKind(Uri.parse('/collections/chess-classics')), null);
  });

  test('app and public hostnames parse to the same game and player', () {
    for (final host in ['chessever.com', 'app.chessever.com']) {
      final game = parseDesktopIncomingLink(
        Uri.parse('https://$host/games/EjfscMGB-1ct01mo'),
      );
      expect(game?.game?.id, 'EjfscMGB-1ct01mo');
      final player = parseDesktopIncomingLink(
        Uri.parse('https://$host/player/mikhail-tal/tal-mikhail-1936'),
      );
      expect(player?.profileId, 'tal-mikhail-1936');
    }
    expect(
      parseDesktopIncomingLink(
        Uri.parse('https://app.chessever.com.evil.test/games/abcd1234'),
      ),
      null,
    );
  });

  test(
    'Events URLs default to For You without changing explicit tabs',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      for (final entry
          in {
            '/': '/broadcast?tab=for-you',
            '/?utm_source=test': '/broadcast?tab=for-you',
            '/broadcast?tab=current': '/broadcast?tab=current',
            '/broadcast?tab=for-you': '/broadcast?tab=for-you',
            '/broadcast?tab=past': '/broadcast?tab=past',
            '/broadcast?tab=search': '/broadcast?tab=search',
            '/broadcast': '/broadcast?tab=for-you',
            '/broadcast/hubs': '/broadcast?tab=for-you',
            '/broadcast?tab=bogus': '/broadcast?tab=for-you',
            '/?tab=current': '/broadcast?tab=current',
          }.entries) {
        expect(
          await openDesktopWebLocation(
            Uri.parse('https://app.chessever.com${entry.key}'),
            container,
          ),
          true,
        );
        expect(
          container.read(desktopTabsProvider).active?.kind,
          TabKind.tournaments,
        );
        expect(
          container.read(desktopWebLocationProvider),
          entry.value,
          reason: entry.key,
        );
      }
    },
  );

  test('direct list URLs select their actual pane', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    for (final path in [
      '/collections',
      '/databases',
      '/favorites',
      '/rankings',

      '/account',
      '/play',
      '/broadcast/settings',
    ]) {
      expect(
        await openDesktopWebLocation(
          Uri.parse('https://app.chessever.com$path'),
          container,
        ),
        true,
      );
      expect(
        container.read(desktopTabsProvider).active?.kind,
        desktopWebListKind(Uri.parse(path)),
      );
      expect(container.read(desktopWebLocationProvider), path);
    }
  });

  test('a game change in one tab restores the exact game on Back/Forward', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final tabs = container.read(desktopTabsProvider.notifier);
    final id = tabs.open(TabKind.board);
    final args = container.read(boardTabGameArgsByTabIdProvider.notifier);
    args.state = {id: game('EjfscMGB-1ct01mo')};
    final first = captureDesktopWebPage(container);
    args.state = {id: game('UKMTO5qg')};
    final second = captureDesktopWebPage(container);
    expect(container.read(desktopWebLocationProvider), '/games/UKMTO5qg');
    first();
    expect(
      container.read(desktopWebLocationProvider),
      '/games/EjfscMGB-1ct01mo',
    );
    second();
    expect(container.read(desktopWebLocationProvider), '/games/UKMTO5qg');
    expect(
      container
          .read(desktopTabsProvider)
          .tabs
          .where((tab) => tab.kind == TabKind.board),
      hasLength(1),
    );
  });

  test(
    'same workspace can go from collection to game and return to its collection',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final tabs = container.read(desktopTabsProvider.notifier);
      final id = tabs.open(TabKind.collectionWorkspace);
      container.read(collectionWorkspaceArgsByTabIdProvider.notifier).state = {
        id: const CollectionWorkspaceArgs(
          slug: 'classic-games',
          title: 'Classics',
        ),
      };
      final collection = captureDesktopWebPage(container);
      tabs.navigateActive(TabKind.board);
      container.read(boardTabGameArgsByTabIdProvider.notifier).state = {
        id: game('UKMTO5qg'),
      };
      collection();
      expect(
        container.read(desktopTabsProvider).active?.kind,
        TabKind.collectionWorkspace,
      );
      expect(
        container.read(desktopWebLocationProvider),
        '/collections/classic-games',
      );
    },
  );

  test(
    'historical profiles retain their canonical identity instead of returning to root',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final id = container
          .read(desktopTabsProvider.notifier)
          .open(TabKind.playerProfile);
      container.read(playerProfileByTabIdProvider.notifier).state = {
        id: const PlayerProfileArgs(
          playerName: 'Tal, Mikhail',
          memorialRouteId: 'tal-mikhail-1936',
        ),
      };
      expect(
        container.read(desktopWebLocationProvider),
        '/player/mikhail-tal/tal-mikhail-1936',
      );
    },
  );

  test('Likes view/day and Miniatures sections are navigable state', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final tabs = container.read(desktopTabsProvider.notifier);
    tabs.open(TabKind.likes);
    container.read(communityLikesDayProvider.notifier).state = DateTime(
      2026,
      10,
      20,
    );
    container.read(communityLikesSectionProvider.notifier).state =
        CommunityLikesSection.players;
    expect(
      container.read(desktopWebLocationProvider),
      '/app/likes/week?date=2026-10-20&view=players',
    );
    final earlier = captureDesktopWebPage(container);
    container.read(communityLikesSectionProvider.notifier).state =
        CommunityLikesSection.games;
    earlier();
    expect(
      container.read(communityLikesSectionProvider),
      CommunityLikesSection.players,
    );
    await openDesktopWebLocation(
      Uri.parse('/app/miniatures/players'),
      container,
    );
    final id = container.read(desktopTabsProvider).activeId!;
    expect(
      container.read(desktopMiniaturesSectionByTabIdProvider(id)),
      DesktopMiniaturesSection.players,
    );
    expect(
      container.read(desktopWebLocationProvider),
      '/app/miniatures/players',
    );
  });

  test('disabled Calendar URLs return to Home without creating tabs', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final tabs = container.read(desktopTabsProvider.notifier);
    final board = tabs.open(TabKind.board);
    for (final path in [
      '/calendar?mode=fide&month=2026-10',
      '/calendar?mode=major&month=2026-11',
    ]) {
      expect(await openDesktopWebLocation(Uri.parse(path), container), isTrue);
      expect(tabs.state.isHomeVisible, isTrue);
      expect(tabs.state.tabs.map((tab) => tab.id), [board]);
    }
  });

  test(
    'manual help URL requests an overlay while preserving the active tab',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final tabs = container.read(desktopTabsProvider.notifier);
      final board = tabs.open(TabKind.board);
      await openDesktopWebLocation(Uri.parse('/learn'), container);
      expect(container.read(desktopHelpRequestedProvider), isTrue);
      expect(tabs.state.activeId, board);
      expect(tabs.state.tabs, hasLength(1));
    },
  );
  test('public player section suffixes keep the player identity', () {
    for (final view in ['games', 'events', 'about', 'overview']) {
      final link = parseDesktopIncomingLink(
        Uri.parse(
          'https://app.chessever.com/player/magnus-carlsen/1503014/$view',
        ),
      );
      expect(link?.profileId, '1503014');
      expect(
        link?.profileSection,
        view == 'games'
            ? PlayerProfileSection.games
            : view == 'events'
            ? PlayerProfileSection.events
            : PlayerProfileSection.about,
      );
    }
  });

  test(
    'analysis FEN and orientation round-trip without exposing a PGN',
    () async {
      const fen = '8/8/8/8/8/2k5/8/2K5 w - - 0 1';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        await openDesktopWebLocation(
          Uri(path: '/analysis', queryParameters: {'fen': fen, 'flip': '1'}),
          container,
        ),
        true,
      );
      final id = container.read(desktopTabsProvider).activeId!;
      expect(
        container.read(boardTabGameArgsByTabIdProvider)[id]?.initialFen,
        fen,
      );
      expect(
        container.read(desktopWebBoardPositionByTabIdProvider)[id]?.flipped,
        true,
      );
      expect(
        await openDesktopWebLocation(
          Uri.parse('/analysis?fen=broken'),
          container,
        ),
        false,
      );
    },
  );

  test('board cursor and orientation use the public game query format', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final id = container.read(desktopTabsProvider.notifier).open(TabKind.board);
    container.read(boardTabGameArgsByTabIdProvider.notifier).state = {
      id: game('EjfscMGB-1ct01mo'),
    };
    final chess = ChessGame.fromPgn('EjfscMGB-1ct01mo', '1. e4 e5 2. Nf3 *');
    container.read(boardPaneSessionByTabIdProvider.notifier).state = {
      id: BoardPaneSession(
        game: chess,
        pointer: [0],
        pgnHeaders: {},
        flipped: true,
        loadedFrom: null,
        lastAppliedPgn: null,
        lastAppliedGameId: 'EjfscMGB-1ct01mo',
        lastAppliedInitialFenKey: null,
        dirtySinceLoad: false,
        hasUnseenMoves: false,
        undoStack: [],
      ),
    };
    expect(
      container.read(desktopWebLocationProvider),
      '/games/EjfscMGB-1ct01mo?ply=1&flip=1',
    );
    final back = captureDesktopWebPage(container);
    back();
    expect(
      container.read(desktopWebBoardPositionByTabIdProvider)[id]?.fen,
      chess.mainline.first.fen,
    );
  });

  test('disabled Calendar detail links do not call the event loader', () async {
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        desktopCalendarWebEventLoaderProvider.overrideWithValue((_) async {
          calls++;
          throw StateError('disabled Calendar must not fetch');
        }),
      ],
    );
    addTearDown(container.dispose);
    const path = '/calendar/european-team-championship/fide-54321';
    expect(await openDesktopWebLocation(Uri.parse(path), container), isTrue);
    expect(container.read(desktopTabsProvider).tabs, isEmpty);
    expect(container.read(desktopTabsProvider).isHomeVisible, isTrue);
    expect(
      container.read(desktopWebLocationProvider),
      startsWith('/broadcast'),
    );
    expect(calls, 0);
  });

  test('the Likes About surface has its own public URL', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await openDesktopWebLocation(Uri.parse('/app/likes'), container);
    expect(
      container.read(communityLikesSectionProvider),
      CommunityLikesSection.about,
    );
    expect(container.read(desktopWebLocationProvider), '/app/likes');
  });
}
