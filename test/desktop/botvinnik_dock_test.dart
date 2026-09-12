import 'package:chessever/chat/chat_api.dart';
import 'package:chessever/desktop/shell/desktop_main_routes.dart';
import 'package:chessever/desktop/shell/desktop_sidebar.dart';
import 'package:chessever/chat/chat_references.dart';
import 'package:chessever/desktop/state/botvinnik_dock.dart';
import 'package:chessever/desktop/state/botvinnik_reference_router.dart';
import 'package:chessever/desktop/widgets/botvinnik/botvinnik_dock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// Allowance fixtures; the copy must echo whatever the API sends.
const Map<String, dynamic> _freeFixture = {
  'limit': 37,
  'used': 12,
  'remaining': 25,
  'isPremium': false,
};
const Map<String, dynamic> _premiumFixture = {
  'limit': 91,
  'used': 8,
  'remaining': 83,
  'isPremium': true,
};
const Map<String, dynamic> _freeExhaustedFixture = {
  'limit': 37,
  'used': 37,
  'remaining': 0,
  'isPremium': false,
};
const Map<String, dynamic> _premiumExhaustedFixture = {
  'limit': 91,
  'used': 91,
  'remaining': 0,
  'isPremium': true,
};
const Map<String, dynamic> _upgradeFixture = {
  'limit': 0,
  'used': 0,
  'remaining': 0,
  'isPremium': false,
};

ChatQuotaStatus _quota(Map<String, dynamic> json) =>
    ChatQuotaStatus.fromJson(json);

