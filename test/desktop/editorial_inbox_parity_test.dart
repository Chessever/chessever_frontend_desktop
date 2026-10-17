import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/inbox_pane.dart';
import 'package:chessever/desktop/services/editorial/editorial_links.dart';
import 'package:chessever/desktop/services/editorial/inbox_message.dart';
import 'package:chessever/desktop/services/editorial/inbox_provider.dart';
import 'package:chessever/desktop/shell/desktop_main_routes.dart';
import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/library_destination.dart';
import 'package:chessever/desktop/state/desktop_smart_games.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/desktop/widgets/collections/collection_actions.dart';
import 'package:chessever/desktop/services/collections_reader.dart';
import 'package:chessever/desktop/widgets/editorial/inbox_reader.dart';
import 'package:chessever/desktop/widgets/editorial/inbox_image.dart';
import '../inbox_fakes.dart';
import 'support/collections_fakes.dart';

Future<void> mount(
  WidgetTester tester,
  ProviderContainer container,
  Widget child, {
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(1100, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
              size: const Size(1100, 700),
              textScaler: TextScaler.linear(scale),
            ),
            child: child,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('read retry and Refresh remove stale unread UI', (tester) async {
    final source = FakeInboxSource()..failMark = true;
    source.rows[inboxOwnerA] = [inboxFixture(inboxIdA)];
    final controller = InboxController(
      ownerId: inboxOwnerA,
      source: source,
      cache: FakeInboxCache(),
    );
    await controller.start();
    final container = ProviderContainer(
      overrides: [inboxProvider.overrideWith((ref) => controller)],
    );
    addTearDown(container.dispose);
    await mount(tester, container, const InboxPane());
    await tester.tap(find.byKey(const ValueKey('inbox-row-$inboxIdA')));
    await tester.pumpAndSettle();
    expect(controller.state.hasUnread, true);
    source.failMark = false;
    await tester.scrollUntilVisible(
      find.text('Retry read'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Retry read'));
    await tester.pumpAndSettle();
    expect(controller.state.hasUnread, false);
    source.rows[inboxOwnerA] = [];
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(
      find.text('This message has been taken back or removed.'),
      findsOneWidget,
    );
    expect(find.text('No messages yet'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'account changes clear selection before any new account acknowledgement',
    (tester) async {
      final owner = StateProvider((ref) => inboxOwnerA);
      final source = FakeInboxSource();
      source.rows[inboxOwnerB] = [inboxFixture(inboxIdA)];
      final controllers = {
        for (final id in [inboxOwnerA, inboxOwnerB])
          id: InboxController(
            ownerId: id,
            source: source,
            cache: FakeInboxCache(),
          ),
      };
      await Future.wait(controllers.values.map((c) => c.start()));
      final container = ProviderContainer(
        overrides: [
          inboxProvider.overrideWith((ref) => controllers[ref.watch(owner)]!),
        ],
      );
      addTearDown(container.dispose);
      await mount(tester, container, const InboxPane());
      await tester.tap(find.byKey(const ValueKey('inbox-row-$inboxIdA')));
      await tester.pumpAndSettle();
      container.read(owner.notifier).state = inboxOwnerB;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('inbox-full-text')), findsNothing);
      expect(source.marks.where((mark) => mark.$1 == inboxOwnerB), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'native mobile aliases and numbered shortcuts retain their destinations',
    () {
      for (final entry
          in {
            'inbox': DesktopPane.inbox,
            'library': DesktopPane.library,
            'my-prep': DesktopPane.players,
            'my-likes': DesktopPane.library,
            'collections': DesktopPane.collections,
          }.entries) {
        for (final prefix in ['', '/app']) {
          expect(
            desktopEditorialPaneForUri(
              Uri.parse('https://chessever.com$prefix/${entry.key}/'),
            ),
            entry.value,
          );
        }
      }
      expect(
        desktopEditorialPageRequiresPremium(
          Uri.parse('https://chessever.com/play'),
        ),
        true,
      );
      expect(desktopMainRouteShortcutNumber(DesktopPane.inbox), null);
      expect(desktopMainRouteShortcutNumber(DesktopPane.collections), 0);
      expect(desktopMainRouteShortcutNumber(DesktopPane.play), 9);
      expect(
        desktopEditorialPageRequiresPremium(
          Uri.parse('https://chessever.com/app/reports'),
        ),
        true,
      );
      for (final hub in ['feed', 'likes', 'miniatures', 'my-prep', 'library']) {
        expect(
          desktopEditorialPageRequiresPremium(
            Uri.parse('https://chessever.com/$hub'),
          ),
          false,
        );
      }
      expect(
        desktopEditorialPaneForUri(
          Uri.parse('https://chessever.com.evil.test/inbox'),
        ),
        null,
      );
      expect(
        desktopEditorialPaneForUri(
          Uri.parse('https://chessever.com:444/inbox'),
        ),
        null,
      );
    },
  );

  test('image and link policy matches the production mobile Inbox', () {
    expect(editorialLink('/app/inbox')?.host, 'chessever.com');
    expect(editorialLink('http://example.com/help')?.scheme, 'http');
    for (final unsafe in [
      'javascript:alert(1)',
      'data:text/html,test',
      'https://user@chessever.com/inbox',
    ]) {
      expect(editorialLink(unsafe), null);
    }
    expect(
      editorialImage(
        'https://oelbsuggrzyqwzmvidju.supabase.co/storage/v1/object/public/editorial-inbox/photo.png',
      ),
      isNotNull,
    );
    expect(editorialImage('/news/cover.jpg'), isNotNull);
    for (final unsafe in [
      'https://example.com/pixel.gif',
      'http://chessever.com/cover.jpg',
      'https://chessever.com:444/image',
      'https://oelbsuggrzyqwzmvidju.supabase.co/rest/v1/secrets',
    ]) {
      expect(editorialImage(unsafe), null);
    }
  });

  testWidgets('Markdown, attachment and action use the same link opener', (
    tester,
  ) async {
    final opened = <Uri>[];
    final container = ProviderContainer(
      overrides: [
        desktopEditorialLinkOpenerProvider.overrideWithValue(
          (context, uri) async => opened.add(uri),
        ),
      ],
    );
    addTearDown(container.dispose);
    final message = InboxMessage(
      id: inboxIdA,
      title: 'A rich update',
      body:
          '## Study this\n\n**Important**\n\n- First step\n- Second step\n\n[Open Library](/app/library)',
      isMarkdown: true,
      publishedAt: DateTime.utc(2026, 10, 14),
      imageUrl:
          'https://oelbsuggrzyqwzmvidju.supabase.co/storage/v1/object/public/editorial-inbox/fixture.jpg',
      actionLabel: 'See collections',
      actionUrl: 'https://chessever.com/collections',
    );
    await mount(
      tester,
      container,
      InboxReader(message: message, onRetryRead: () {}),
    );
    expect(find.text('Oct 14, 2026'), findsOneWidget);
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.byType(InboxImage), findsOneWidget);
    final decoded =
        tester.widget<Image>(find.byType(Image)).image as ResizeImage;
    expect(decoded.policy, ResizeImagePolicy.fit);
    expect(decoded.width, lessThanOrEqualTo(2048));
    expect(decoded.height, lessThanOrEqualTo(4096));
    expect(decoded.imageProvider, isA<CachedNetworkImageProvider>());
    await tester.ensureVisible(find.text('Open Library'));
    await tester.tap(find.text('Open Library'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('inbox-action')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('inbox-action')));
    await tester.pumpAndSettle();
    expect(opened.map((u) => u.path), ['/app/library', '/collections']);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('compact reading and back retain the list without overflow', (
    tester,
  ) async {
    final source = FakeInboxSource();
    final controller = InboxController(
      ownerId: inboxOwnerA,
      source: source,
      cache: FakeInboxCache(),
    );
    await controller.start();
    final container = ProviderContainer(
      overrides: [inboxProvider.overrideWith((ref) => controller)],
    );
    addTearDown(container.dispose);
    await mount(
      tester,
      container,
      const Align(child: SizedBox(width: 430, child: InboxPane())),
      scale: 1.5,
    );
    await tester.tap(find.byKey(const ValueKey('inbox-row-$inboxIdA')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('inbox-full-text')),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('inbox-full-text')), findsOneWidget);
    expect(find.byKey(const ValueKey('inbox-row-$inboxIdB')), findsNothing);
    expect(tester.takeException(), null);
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inbox-row-$inboxIdB')), findsOneWidget);
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a hidden tab never acknowledges a selected publication', (
    tester,
  ) async {
    final source = FakeInboxSource();
    final controller = InboxController(
      ownerId: inboxOwnerA,
      source: source,
      cache: FakeInboxCache(),
    );
    await controller.start();
    final container = ProviderContainer(
      overrides: [inboxProvider.overrideWith((ref) => controller)],
    );
    addTearDown(container.dispose);
    final tabs = container.read(desktopTabsProvider.notifier);
    final id = tabs.open(TabKind.inbox);
    tabs.open(TabKind.board);
    await mount(tester, container, InboxPane(tabId: id));
    await tester.tap(find.byKey(const ValueKey('inbox-row-$inboxIdA')));
    await tester.pumpAndSettle();
    expect(source.marks, isEmpty);
    tabs.activate(id);
    await tester.pumpAndSettle();
    expect(source.marks, hasLength(1));
    tabs.open(TabKind.board);
    await tester.pumpAndSettle();
    source.rows[inboxOwnerA] = [
      inboxFixture(inboxIdA, publishedAt: DateTime.utc(2026, 11)),
    ];
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(source.marks, hasLength(1));
    tabs.activate(id);
    await tester.pumpAndSettle();
    expect(source.marks, hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'canceling Premium does not navigate and concurrent clicks share one flow',
    (tester) async {
      final gate = Completer<bool>();
      var requests = 0, navigations = 0;
      final container = ProviderContainer(
        overrides: [
          desktopEditorialPremiumRequestProvider.overrideWithValue((context) {
            requests++;
            return gate.future;
          }),
          desktopEditorialNavigationProvider.overrideWithValue((
            context,
            uri,
          ) async {
            navigations++;
          }),
        ],
      );
      addTearDown(container.dispose);
      late BuildContext context;
      await mount(
        tester,
        container,
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      );
      final opener = container.read(desktopEditorialLinkOpenerProvider);
      final first = opener(
        context,
        Uri.parse('https://chessever.com/app/reports'),
      );
      await opener(context, Uri.parse('https://chessever.com/app/reports'));
      expect(requests, 1);
      expect(navigations, 0);
      gate.complete(false);
      await first;
      expect(navigations, 0);
      await opener(context, Uri.parse('https://chessever.com/library'));
      expect(navigations, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a locked collection opens only after Premium and fresh server confirmation',
    (tester) async {
      final reader = FakeCollectionsReader();
      var unlock = false, requests = 0;
      final container = ProviderContainer(
        overrides: [
          collectionsReaderProvider.overrideWithValue(reader),
          desktopEditorialPremiumRequestProvider.overrideWithValue((
            context,
          ) async {
            requests++;
            if (unlock) reader.lockedSlugs = {};
            return unlock;
          }),
        ],
      );
      addTearDown(container.dispose);
      late BuildContext context;
      await mount(
        tester,
        container,
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      );
      final opener = container.read(desktopEditorialLinkOpenerProvider);
      await opener(
        context,
        Uri.parse('https://chessever.com/collections/zurich-1953'),
      );
      expect(requests, 1);
      expect(container.read(collectionWorkspaceArgsByTabIdProvider), isEmpty);
      unlock = true;
      await opener(
        context,
        Uri.parse('https://chessever.com/collections/zurich-1953'),
      );
      expect(requests, 2);
      expect(
        container
            .read(collectionWorkspaceArgsByTabIdProvider)
            .values
            .single
            .slug,
        'zurich-1953',
      );
      expect(reader.freshReads, greaterThanOrEqualTo(3));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('My Likes selects the existing Library destination', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    late BuildContext context;
    await mount(
      tester,
      container,
      Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      ),
    );
    await container.read(desktopEditorialLinkOpenerProvider)(
      context,
      Uri.parse('https://chessever.com/app/my-likes'),
    );
    expect(container.read(desktopTabsProvider).active?.kind, TabKind.library);
    expect(
      container.read(libraryDestinationRequestProvider)?.$2,
      '__library_my_likes__',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('Miniatures reuses the native collection tab', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    late BuildContext context;
    await mount(
      tester,
      container,
      Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      ),
    );
    final opener = container.read(desktopEditorialLinkOpenerProvider);
    final uri = Uri.parse('https://chessever.com/app/miniatures');
    await opener(context, uri);
    final first = container.read(desktopTabsProvider).active!;
    expect(first.kind, TabKind.smartGames);
    expect(
      container.read(desktopSmartGamesTypeByTabIdProvider)[first.id],
      PremiumGamesType.miniatures,
    );
    await opener(context, uri);
    expect(container.read(desktopTabsProvider).activeId, first.id);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
