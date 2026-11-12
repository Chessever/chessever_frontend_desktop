import 'dart:async';
import 'dart:convert';

import 'package:chessever/desktop/services/broadcast_video_streams.dart';
import 'package:chessever/desktop/state/broadcast_video_streams_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _combined = BroadcastVideoScope(
  tourId: 'combined',
  roundId: 'combined-r2',
);
const _origin = BroadcastVideoScope(tourId: 'group-c', roundId: 'group-c-r2');
const _key = (scope: _combined, gameId: 'mirror-game');
const _stream = <String, Object?>{
  'id': 'commentary',
  'label': 'Commentary',
  'provider': 'kick',
  'sourceId': 'commentary',
  'url': 'https://kick.com/commentary',
};

void main() {
  for (final assigned in [true, false]) {
    test(
      'explicit ${assigned ? 'stream' : 'disabled'} assignment never falls back',
      () async {
        var lookups = 0;
        final container = ProviderContainer(
          overrides: [
            broadcastVideoStreamsClientProvider.overrideWithValue(
              BroadcastVideoStreamsClient(
                httpClient: MockClient(
                  (_) async => http.Response(
                    jsonEncode({
                      'streams': assigned ? [_stream] : [],
                      'source': {'scope': 'tour', 'id': 'combined'},
                    }),
                    200,
                  ),
                ),
              ),
            ),
            broadcastVideoOriginLookupProvider.overrideWithValue((
              scope,
              gameId,
            ) async {
              lookups++;
              return _origin;
            }),
          ],
        );
        final sub = container.listen(
          broadcastVideoGameStreamsProvider(_key),
          (_, _) {},
        );
        final result = await container.read(
          broadcastVideoGameStreamsProvider(_key).future,
        );
        expect(result.source?.id, 'combined');
        expect(result.streams.length, assigned ? 1 : 0);
        expect(lookups, 0);
        sub.close();
        container.dispose();
      },
    );
  }

  test('unassigned Combined uses the resolved original round', () async {
    final paths = <String>[];
    var lookups = 0;
    final container = ProviderContainer(
      overrides: [
        broadcastVideoStreamsClientProvider.overrideWithValue(
          BroadcastVideoStreamsClient(
            httpClient: MockClient((request) async {
              paths.add(request.url.path);
              final original = request.url.path.contains('group-c-r2');
              return http.Response(
                jsonEncode({
                  'streams': original ? [_stream] : [],
                  'source':
                      original ? {'scope': 'tour', 'id': 'group-c'} : null,
                }),
                200,
              );
            }),
          ),
        ),
        broadcastVideoOriginLookupProvider.overrideWithValue((
          scope,
          gameId,
        ) async {
          expect(scope, _combined);
          expect(gameId, 'mirror-game');
          lookups++;
          return _origin;
        }),
      ],
    );
    final sub = container.listen(
      broadcastVideoGameStreamsProvider(_key),
      (_, _) {},
    );
    final result = await container.read(
      broadcastVideoGameStreamsProvider(_key).future,
    );
    expect(result.streams.single.id, 'commentary');
    expect(result.source?.id, 'group-c');
    expect(paths, [
      '/api/broadcast/round/combined-r2/video-streams',
      '/api/broadcast/round/group-c-r2/video-streams',
    ]);
    expect(lookups, 1);
    sub.close();
    container.dispose();
  });

  test(
    'closing while the direct request is pending starts no origin lookup',
    () async {
      final pending = Completer<http.Response>();
      var lookups = 0;
      final container = ProviderContainer(
        overrides: [
          broadcastVideoStreamsClientProvider.overrideWithValue(
            BroadcastVideoStreamsClient(
              httpClient: MockClient((_) => pending.future),
            ),
          ),
          broadcastVideoOriginLookupProvider.overrideWithValue((
            scope,
            gameId,
          ) async {
            lookups++;
            return _origin;
          }),
        ],
      );
      container.listen(broadcastVideoGameStreamsProvider(_key), (_, _) {});
      container.dispose();
      pending.complete(http.Response('{"streams":[],"source":null}', 200));
      await Future<void>.delayed(Duration.zero);
      expect(lookups, 0);
    },
  );

  test(
    'closing while origin lookup is pending starts no source request',
    () async {
      final pending = Completer<BroadcastVideoScope?>();
      final paths = <String>[];
      final container = ProviderContainer(
        overrides: [
          broadcastVideoStreamsClientProvider.overrideWithValue(
            BroadcastVideoStreamsClient(
              httpClient: MockClient((request) async {
                paths.add(request.url.path);
                return http.Response('{"streams":[],"source":null}', 200);
              }),
            ),
          ),
          broadcastVideoOriginLookupProvider.overrideWithValue(
            (scope, gameId) => pending.future,
          ),
        ],
      );
      container.listen(broadcastVideoGameStreamsProvider(_key), (_, _) {});
      await Future<void>.delayed(Duration.zero);
      container.dispose();
      pending.complete(_origin);
      await Future<void>.delayed(Duration.zero);
      expect(paths, ['/api/broadcast/round/combined-r2/video-streams']);
    },
  );
}