void main() {
  group('allowance copy', () {
    test('free and premium lines render the API numbers', () {
      expect(
        botvinnikAllowanceSpan(_quota(_freeFixture)).toPlainText(),
        '25 of 37 messages left today',
      );
      expect(
        botvinnikAllowanceSpan(_quota(_premiumFixture)).toPlainText(),
        'Premium: 83 of 91 messages left today',
      );
    });

    test('exhausted and upgrade-required lines are distinct', () {
      final exhausted =
          botvinnikAllowanceSpan(_quota(_freeExhaustedFixture)).toPlainText();
      final upgrade =
          botvinnikAllowanceSpan(_quota(_upgradeFixture)).toPlainText();
      expect(exhausted, 'no messages left today');
      expect(upgrade, isNot(exhausted));
      expect(upgrade, contains('not in your plan'));
    });

    test('composer notices differ for each gate and name the limit', () {
      final now = DateTime(2026, 9, 12, 10);
      final signedOut = botvinnikComposerNotice(
        ChatComposerAccess.signedOut,
        null,
        now,
      );
      final free = botvinnikComposerNotice(
        ChatComposerAccess.exhausted,
        _quota(_freeExhaustedFixture),
        now,
      );
      final premium = botvinnikComposerNotice(
        ChatComposerAccess.exhausted,
        _quota(_premiumExhaustedFixture),
        now,
      );
      final upgrade = botvinnikComposerNotice(
        ChatComposerAccess.upgradeRequired,
        _quota(_upgradeFixture),
        now,
      );

      expect(
        botvinnikComposerNotice(ChatComposerAccess.enabled, null, now),
        isNull,
      );
      expect(signedOut, contains('draft stays'));
      expect(free, contains('all 37 messages'));
      expect(premium, contains('all 91 Premium messages'));
      expect(upgrade, contains('Premium adds a daily allowance'));
      expect({signedOut, free, premium, upgrade}, hasLength(4));
      for (final copy in [signedOut, free, premium, upgrade]) {
        expect(copy, isNot(contains('—')));
      }
    });

    test('reset labels read in local time', () {
      final now = DateTime(2026, 9, 12, 10);
      expect(
        botvinnikResetLabel(DateTime(2026, 9, 12, 23, 30), now),
        'Resets 23:30',
      );
      expect(
        botvinnikResetLabel(DateTime(2026, 9, 13, 0, 0), now),
        'Resets tomorrow 00:00',
      );
    });
  });

  group('launch contexts', () {
    test('home launch identifies the home screen', () {
      expect(botvinnikHomeScreenContext.toJson(), {
        'schemaVersion': 1,
        'screen': 'home',
      });
    });

    test('tournament launch carries event and selected tour', () {
      final context = botvinnikTournamentScreenContext(
        eventId: 'group-1',
        eventName: 'Norway Chess 2026',
        tournamentId: 'tour-open',
        tournamentName: 'Open',
      );
      expect(context.toJson(), {
        'schemaVersion': 1,
        'screen': 'tournament',
        'eventId': 'group-1',
        'eventName': 'Norway Chess 2026',
        'tournamentId': 'tour-open',
        'tournamentName': 'Open',
      });
      expect(
        botvinnikTournamentScreenContext(
          eventId: 'group-1',
          eventName: 'Norway Chess 2026',
          tournamentId: '',
          tournamentName: ' ',
        ).toJson(),
        isNot(contains('tournamentId')),
      );
    });

    test('player launch prefers FIDE, then gamebase, then memorial id', () {
      expect(
        botvinnikPlayerScreenContext(
          playerName: 'Carlsen, Magnus',
          fideId: 1503014,
          gamebasePlayerId: 'gb-9',
        ).playerId,
        '1503014',
      );
      expect(
        botvinnikPlayerScreenContext(
          playerName: 'Tal, Mikhail',
          fideId: 0,
          gamebasePlayerId: 'gb-9',
          memorialRouteId: 'tal',
        ).playerId,
        'gb-9',
      );
      expect(
        botvinnikPlayerScreenContext(
          playerName: 'Tal, Mikhail',
          memorialRouteId: 'tal',
        ).playerId,
        'tal',
      );
    });

    test('the empty state names the launch subject', () {
      expect(botvinnikContextSubject(null), isNull);
      expect(
        botvinnikContextSubject(
          botvinnikPlayerScreenContext(playerName: 'Ju Wenjun'),
        ),
        'Ju Wenjun',
      );
    });
  });

  group('references', () {
    test('coordinator links for game, event, tournament and round', () {
      expect(
        botvinnikReferenceDeepLink(
          const ChatReference(type: 'game', id: 'g1', label: 'A vs B'),
        ).toString(),
        'https://chessever.com/games/g1',
      );
      expect(
        botvinnikReferenceDeepLink(
          const ChatReference(type: 'event', id: 'e1', label: 'Event'),
        ).toString(),
        'https://chessever.com/broadcast/e1',
      );
      expect(
        botvinnikReferenceDeepLink(
          const ChatReference(type: 'tournament', id: 't1', label: 'Open'),
        ).toString(),
        'https://chessever.com/broadcast/t1',
      );
      expect(
        botvinnikReferenceDeepLink(
          const ChatReference(
            type: 'round',
            id: 'r1',
            label: 'Round 1',
            tourId: 't1',
          ),
        ).toString(),
        'https://chessever.com/broadcast/t1',
      );
      expect(
        botvinnikReferenceDeepLink(
          const ChatReference(type: 'round', id: 'r1', label: 'Round 1'),
        ),
        isNull,
      );
    });

    test('openings stay plain text until a destination is plugged in', () {
      const opening = ChatReference(type: 'opening', id: 'B14', label: 'B14');
      expect(const DesktopBotvinnikReferenceRouter().canOpen(opening), isFalse);

      final withSmartEvents = DesktopBotvinnikReferenceRouter(
        openingOpener: (ref, code) async {},
      );
      expect(withSmartEvents.canOpen(opening), isTrue);
      expect(
        withSmartEvents.canOpen(
          const ChatReference(type: 'opening', id: 'b14', label: 'b14'),
        ),
        isTrue,
      );
      for (final id in ['B1', 'BB14']) {
        expect(
          withSmartEvents.canOpen(
            ChatReference(type: 'opening', id: id, label: id),
          ),
          isFalse,
        );
      }
    });

    test('an unroutable reference is not linkified', () {
      const references = [
        ChatReference(type: 'opening', id: 'B14', label: 'Caro-Kann'),
      ];
      const router = DesktopBotvinnikReferenceRouter();
      final openable = references.where(router.canOpen).toList();
      final result = integrateChatReferences('The Caro-Kann held.', openable);
      expect(result.markdown, 'The Caro-Kann held.');
    });

    test('the opening seam provider defaults to no destination', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(botvinnikOpeningReferenceOpenerProvider), isNull);
    });
  });

  group('shell registration', () {
    test('Botvinnik is a sidebar action under Feedback, not a route', () {
      final labels = debugDesktopSidebarLabelsInOrder();
      expect(labels[labels.indexOf('Feedback') + 1], 'Botvinnik');
      expect(debugDesktopSidebarPaneForLabel('Botvinnik'), isNull);
      expect(
        desktopMainRoutes.map((route) => route.label),
        isNot(contains('Botvinnik')),
      );
    });

    test('dock width stays inside its bounds and open asks for focus', () {
      final notifier = BotvinnikDockNotifier();
      addTearDown(notifier.dispose);
      notifier.setWidth(10);
      expect(notifier.state.width, kBotvinnikDockMinWidth);
      notifier.setWidth(5000);
      expect(notifier.state.width, kBotvinnikDockMaxWidth);
      final before = notifier.state.focusRequest;
      notifier.open();
      expect(notifier.state.open, isTrue);
      expect(notifier.state.focusRequest, before + 1);
    });
  });
}
