import 'package:chessever/chat/chat_api.dart';
import 'package:chessever/chat/chat_references.dart';
import 'package:flutter_test/flutter_test.dart';

// Allowance figures below are fixtures shaped like the Worker's quota
// payload. None of them is a product constant.
const Map<String, dynamic> _openFixture = {
  'limit': 11,
  'used': 4,
  'remaining': 7,
  'isPremium': false,
  'resetsAt': '2026-09-13T00:00:00.000Z',
};
const Map<String, dynamic> _exhaustedFixture = {
  'limit': 11,
  'used': 11,
  'remaining': 0,
  'isPremium': false,
  'resetsAt': '2026-09-13T00:00:00.000Z',
};
const Map<String, dynamic> _premiumExhaustedFixture = {
  'limit': 73,
  'used': 73,
  'remaining': 0,
  'isPremium': true,
  'resetsAt': '2026-09-13T00:00:00.000Z',
};
const Map<String, dynamic> _upgradeFixture = {
  'limit': 0,
  'used': 0,
  'remaining': 0,
  'isPremium': false,
};

void main() {
  group('NDJSON stream parsing', () {
    test('parses start, delta, references, done and error events', () {
      final events =
          [
            '{"type":"start","title":"Norway Chess","quota":{"limit":11,"used":5,"remaining":6,"isPremium":false}}',
            '{"type":"delta","text":"Carlsen"}',
            '{"type":"references","references":[{"type":"player","id":"1503014","label":"Carlsen, Magnus"}]}',
            '{"type":"done","quota":{"limit":11,"used":5,"remaining":6,"isPremium":false}}',
            '{"type":"error","message":"Upstream failed"}',
          ].map(parseChatStreamLine).toList();

      expect(events.map((event) => event!.type), [
        'start',
        'delta',
        'references',
        'done',
        'error',
      ]);
      expect(events[0]!.data['title'], 'Norway Chess');
      expect(events[1]!.data['text'], 'Carlsen');
      expect(events[2]!.data['references'], hasLength(1));
      expect(events[4]!.data['message'], 'Upstream failed');
    });

    test('skips blank lines and lines that are not a JSON object', () {
      expect(parseChatStreamLine(''), isNull);
      expect(parseChatStreamLine('   '), isNull);
      expect(parseChatStreamLine('[1, 2]'), isNull);
      expect(parseChatStreamLine('{"type":"delta","te'), isNull);
    });

    test('keeps unknown event types so the consumer can ignore them', () {
      expect(parseChatStreamLine('{"type":"heartbeat"}')!.type, 'heartbeat');
    });

    test('a truncated final line ends the stream without throwing', () async {
      final events =
          await decodeChatStreamLines(
            Stream<String>.fromIterable(const [
              '{"type":"start"}',
              '',
              '{"type":"delta","text":"Carl"}',
              '{"type":"delta","text":"sen wi',
            ]),
          ).toList();

      expect(events.map((event) => event.type), ['start', 'delta']);
    });
  });

  group('composer access', () {
    test('signed-out users get the sign-in path before any quota check', () {
      expect(
        chatComposerAccess(
          isSignedIn: false,
          quota: ChatQuotaStatus.fromJson(_openFixture),
        ),
        ChatComposerAccess.signedOut,
      );
    });

    test('an allowance with messages left keeps the composer open', () {
      expect(
        chatComposerAccess(
          isSignedIn: true,
          quota: ChatQuotaStatus.fromJson(_openFixture),
        ),
        ChatComposerAccess.enabled,
      );
    });

    test('free and premium exhaustion are exhausted, not upgrade', () {
      expect(
        chatComposerAccess(
          isSignedIn: true,
          quota: ChatQuotaStatus.fromJson(_exhaustedFixture),
        ),
        ChatComposerAccess.exhausted,
      );
      expect(
        chatComposerAccess(
          isSignedIn: true,
          quota: ChatQuotaStatus.fromJson(_premiumExhaustedFixture),
        ),
        ChatComposerAccess.exhausted,
      );
    });

    test('a plan with no allowance at all requires an upgrade', () {
      expect(
        chatComposerAccess(
          isSignedIn: true,
          quota: ChatQuotaStatus.fromJson(_upgradeFixture),
        ),
        ChatComposerAccess.upgradeRequired,
      );
    });
  });

  group('opening reference guard', () {
    test('accepts canonical ECO codes', () {
      expect(isChatOpeningReferenceId('B14'), isTrue);
      expect(isChatOpeningReferenceId('A00'), isTrue);
      expect(isChatOpeningReferenceId('E99'), isTrue);
    });

    test('normalizes case and whitespace like mobile', () {
      expect(isChatOpeningReferenceId('b14'), isTrue);
      expect(isChatOpeningReferenceId(' c42 '), isTrue);
      expect(normalizeChatOpeningReferenceId(' b14 '), 'B14');
    });

    test('rejects short, long and out-of-range codes', () {
      expect(isChatOpeningReferenceId('B1'), isFalse);
      expect(isChatOpeningReferenceId('BB14'), isFalse);
      expect(isChatOpeningReferenceId('F10'), isFalse);
      expect(isChatOpeningReferenceId(''), isFalse);
    });
  });

  group('reconcile before resend', () {
    const earlier = ChatMessage(
      id: 'm1',
      role: 'user',
      content: 'Who won round 3?',
    );
    const earlierAnswer = ChatMessage(
      id: 'm2',
      role: 'assistant',
      content: 'Gukesh.',
    );

    test('a question stored after the known history was delivered', () {
      expect(
        chatReconcilePendingSend(
          serverMessages: const [
            earlier,
            earlierAnswer,
            ChatMessage(id: 'm3', role: 'user', content: 'And round 4?'),
          ],
          pendingContent: '  And round 4? ',
          knownMessageIds: const {'m1', 'm2'},
        ),
        ChatReconcileOutcome.alreadyDelivered,
      );
    });

    test('an identical older question does not count as delivery', () {
      expect(
        chatReconcilePendingSend(
          serverMessages: const [earlier, earlierAnswer],
          pendingContent: 'Who won round 3?',
          knownMessageIds: const {'m1', 'm2'},
        ),
        ChatReconcileOutcome.notDelivered,
      );
    });

    test('a question missing from history was not delivered', () {
      expect(
        chatReconcilePendingSend(
          serverMessages: const [earlier, earlierAnswer],
          pendingContent: 'And round 4?',
        ),
        ChatReconcileOutcome.notDelivered,
      );
    });
  });
}
