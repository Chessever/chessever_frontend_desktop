import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/desktop_deep_link_router.dart';

void main() {
  group('parseDesktopBroadcastDeepLink', () {
    test('parses chessever.com broadcast slug and tour id links', () {
      final parsed = parseDesktopBroadcastDeepLink(
        Uri.parse(
          'https://chessever.com/broadcast/45-zalakarosi-sakkfesztival--barczay-laszlo-emlekverseny/4TdB92Cj',
        ),
      );

      expect(parsed, isNotNull);
      expect(
        parsed!.slug,
        '45-zalakarosi-sakkfesztival--barczay-laszlo-emlekverseny',
      );
      expect(parsed.id, '4TdB92Cj');
    });

    test('parses legacy web links with only an event id', () {
      final parsed = parseDesktopBroadcastDeepLink(
        Uri.parse('https://www.chessever.com/broadcast/group_event_123'),
      );

      expect(parsed, isNotNull);
      expect(parsed!.slug, isNull);
      expect(parsed.id, 'group_event_123');
    });

    test('parses custom-scheme broadcast links', () {
      final parsed = parseDesktopBroadcastDeepLink(
        Uri.parse('chessever://broadcast/event-slug/4TdB92Cj'),
      );

      expect(parsed, isNotNull);
      expect(parsed!.slug, 'event-slug');
      expect(parsed.id, '4TdB92Cj');
    });

    test('ignores unrelated chessever links', () {
      expect(
        parseDesktopBroadcastDeepLink(
          Uri.parse('https://chessever.com/pricing'),
        ),
        isNull,
      );
      expect(
        parseDesktopBroadcastDeepLink(
          Uri.parse('https://example.com/broadcast/x/y'),
        ),
        isNull,
      );
    });
  });

  group('parseDesktopGameDeepLink', () {
    test('parses web game links and keeps tour/round query context', () {
      final parsed = parseDesktopGameDeepLink(
        Uri.parse(
          'https://chessever.com/games/5Hkz1dp9?tour=12th-serbian-cup-svetozar-gligoric--open&round=round-5',
        ),
      );

      expect(parsed, isNotNull);
      expect(parsed!.id, '5Hkz1dp9');
      expect(parsed.tour, '12th-serbian-cup-svetozar-gligoric--open');
      expect(parsed.round, 'round-5');
    });

    test('parses custom-scheme game links', () {
      final parsed = parseDesktopGameDeepLink(
        Uri.parse('chessever://games/5Hkz1dp9?tour=open&round=round-5'),
      );

      expect(parsed, isNotNull);
      expect(parsed!.id, '5Hkz1dp9');
      expect(parsed.tour, 'open');
      expect(parsed.round, 'round-5');
    });

    test('ignores unrelated game-looking links', () {
      expect(
        parseDesktopGameDeepLink(
          Uri.parse('https://example.com/games/5Hkz1dp9'),
        ),
        isNull,
      );
      expect(
        parseDesktopGameDeepLink(Uri.parse('https://chessever.com/pricing')),
        isNull,
      );
    });
  });

  test('desktopDeepLinkUrisFromArguments keeps only supported deep links', () {
    final uris = desktopDeepLinkUrisFromArguments([
      '--updated',
      'C:/Users/me/game.pgn',
      'chessever://broadcast/event-slug/4TdB92Cj',
      'https://chessever.com/broadcast/slug/group_event_123',
      'https://chessever.com/games/5Hkz1dp9?tour=open&round=round-5',
      'https://chessever.com/pricing',
      'chessever://broadcast/event-slug/4TdB92Cj',
    ]);

    expect(uris.map((uri) => uri.toString()), [
      'chessever://broadcast/event-slug/4TdB92Cj',
      'https://chessever.com/broadcast/slug/group_event_123',
      'https://chessever.com/games/5Hkz1dp9?tour=open&round=round-5',
    ]);
  });
}
