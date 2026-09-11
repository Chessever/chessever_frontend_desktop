import 'dart:convert';

import 'package:chessever/desktop/services/broadcast_video_streams.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

BroadcastVideoStream stream({
  required String id,
  String? label,
  String? countryCode,
  BroadcastVideoProvider provider = BroadcastVideoProvider.youtube,
  String? sourceId,
  String? url,
  BroadcastVideoPublication? publication,
  BroadcastVideoAudience? audience,
  bool? preferred,
}) {
  final resolvedSourceId = sourceId ?? id;
  return BroadcastVideoStream(
    id: id,
    label: label ?? id,
    countryCode: countryCode,
    provider: provider,
    sourceId: resolvedSourceId,
    url: url ?? 'https://example.com/$resolvedSourceId',
    publication: publication,
    audience: audience,
    preferred: preferred,
  );
}

void main() {
  group('language detection', () {
    test('explicit metadata wins over the title', () {
      final detected = broadcastStreamLanguage(
        stream(
          id: 'one',
          label: 'Official',
          publication: const BroadcastVideoPublication(
            language: 'es',
            title: 'English commentary',
          ),
        ),
      );
      expect(detected.code, 'es');
      expect(detected.label, 'Spanish');
      expect(detected.countryCode, 'ES');
    });

    test('recognises a language word in title, description or label', () {
      expect(
        broadcastStreamLanguage(
          stream(
            id: 'two',
            label: 'Day 4',
            publication: const BroadcastVideoPublication(
              title: 'Global Chess League | English Stream',
            ),
          ),
        ).code,
        'en',
      );
      expect(
        broadcastStreamLanguage(
          stream(id: 'three', label: 'Technique · Hinglish'),
        ).code,
        'hinglish',
      );
    });

    test('a country alone never infers a language', () {
      final detected = broadcastStreamLanguage(
        stream(id: 'four', label: 'Official feed', countryCode: 'MY'),
      );
      expect(detected.code, 'und');
      final groups = groupBroadcastVideoStreams(<BroadcastVideoStream>[
        stream(id: 'four', label: 'Official feed', countryCode: 'MY'),
      ]);
      expect(groups.single.key, 'country-MY');
      expect(groups.single.label, 'Malaysia');
      expect(groups.single.countryCode, 'MY');
    });

    test('Malay-like words do not infer Malay', () {
      for (final label in <String>['Official feed', 'Malayalam commentary']) {
        expect(
          broadcastStreamLanguage(
            stream(
              id: 'five',
              label: label,
              publication: const BroadcastVideoPublication(language: 'zz'),
            ),
          ).code,
          'und',
        );
      }
    });
  });

  group('groupBroadcastVideoStreams', () {
    test('groups same-language streams, English first, audience ordered', () {
      final groups = groupBroadcastVideoStreams(<BroadcastVideoStream>[
        stream(
          id: 'es-1',
          label: 'Tablero · Spanish',
          audience: const BroadcastVideoAudience(
            channelId: 'es',
            count: 100,
            checkedOn: '2026-09-10',
          ),
        ),
        stream(
          id: 'en-small',
          label: 'Channel · English',
          audience: const BroadcastVideoAudience(
            channelId: 'en-small',
            count: 50,
            checkedOn: '2026-09-10',
          ),
        ),
        stream(
          id: 'en-large',
          label: 'Big channel · English',
          audience: const BroadcastVideoAudience(
            channelId: 'en-large',
            count: 500,
            checkedOn: '2026-09-10',
          ),
        ),
      ]);
      expect(groups.map((group) => group.key).toList(), <String>['en', 'es']);
      expect(groups.first.streams.map((entry) => entry.id).toList(), <String>[
        'en-large',
        'en-small',
      ]);
    });

    test('preferred flag leads its language group', () {
      final groups = groupBroadcastVideoStreams(<BroadcastVideoStream>[
        stream(id: 'en-1', label: 'A · English'),
        stream(id: 'en-2', label: 'B · English', preferred: true),
      ]);
      expect(groups.single.streams.first.id, 'en-2');
    });

    test('a repeated channel snapshot is only counted once', () {
      final groups = groupBroadcastVideoStreams(<BroadcastVideoStream>[
        stream(
          id: 'en-old',
          label: 'A · English',
          audience: const BroadcastVideoAudience(
            channelId: 'shared',
            count: 10,
            checkedOn: '2026-09-01',
          ),
        ),
        stream(
          id: 'en-new',
          label: 'A · English',
          audience: const BroadcastVideoAudience(
            channelId: 'shared',
            count: 900,
            checkedOn: '2026-09-10',
          ),
        ),
      ]);
      expect(groups.single.streams.first.id, 'en-new');
    });
  });

  group('resolveBroadcastVideoSelection', () {
    final streams = <BroadcastVideoStream>[
      stream(id: 'es', label: 'Tablero · Spanish', countryCode: 'ES'),
      stream(id: 'en', label: 'Channel · English', countryCode: 'GB'),
    ];

    test('exact pick wins', () {
      expect(
        resolveBroadcastVideoSelection(streams, selectedId: 'es')?.id,
        'es',
      );
    });

    test('remembered language group is the default', () {
      expect(resolveBroadcastVideoSelection(streams, language: 'en')?.id, 'en');
    });

    test('legacy country fallback precedes the first stream', () {
      expect(
        resolveBroadcastVideoSelection(streams, countryCode: 'ES')?.id,
        'es',
      );
    });

    test('falls back to the group order', () {
      expect(resolveBroadcastVideoSelection(streams)?.id, 'en');
    });
  });

  group('display name', () {
    test('strips only a recognised trailing language tag', () {
      expect(
        broadcastVideoStreamDisplayName(
          stream(
            id: 'a',
            label: 'Tech Mahindra Global Chess League · Hinglish',
          ),
        ),
        'Tech Mahindra Global Chess League',
      );
      expect(
        broadcastVideoStreamDisplayName(
          stream(id: 'b', label: 'Studio · Unknown'),
        ),
        'Studio · Unknown',
      );
      expect(
        broadcastVideoStreamTitle(
          stream(
            id: 'c',
            label: 'Channel · English',
            provider: BroadcastVideoProvider.twitch,
          ),
        ),
        'Channel · Twitch',
      );
    });
  });

  group('BroadcastVideoStreamsClient', () {
    test('asks the resolved round scope, then parses the payload', () async {
      late Uri requested;
      final client = BroadcastVideoStreamsClient(
        httpClient: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode(<String, Object?>{
              'source': <String, Object?>{'scope': 'round', 'id': 'r1'},
              'streams': <Object?>[
                <String, Object?>{
                  'id': 'twitch-chess',
                  'label': 'Channel · English',
                  'countryCode': 'GB',
                  'provider': 'twitch',
                  'sourceId': 'chess',
                  'url': 'https://www.twitch.tv/chess',
                  'preferred': true,
                },
                <String, Object?>{'id': 'broken'},
              ],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
      final resolved = await client.fetch(
        const BroadcastVideoScope(tourId: 't1', roundId: 'r1'),
      );
      expect(
        requested.toString(),
        'https://api.broadcast.chessever.com/api/broadcast/round/r1/video-streams',
      );
      expect(resolved.streams, hasLength(1));
      expect(resolved.streams.single.provider, BroadcastVideoProvider.twitch);
      expect(resolved.streams.single.preferred, isTrue);
      expect(resolved.source?.scope, 'round');
      expect(resolved.source?.id, 'r1');
    });

    test('falls back to the tour scope when the round is unknown', () async {
      late Uri requested;
      final client = BroadcastVideoStreamsClient(
        httpClient: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode(<String, Object?>{'streams': <Object?>[]}),
            200,
          );
        }),
      );
      await client.fetch(const BroadcastVideoScope(tourId: 't1'));
      expect(
        requested.toString(),
        'https://api.broadcast.chessever.com/api/broadcast/t1/video-streams',
      );
    });

    test('marks 4xx failures permanent so a stale panel is cleared', () async {
      final client = BroadcastVideoStreamsClient(
        httpClient: MockClient((_) async => http.Response('not found', 404)),
      );
      await expectLater(
        client.fetch(const BroadcastVideoScope(tourId: 't1')),
        throwsA(
          isA<BroadcastVideoStreamsException>().having(
            (error) => error.permanent,
            'permanent',
            isTrue,
          ),
        ),
      );
    });

    test('treats 5xx failures as transient', () async {
      final client = BroadcastVideoStreamsClient(
        httpClient: MockClient((_) async => http.Response('nope', 503)),
      );
      await expectLater(
        client.fetch(const BroadcastVideoScope(tourId: 't1')),
        throwsA(
          isA<BroadcastVideoStreamsException>().having(
            (error) => error.permanent,
            'permanent',
            isFalse,
          ),
        ),
      );
    });
  });

  group('watch URL', () {
    test('matches the canonical web watch path', () {
      expect(
        broadcastVideoWatchUri(
          scope: 'round',
          scopeId: 'r1',
          streamId: 'en',
        ).toString(),
        'https://chessever.com/watch/round/r1/en',
      );
    });
  });

  group('scope', () {
    test('uses the round path only when a round is known', () {
      expect(
        const BroadcastVideoScope(tourId: 't1', roundId: 'r1').apiPathSegments,
        <String>['round', 'r1'],
      );
      expect(const BroadcastVideoScope(tourId: 't1').apiPathSegments, <String>[
        't1',
      ]);
      expect(
        const BroadcastVideoScope(tourId: 't1', roundId: ' ').hasRound,
        isFalse,
      );
    });
  });
}
