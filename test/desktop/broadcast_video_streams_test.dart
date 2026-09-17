import 'dart:convert';

import 'package:chessever/desktop/services/broadcast_video_streams.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

BroadcastVideoStream stream({
  required String id,
  String? label,
  String? countryCode,
  String? language,
  Set<BroadcastVideoClientPlatform>? platforms,
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
    language: language,
    platforms: platforms,
    provider: provider,
    sourceId: resolvedSourceId,
    url: url ?? 'https://example.com/$resolvedSourceId',
    publication: publication,
    audience: audience,
    preferred: preferred,
  );
}

const BroadcastVideoAudience _fideAudience = BroadcastVideoAudience(
  channelId: fideYoutubeChannelId,
  count: 379000,
  checkedOn: '2026-09-15',
);

const Set<BroadcastVideoClientPlatform> _desktopWeb =
    <BroadcastVideoClientPlatform>{
      BroadcastVideoClientPlatform.web,
      BroadcastVideoClientPlatform.desktop,
    };

BroadcastVideoStream fideMain() => stream(
  id: 'fide-main',
  label: 'FIDE',
  audience: _fideAudience,
  publication: const BroadcastVideoPublication(
    language: 'en',
    title:
        '♟ FIDE Chess Olympiad 2026 | Round 1 | Gukesh, Sindarov, Bibisara & more',
  ),
);

BroadcastVideoStream camera(int number, {String? id}) => stream(
  id: id ?? 'camera-$number',
  label: 'Official stream $number',
  audience: _fideAudience,
  platforms: _desktopWeb,
  publication: BroadcastVideoPublication(
    title: 'FIDE Chess Olympiad 2026 | Round 1 |  Stream $number | Open',
  ),
);

