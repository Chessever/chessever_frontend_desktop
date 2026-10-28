import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/models/player_download_preferences.dart';
import 'package:chessever/desktop/services/player_workspace_repository.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';

void main() {
  for (final source in GamebaseExternalPlayerSource.values) {
    test(
      '${source.name} forwards date range, clocks, and independent sync cursor',
      () async {
        RequestOptions? request;
        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              request = options;
              handler.resolve(
                Response<String>(
                  requestOptions: options,
                  data: '',
                  statusCode: 200,
                  headers: Headers.fromMap({
                    'x-pgn-filter-version': ['1'],
                    'x-pgn-snapshot': ['full'],
                  }),
                ),
              );
            },
          ),
        );
        final api = GamebaseRepository(dio, baseUrl: 'https://gamebase.test');
        final workspace = PlayerWorkspaceRepository(gamebaseRepository: api);
        final preferences = PlayerDownloadPreferences(
          timeControls: const {
            PlayerDownloadTimeControl.blitz,
            PlayerDownloadTimeControl.rapid,
          },
          fromDate: DateTime.utc(2026, 6, 1),
          toDate: DateTime.utc(2026, 6, 30),
        );
        final downloaded =
            source == GamebaseExternalPlayerSource.lichess
                ? await workspace.downloadLichessGames(
                  username: 'prep-player',
                  preferences: preferences,
                  sinceMs: 1781568000000,
                )
                : await workspace.downloadChessComGames(
                  username: 'prep-player',
                  preferences: preferences,
                  sinceMs: 1781568000000,
                );
        expect(request!.queryParameters['timeControls'], 'blitz,rapid');
        expect(
          request!.queryParameters['dateFrom'],
          DateTime.utc(2026, 6, 1).millisecondsSinceEpoch,
        );
        expect(
          request!.queryParameters['until'],
          DateTime.utc(2026, 7, 1).millisecondsSinceEpoch,
        );
        expect(request!.queryParameters['since'], 1781568000000);
        expect(downloaded.gameCount, 0);
        expect(downloaded.replaceExistingSource, isTrue);
      },
    );
  }

  test(
    'old server cannot silently accept filters and return all games',
    () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '',
                headers: Headers.fromMap({
                  'x-pgn-snapshot': ['full'],
                }),
              ),
            );
          },
        ),
      );
      final workspace = PlayerWorkspaceRepository(
        gamebaseRepository: GamebaseRepository(
          dio,
          baseUrl: 'https://gamebase.test',
        ),
      );
      await expectLater(
        workspace.downloadLichessGames(
          username: 'prep-player',
          preferences: const PlayerDownloadPreferences(
            timeControls: {PlayerDownloadTimeControl.blitz},
          ),
        ),
        throwsA(
          predicate(
            (Object error) => error.toString().contains('server is updated'),
          ),
        ),
      );
      // Existing unrestricted downloads continue to work on that server.
      expect(
        (await workspace.downloadLichessGames(
          username: 'prep-player',
        )).gameCount,
        0,
      );
    },
  );
}
