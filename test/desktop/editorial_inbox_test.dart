import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/services/editorial/inbox_message.dart';
import 'package:chessever/desktop/services/editorial/inbox_provider.dart';
import 'package:chessever/desktop/widgets/editorial/inbox_dialog.dart';
import '../inbox_fakes.dart';

void main() {
  testWidgets(
    'removing the last unread message clears every desktop Inbox dot',
    (tester) async {
      final source = FakeInboxSource(), cache = FakeInboxCache();
      final controller = InboxController(
        ownerId: inboxOwnerA,
        source: source,
        cache: cache,
      );
      await controller.start();
      final content = Column(
        children: [
          const DesktopInboxUnreadAnchor(
            child: SizedBox(width: 34, height: 34),
          ),
          const Expanded(child: DesktopInboxDialog()),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [inboxProvider.overrideWith((ref) => controller)],
          child: FTheme(
            data: FThemes.zinc.dark,
            child: MaterialApp(home: Scaffold(body: content)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(inboxFixture(inboxIdA).title));
      await tester.pumpAndSettle();
      expect(controller.state.hasUnread, true);
      expect(find.byType(DesktopInboxDot), findsWidgets);
      source.rows[inboxOwnerA] = [
        inboxFixture(inboxIdA, readAt: inboxReadTime),
      ];
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(controller.state.hasUnread, false);
      expect(find.byType(DesktopInboxDot), findsNothing);
      source.rows[inboxOwnerA] = [];
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(
        find.text('This message has been taken back or removed.'),
        findsOneWidget,
      );
      expect(find.byType(DesktopInboxDot), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'an open message renders and acknowledges its new publication after editing',
    (tester) async {
      final source = FakeInboxSource(), cache = FakeInboxCache();
      final controller = InboxController(
        ownerId: inboxOwnerA,
        source: source,
        cache: cache,
      );
      await controller.start();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [inboxProvider.overrideWith((ref) => controller)],
          child: FTheme(
            data: FThemes.zinc.dark,
            child: const MaterialApp(
              home: Scaffold(body: DesktopInboxDialog()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(inboxFixture(inboxIdA).title));
      await tester.pumpAndSettle();
      final count = source.marks.length;
      source.markOverride = (_, _) async => DateTime.utc(2026, 11);
      source.rows[inboxOwnerA] = [
        InboxMessage(
          id: inboxIdA,
          title: 'Edited title',
          body: 'Republished full text',
          publishedAt: DateTime.utc(2026, 10),
        ),
      ];
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.text('Republished full text'), findsWidgets);
      expect(source.marks.length, count + 1);
      expect(controller.state.hasUnread, false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