void main() {
  group('broadcastVideoEmbedPageUri', () {
    test('frames the stream through the site, never a provider top-level', () {
      final uri = broadcastVideoEmbedPageUri(
        scope: 'round',
        scopeId: 'r1',
        streamId: 'twitch-chess',
        play: true,
      );
      expect(
        uri.toString(),
        'https://chessever.com/embed/video/round/r1/twitch-chess?autoplay=1',
      );
      expect(broadcastEmbedPageHosts, contains(uri.host));
      expect(
        broadcastVideoEmbedPageUri(
          scope: 'tour',
          scopeId: 'a b/c',
          streamId: 'x',
          play: false,
        ).toString(),
        'https://chessever.com/embed/video/tour/a%20b%2Fc/x?autoplay=0',
      );
    });

    test('keeps provider minimum player sizes for the rail', () {
      expect(BroadcastVideoProvider.twitch.minWidth, 400);
      expect(BroadcastVideoProvider.twitch.minHeight, 300);
      expect(BroadcastVideoProvider.youtube.minWidth, 200);
      expect(BroadcastVideoProvider.kick.minHeight, 200);
    });
  });

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

    test('Uzbek editor tags group under the Uzbekistan flag', () {
      final detected = broadcastStreamLanguage(
        stream(id: 'room', label: 'Chess Room', language: 'uz'),
      );
      expect(detected.code, 'uz');
      expect(detected.label, 'Uzbek');
      expect(detected.countryCode, 'UZ');
    });

    test('stream language tag is used when publication is missing', () {
      final detected = broadcastStreamLanguage(
        stream(id: 'tagged', label: 'Official feed', language: 'hi'),
      );
      expect(detected.code, 'hi');
      expect(detected.label, 'Hindi');
      expect(detected.countryCode, 'IN');
    });

    test('stream language tag beats a conflicting title', () {
      expect(
        broadcastStreamLanguage(
          stream(
            id: 'tagged',
            label: 'Official feed',
            language: 'es',
            publication: const BroadcastVideoPublication(
              title: 'English commentary',
            ),
          ),
        ).code,
        'es',
      );
    });

    test('language region tags and names resolve like the web', () {
      expect(
        broadcastStreamLanguage(
          stream(id: 'one', label: 'Official', language: 'en-IN'),
        ).code,
        'en',
      );
      expect(
        broadcastStreamLanguage(
          stream(id: 'two', label: 'Official', language: 'spanish'),
        ).code,
        'es',
      );
    });

    test('stream language groups without a language word in the label', () {
      final groups = groupBroadcastVideoStreams(<BroadcastVideoStream>[
        stream(id: 'a', label: 'Board 1', language: 'en'),
        stream(id: 'b', label: 'Board 2', language: 'en'),
        stream(id: 'c', label: 'Mesa', language: 'es'),
      ]);
      expect(groups.map((group) => group.label).toList(), <String>[
        'English',
        'Spanish',
      ]);
      expect(groups.first.countryCode, 'GB');
      expect(groups.last.countryCode, 'ES');
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

    test('FIDE main wins for English memory or no memory', () {
      final olympiad = <BroadcastVideoStream>[
        stream(id: 'english', label: 'Other English', language: 'en'),
        stream(
          id: 'spanish',
          label: 'Español',
          publication: const BroadcastVideoPublication(language: 'es'),
        ),
        camera(1),
        fideMain(),
      ];
      expect(
        resolveBroadcastVideoSelection(olympiad, selectedId: 'camera-1')?.id,
        'camera-1',
      );
      expect(
        resolveBroadcastVideoSelection(olympiad, language: 'es')?.id,
        'spanish',
      );
      expect(
        resolveBroadcastVideoSelection(olympiad, language: 'en')?.id,
        'fide-main',
      );
      expect(resolveBroadcastVideoSelection(olympiad)?.id, 'fide-main');
    });
  });

  group('toolbar grouping', () {
    test('recognises only exact FIDE commentary and numbered cameras', () {
      expect(isFideMainCommentary(fideMain()), isTrue);
      expect(fideCameraNumber(camera(12)), 12);
      expect(
        fideCameraNumber(
          camera(8).copyWith(
            publication: const BroadcastVideoPublication(
              title: 'FIDE Chess Olympiad 2026 | Round 1 | Open Stream 8',
            ),
          ),
        ),
        8,
      );
      expect(
        fideCameraNumber(
          camera(2).copyWith(
            platforms: <BroadcastVideoClientPlatform>{
              BroadcastVideoClientPlatform.mobile,
            },
          ),
        ),
        isNull,
      );
      expect(
        fideCameraNumber(
          stream(
            id: 'camera-2',
            label: 'Official stream 2',
            audience: _fideAudience,
            publication: const BroadcastVideoPublication(
              title: 'FIDE Chess Olympiad 2026 | Round 1 |  Stream 2 | Open',
            ),
          ),
        ),
        isNull,
      );
      expect(
        fideCameraNumber(
          camera(2).copyWith(
            publication: const BroadcastVideoPublication(
              language: 'en',
              title: 'FIDE Chess Olympiad 2026 | Round 1 |  Stream 2 | Open',
            ),
          ),
        ),
        isNull,
      );
      expect(
        fideCameraNumber(
          camera(2).copyWith(
            audience: const BroadcastVideoAudience(
              channelId: 'UC1111111111111111111111',
            ),
          ),
        ),
        isNull,
      );
      expect(isFideMainCommentary(camera(1)), isFalse);
    });

    test('treats official pairing-title board feeds as numbered cameras', () {
      final colombia = stream(
        id: 'colombia',
        label: 'Colombia vs Hungary',
        audience: _fideAudience,
        platforms: _desktopWeb,
        publication: const BroadcastVideoPublication(
          title:
              'FIDE Chess Olympiad 2026 | Round 2 | Colombia vs Hungary | Open',
        ),
      );
      final ecuador = stream(
        id: 'ecuador',
        label: 'Ecuador vs Uzbekistan',
        audience: _fideAudience,
        platforms: _desktopWeb,
        publication: const BroadcastVideoPublication(
          title:
              'FIDE Chess Olympiad 2026 | Round 2 |  Ecuador vs Uzbekistan | Women',
        ),
      );
      final groups = toolbarBroadcastVideoGroups(
        <BroadcastVideoStream>[
          colombia,
          stream(
            id: 'english',
            label: 'Other English',
            language: 'en',
          ),
          ecuador,
          fideMain(),
        ],
        const <String>[],
        20,
      );
      expect(
        groups.map((group) => group.kind).toList(),
        <BroadcastToolbarVideoKind>[
          BroadcastToolbarVideoKind.fide,
          BroadcastToolbarVideoKind.language,
          BroadcastToolbarVideoKind.cameras,
        ],
      );
      expect(groups.last.streams.map((stream) => stream.id), <String>[
        'colombia',
        'ecuador',
      ]);
      expect(groups.last.streams.map(fideCameraNumber).toList(), <int>[1, 2]);
    });

    test('keeps FIDE main first and one numeric camera group last', () {
      final groups = toolbarBroadcastVideoGroups(
        <BroadcastVideoStream>[
          camera(10),
          stream(
            id: 'english',
            label: 'Other English',
            publication: const BroadcastVideoPublication(language: 'en'),
            audience: const BroadcastVideoAudience(
              channelId: 'UC0000000000000000000000',
              count: 900000,
              checkedOn: '2026-09-15',
            ),
          ),
          camera(2),
          stream(
            id: 'spanish',
            label: 'Español',
            publication: const BroadcastVideoPublication(language: 'es'),
          ),
          fideMain(),
          camera(1),
        ],
        const <String>[],
        20,
      );
      expect(
        groups.map((group) => group.kind).toList(),
        <BroadcastToolbarVideoKind>[
          BroadcastToolbarVideoKind.fide,
          BroadcastToolbarVideoKind.language,
          BroadcastToolbarVideoKind.language,
          BroadcastToolbarVideoKind.cameras,
        ],
      );
      expect(groups.first.streams.map((stream) => stream.id), <String>[
        'fide-main',
      ]);
      expect(groups.last.streams.map(fideCameraNumber).toList(), <int>[
        1,
        2,
        10,
      ]);
    });

    test('moves a selected non-English language ahead of FIDE', () {
      final groups = toolbarBroadcastVideoGroups(
        <BroadcastVideoStream>[
          stream(
            id: 'english',
            label: 'Other English',
            publication: const BroadcastVideoPublication(language: 'en'),
          ),
          camera(2),
          stream(
            id: 'spanish',
            label: 'Español',
            publication: const BroadcastVideoPublication(language: 'es'),
          ),
          fideMain(),
        ],
        const <String>[],
        20,
        selectedId: 'spanish',
      );
      expect(groups.first.streams.first.id, 'spanish');
      expect(groups[1].kind, BroadcastToolbarVideoKind.fide);
      expect(groups.last.kind, BroadcastToolbarVideoKind.cameras);
    });

    test('camera pins move out and never dissolve the remaining group', () {
      for (final capacity in <int>[0, 2, 20]) {
        final groups = toolbarBroadcastVideoGroups(
          <BroadcastVideoStream>[
            camera(3),
            stream(
              id: 'english',
              label: 'Other English',
              publication: const BroadcastVideoPublication(language: 'en'),
            ),
            camera(1),
            camera(2),
            fideMain(),
          ],
          const <String>['camera-2'],
          capacity,
        );
        expect(groups.first.kind, BroadcastToolbarVideoKind.camera);
        expect(groups.first.cameraNumber, 2);
        expect(groups.last.kind, BroadcastToolbarVideoKind.cameras);
        expect(groups.last.streams.map(fideCameraNumber).toList(), <int>[1, 3]);
      }
    });

    test('unwraps languages only when every stream fits', () {
      final streams = <BroadcastVideoStream>[
        for (final entry in <(String, String)>[
          ('0', 'en'),
          ('1', 'en'),
          ('2', 'en'),
          ('3', 'en'),
          ('4', 'en'),
          ('5', 'pt'),
          ('6', 'es'),
          ('7', 'es'),
          ('8', 'es'),
          ('9', 'ru'),
        ])
          stream(
            id: entry.$1,
            label: 'Channel ${entry.$1}',
            publication: BroadcastVideoPublication(language: entry.$2),
          ),
      ];
      final languageGroups =
          groupBroadcastVideoStreams(streams)
              .map(
                (group) => BroadcastToolbarVideoGroup(
                  key: group.key,
                  code: group.code,
                  label: group.label,
                  countryCode: group.countryCode,
                  streams: group.streams,
                  kind: BroadcastToolbarVideoKind.language,
                ),
              )
              .toList();
      final individual = progressiveBroadcastStreamGroups(
        languageGroups,
        const <String>[],
        streams.length,
      );
      expect(individual, hasLength(streams.length));
      expect(individual.every((group) => group.streams.length == 1), isTrue);
      final compact = progressiveBroadcastStreamGroups(
        languageGroups,
        const <String>[],
        streams.length - 1,
      );
      expect(
        compact.map((group) => <Object>[group.label, group.streams.length]),
        <List<Object>>[
          <Object>['English', 5],
          <Object>['Portuguese', 1],
          <Object>['Russian', 1],
          <Object>['Spanish', 3],
        ],
      );
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
      expect(resolved.streams.single.platforms, isNull);
      expect(resolved.source?.scope, 'round');
      expect(resolved.source?.id, 'r1');
    });

    test('reads platform allow-lists and top-level language', () {
      final stream = BroadcastVideoStream.fromJson(<String, Object?>{
        'id': 'cam',
        'label': 'Official',
        'provider': 'youtube',
        'sourceId': 'abcdefghijk',
        'url': 'https://www.youtube.com/watch?v=abcdefghijk',
        'language': 'en-IN',
        'platforms': <String>['web', 'desktop'],
        'audience': <String, Object?>{
          'channelId': fideYoutubeChannelId,
          'count': 10,
          'checkedOn': '2026-09-15',
        },
      });
      expect(stream, isNotNull);
      expect(stream!.language, 'en-IN');
      expect(stream.platforms, _desktopWeb);
      expect(
        broadcastStreamSupportsPlatform(
          stream,
          BroadcastVideoClientPlatform.mobile,
        ),
        isFalse,
      );
      expect(
        BroadcastVideoStream.fromJson(<String, Object?>{
          'id': 'bad',
          'label': 'Official',
          'provider': 'youtube',
          'sourceId': 'abcdefghijk',
          'url': 'https://www.youtube.com/watch?v=abcdefghijk',
          'platforms': <String>['console'],
        }),
        isNull,
      );
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
