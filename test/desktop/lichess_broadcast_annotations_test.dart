import 'package:chessever/services/lichess_move_annotations_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const gameId = 'Kd8M2Wfp';
  const roundId = '6k62uFr2';
  tearDown(LichessMoveAnnotationsService.clearCache);

  test('reads round and game IDs from a Lichess broadcast game link', () {
    expect(
      LichessMoveAnnotationsService.broadcastIdsFromUrl(
        'https://lichess.org/broadcast/bundesliga/round-6/$roundId/$gameId#34',
      ),
      (roundId: roundId, gameId: gameId),
    );
    expect(
      LichessMoveAnnotationsService.broadcastIdsFromUrl(
        'https://lichess.org.example.com/broadcast/bundesliga/round-6/$roundId/$gameId',
      ),
      isNull,
    );
  });

  test('loads only matching mainline advice and reuses the response', () async {
    var requests = 0;
    final annotations = await http.runWithClient(
      () async {
        final results = await Future.wait([
          for (var i = 0; i < 2; i++)
            LichessMoveAnnotationsService.getAnnotations(
              lichessGameId: gameId,
              broadcastRoundId: roundId,
              signature: '4:e4|e5|Bb5|Nc6',
              moveSans: const ['e4', 'e5', 'Bb5', 'Nc6'],
            ),
        ]);
        final cached = await LichessMoveAnnotationsService.getAnnotations(
          lichessGameId: gameId,
          broadcastRoundId: roundId,
          signature: '4:e4|e5|Bb5|Nc6',
          moveSans: const ['e4', 'e5', 'Bb5', 'Nc6'],
        );
        expect(results, everyElement(same(cached)));

        final mismatch = await LichessMoveAnnotationsService.getAnnotations(
          lichessGameId: gameId,
          broadcastRoundId: roundId,
          signature: '4:e4|e5|Nf3|Nc6',
          moveSans: const ['e4', 'e5', 'Nf3', 'Nc6'],
        );
        expect(mismatch, isNull);
        return cached;
      },
      () => MockClient((request) async {
        requests++;
        expect(
          request.url.toString(),
          'https://lichess.org/api/study/$roundId/$gameId.pgn?comments=true&variations=false',
        );
        return http.Response(
          '1. e4 e5 2. Bb5?! {[%eval 0.0]} {Inaccuracy. Nf3 was best.} '
          '(2. Nf3 {Mistake. Bc4 was best.}) Nc6 {Regular PGN comment.} 1-0',
          200,
        );
      }),
    );

    expect(requests, 2);
    expect(annotations!.keys, [2]);
    expect(annotations[2]?.type, LichessMoveAnnotationType.inaccuracy);
    expect(annotations[2]?.comment, 'Inaccuracy. Nf3 was best.');
  });
}
