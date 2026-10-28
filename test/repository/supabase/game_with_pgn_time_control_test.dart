import 'dart:convert';

import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Explicit HTTP contract fixture: mimic PostgREST's projection. This is not
// evidence of a live backend read. Missing joins really omit the detailed tc.
const detailedControl = '90 min / 40 moves + 30 min + 30 sec / move';
const fixturePgn = '1. e4 {[%clk 1:30:55]} e5 {[%clk 1:29:45]} *';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String? selected;
  var includeTour = true;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:54321',
      anonKey: 'LOCAL-FIXTURE-KEY',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/rest/v1/games');
        expect(request.url.queryParameters['id'], 'eq.clock-game');
        selected = request.url.queryParameters['select'];
        final row = <String, dynamic>{
          'id': 'clock-game',
          'round_id': 'round-5',
          'round_slug': 'round-5',
          'tour_id': 'clock-tour',
          'tour_slug': 'clock-tour',
          'pgn': fixturePgn,
          'status': '1/2-1/2',
          'think_time': 7,
          'last_clock_white': 5455,
          'last_clock_black': 5385,
          if (selected?.contains('tc:info->>tc') ?? false)
            'tours': includeTour ? {'tc': detailedControl} : null,
        };
        return http.Response(
          jsonEncode(row),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
  });
  tearDownAll(() async => Supabase.instance.dispose());
  setUp(() {
    selected = null;
    includeTour = true;
  });

  test(
    'focused PGN hydration carries the detailed tour time control',
    () async {
      final game = await GameRepository().getGameWithPGN('clock-game');
      expect(game.timeControlText, detailedControl);
      expect(game.pgn, fixturePgn);
      expect(game.lastClockWhite, 5455);
      expect(game.lastClockBlack, 5385);
      expect(game.thinkTime, 7);
    },
  );

  test('missing related tour does not prevent the game from opening', () async {
    includeTour = false;
    final game = await GameRepository().getGameWithPGN('clock-game');
    expect(game.pgn, fixturePgn);
    expect(game.timeControlText, isNull);
  });
}
