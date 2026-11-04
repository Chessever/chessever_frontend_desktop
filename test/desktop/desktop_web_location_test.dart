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

  test('direct list URLs select their actual pane', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    for (final path in [
      '/collections',
      '/databases',
      '/favorites',
      '/rankings',
      '/learn',
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

  test(
    'calendar mode and month survive direct navigation and history restoration',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await openDesktopWebLocation(
        Uri.parse('/calendar?mode=fide&month=2026-10'),
        container,
      );
      expect(
        container.read(desktopWebLocationProvider),
        '/calendar?mode=fide&month=2026-10',
      );
      final october = captureDesktopWebPage(container);
      await openDesktopWebLocation(
        Uri.parse('/calendar?mode=major&month=2026-11'),
        container,
      );
      october();
      expect(
        container.read(desktopWebLocationProvider),
        '/calendar?mode=fide&month=2026-10',
      );
    },
  );
}
