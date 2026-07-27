import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/providers/live_stream_lifecycle_provider.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart';

void main() {
  group('broadcast result metadata', () {
    final finished = <String, dynamic>{
      'Result': '1-0',
      ChessGame.metadataIsLiveKey: false,
      ChessGame.metadataAllowMainlineExtensionKey: true,
    };

    test('unknown and missing statuses preserve a terminal result', () {
      for (final status in <String?>[null, '', 'future-server-value']) {
        expect(
          mergeRecognizedLiveStatusMetadata(
            currentMetadata: finished,
            rawStatus: status,
          ),
          isNull,
          reason: 'status=$status',
        );
      }
    });

    test('normalizes every recognized broadcast result to PGN metadata', () {
      final expected = <String, String>{
        'live': '*',
        'W': '1-0',
        'B': '0-1',
        'D': '1/2-1/2',
      };

      for (final entry in expected.entries) {
        final merged = mergeRecognizedLiveStatusMetadata(
          currentMetadata: const <String, dynamic>{},
          rawStatus: entry.key,
        );
        expect(merged, isNotNull, reason: 'status=${entry.key}');
        expect(merged!['Result'], entry.value);
        expect(merged[ChessGame.metadataIsLiveKey], entry.key == 'live');
      }
    });

    test('accepted terminal row wins over a lagging PGN result', () {
      final finalized = finalizeBroadcastPgnMetadata(
        parsedMetadata: <String, dynamic>{
          'Result': '*',
          ChessGame.metadataIsLiveKey: true,
          ChessGame.metadataAllowMainlineExtensionKey: false,
        },
        acceptedLiveStatus: '1-0',
      );

      expect(finalized['Result'], '1-0');
      expect(finalized[ChessGame.metadataIsLiveKey], isFalse);
      expect(finalized[ChessGame.metadataAllowMainlineExtensionKey], isTrue);
    });

    test(
      'unconfirmed database snapshots with an undecided result remain editable',
      () {
        final parsed = ChessGame.fromPgn(
          'database-snapshot',
          '[Result "*"]\n\n1. e4 *',
        );
        final metadata = finalizeBroadcastPgnMetadata(
          parsedMetadata: parsed.metadata,
          acceptedLiveStatus: null,
        );
        final navigator = ChessGameNavigator(
          parsed.copyWith(metadata: metadata),
        )..goToTail();

        navigator.makeOrGoToMove('e7e5');

        expect(metadata[ChessGame.metadataIsLiveKey], isFalse);
        expect(metadata[ChessGame.metadataAllowMainlineExtensionKey], isTrue);
        expect(navigator.state.game.mainline.map((move) => move.san), [
          'e4',
          'e5',
        ]);
        expect(navigator.state.game.mainline.first.variations, isNull);
        expect(navigator.state.movePointer, [1]);
      },
    );

    test('accepted live snapshots keep the broadcast mainline protected', () {
      final parsed = ChessGame.fromPgn(
        'live-snapshot',
        '[Result "*"]\n\n1. e4 *',
      );
      final metadata = finalizeBroadcastPgnMetadata(
        parsedMetadata: parsed.metadata,
        acceptedLiveStatus: 'live',
      );
      final navigator = ChessGameNavigator(parsed.copyWith(metadata: metadata))
        ..goToTail();

      navigator.makeOrGoToMove('e7e5');

      expect(metadata[ChessGame.metadataIsLiveKey], isTrue);
      expect(metadata[ChessGame.metadataAllowMainlineExtensionKey], isFalse);
      expect(navigator.state.game.mainline.map((move) => move.san), ['e4']);
      expect(
        navigator.state.game.mainline.first.variations!.single.single.san,
        'e5',
      );
      expect(navigator.state.movePointer, [0, 0, 0]);
    });

    test('database context never inherits an ongoing source status', () {
      expect(
        resolveInitialBoardPgnLiveStatus(
          acceptedLiveStatus: null,
          isDatabaseSnapshot: true,
          gameId: 'bound-game',
          sourceGameStatus: GameStatus.ongoing,
          parsedResult: '*',
        ),
        isNull,
      );
      expect(
        isDatabaseBoardSnapshot(
          const BoardTabGameArgs(
            pgn: '',
            label: 'database',
            whiteName: '',
            blackName: '',
            databaseGamesContinuation: BoardTabGamesContinuation.twicDatabase(),
          ),
        ),
        isTrue,
      );
    });

    test('bound broadcasts stay protected before their first realtime row', () {
      expect(
        resolveInitialBoardPgnLiveStatus(
          acceptedLiveStatus: null,
          isDatabaseSnapshot: false,
          gameId: 'bound-live-game',
          sourceGameStatus: GameStatus.ongoing,
          parsedResult: '*',
        ),
        '*',
      );
      expect(
        resolveInitialBoardPgnLiveStatus(
          acceptedLiveStatus: null,
          isDatabaseSnapshot: false,
          gameId: 'bound-live-game-without-row',
          sourceGameStatus: null,
          parsedResult: '*',
        ),
        '*',
      );
    });
  });

  test('missing clocks cannot fabricate a terminal live-game result', () {
    final missingClocks = _liveGame(
      pgn: '1. e4 *',
      fen: _afterE4,
      lastMove: 'e2e4',
      lastMoveTime: DateTime.utc(2026, 7, 18, 12),
      whiteClockSeconds: 300,
      blackClockSeconds: 300,
    ).copyWith(clearWhiteClockSeconds: true, clearBlackClockSeconds: true);

    expect(missingClocks.gameStatus, GameStatus.ongoing);
    expect(missingClocks.effectiveGameStatus, GameStatus.ongoing);

    final knownZeroClocks = missingClocks.copyWith(
      whiteClockSeconds: 0,
      blackClockSeconds: 0,
    );
    expect(
      knownZeroClocks.effectiveGameStatus,
      GameStatus.ongoing,
      reason: 'Clock zero plus material balance cannot prove a chess result.',
    );
    expect(
      TournamentGameSummary.fromGamesTourModel(knownZeroClocks).status,
      GameStatus.ongoing,
      reason: 'Navigation state must use the authoritative server status.',
    );
    expect(
      GameCardData.fromGamesTourModel(knownZeroClocks).status,
      GameStatus.ongoing,
      reason: 'A card must stay live until an authoritative terminal status.',
    );
  });

  test('focused packet is arbitrated against the freshest Board seed', () {
    final retainedCardBase = _liveGame(
      pgn: '1. e4 *',
      fen: _afterE4,
      lastMove: 'e2e4',
      lastMoveTime: DateTime.utc(2026, 1, 1, 12, 0, 5),
      whiteClockSeconds: 296,
      blackClockSeconds: 300,
    );
    final hydratedBoardArgs = _liveGame(
      pgn: '1. e4 e5 2. Nf3 *',
      fen: _afterNf3,
      lastMove: 'g1f3',
      lastMoveTime: DateTime.utc(2026, 1, 1, 12, 0, 10),
      whiteClockSeconds: 292,
      blackClockSeconds: 294,
    );
    const intermediateFirstRow = LiveGameUpdate(
      gameId: 'game-1',
      pgn: '1. e4 e5 *',
      fen: _afterE4E5,
      lastMove: 'e7e5',
      lastMoveTime: '2026-01-01T12:00:06.000Z',
      lastClockWhite: 296,
      lastClockBlack: 294,
      status: 'live',
    );

    final selectedBase = selectFreshestBoardLiveBase(
      currentBase: retainedCardBase,
      argsSeed: hydratedBoardArgs,
    );
    expect(selectedBase, same(hydratedBoardArgs));
    expect(shouldReplaceBaseGame(retainedCardBase, selectedBase!), isTrue);

    final intermediateCandidate = mergeLiveGameUpdateWithBase(
      baseGame: selectedBase,
      update: intermediateFirstRow,
    );
    expect(
      shouldReplaceBaseGame(selectedBase, intermediateCandidate),
      isFalse,
      reason:
          'An intermediate focused row must be compared with the fresher '
          'Board args, not only the retained card base.',
    );
    expect(
      shouldAcceptFocusedLiveCandidate(
        current: selectedBase,
        incoming: intermediateCandidate,
        serverConfirmedRegression: false,
      ),
      isFalse,
    );
    expect(
      shouldAcceptFocusedLiveCandidate(
        current: selectedBase,
        incoming: intermediateCandidate,
        serverConfirmedRegression: true,
      ),
      isTrue,
      reason:
          'An exact current-row read can authorize an intentional takeback '
          'even when ply/time move backwards.',
    );
  });

  test(
    'confirmed takeback truncates live mainline but preserves old analysis',
    () {
      final oldGame = ChessGame.fromPgn(
        'game-1',
        '[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6 *',
      );
      final freshGame = ChessGame.fromPgn(
        'game-1',
        '[Result "*"]\n\n1. e4 e5 *',
      );

      final merged = mergeBroadcastUpdateForTesting(oldGame, freshGame);

      expect(merged.mainline.map((move) => move.uci), ['e2e4', 'e7e5']);
      final retainedBranches = merged.mainline.last.variations;
      expect(retainedBranches, isNotNull);
      expect(retainedBranches!.last.map((move) => move.uci), ['g1f3', 'b8c6']);
    },
  );

  test(
    'root takeback survives empty echoes and restores the complete analysis',
    () {
      final oldGame = ChessGame.fromPgn(
        'game-1',
        '[Result "*"]\n\n'
            '1. e4 \$1 {root note [%eval 0.25]} '
            'e5 \$2 {reply note [%eval 0.10]} '
            '(1... c5 \$5 {sicilian note [%eval 0.15]}) '
            '2. Nf3 \$3 {knight note [%eval 0.30]} *',
      );
      final emptyLiveGame = ChessGame.fromPgn('game-1', '[Result "*"]\n\n*');

      final rootReset = mergeBroadcastUpdateForTesting(oldGame, emptyLiveGame);
      expect(rootReset.mainline, isEmpty);
      expect(rootReset.detachedRootAnalysis, isNotEmpty);
      expect(
        shouldMergeBroadcastTree(gameId: 'game-1', currentGame: rootReset),
        isTrue,
        reason:
            'Board PGN intake must not bypass detached analysis just because '
            'the canonical mainline is empty.',
      );

      final serialized = jsonEncode(rootReset.toJson());
      final restoredFromJson = ChessGame.fromJson(
        (jsonDecode(serialized) as Map).cast<String, dynamic>(),
      );
      final repeatedEmpty = mergeBroadcastUpdateForTesting(
        restoredFromJson,
        emptyLiveGame,
      );
      expect(repeatedEmpty.mainline, isEmpty);
      expect(repeatedEmpty.detachedRootAnalysis, isNotEmpty);

      final resumedLiveGame = ChessGame.fromPgn(
        'game-1',
        '[Result "*"]\n\n1. e4 *',
      );
      final resumed = mergeBroadcastUpdateForTesting(
        repeatedEmpty,
        resumedLiveGame,
      );

      expect(resumed.mainline.map((move) => move.uci), ['e2e4']);
      expect(resumed.mainline.first.fen, resumedLiveGame.mainline.first.fen);
      expect(resumed.detachedRootAnalysis, isNull);
      expect(resumed.mainline.first.eval, '0.25');
      expect(resumed.mainline.first.nags, contains(1));
      expect(
        resumed.mainline.first.comments,
        contains('root note [%eval 0.25]'),
      );

      final branches = resumed.mainline.first.variations!;
      final oldContinuation = branches.firstWhere(
        (line) => line.first.uci == 'e7e5',
      );
      expect(oldContinuation.map((move) => move.uci), ['e7e5', 'g1f3']);
      expect(oldContinuation.first.eval, '0.10');
      expect(oldContinuation.first.nags, contains(2));
      expect(
        oldContinuation.first.comments,
        contains('reply note [%eval 0.10]'),
      );
      expect(oldContinuation.last.eval, '0.30');
      expect(oldContinuation.last.nags, contains(3));

      final oldAlternative = branches.firstWhere(
        (line) => line.first.uci == 'c7c5',
      );
      expect(oldAlternative.first.eval, '0.15');
      expect(oldAlternative.first.nags, contains(5));
      expect(
        oldAlternative.first.comments,
        contains('sicilian note [%eval 0.15]'),
      );
    },
  );

  test('a different resumed first move stays the canonical live position', () {
    final oldGame = ChessGame.fromPgn(
      'game-1',
      '[Result "*"]\n\n1. e4 {saved line} e5 *',
    );
    final emptyLiveGame = ChessGame.fromPgn('game-1', '[Result "*"]\n\n*');
    final rootReset = mergeBroadcastUpdateForTesting(oldGame, emptyLiveGame);
    final resumedLiveGame = ChessGame.fromPgn(
      'game-1',
      '[Result "*"]\n\n1. d4 *',
    );

    final resumed = mergeBroadcastUpdateForTesting(rootReset, resumedLiveGame);

    expect(resumed.mainline.map((move) => move.uci), ['d2d4']);
    expect(resumed.mainline.first.fen, resumedLiveGame.mainline.first.fen);
    expect(resumed.mainline.first.variations!.single.map((move) => move.uci), [
      'e2e4',
      'e7e5',
    ]);
  });

  test(
    'matching broadcast moves take fresh clocks without losing comments',
    () {
      final oldGame = ChessGame.fromPgn(
        'game-1',
        '[Result "*"]\n\n1. e4 {local note [%clk 0:05:00]} e5 *',
      );
      final freshGame = ChessGame.fromPgn(
        'game-1',
        '[Result "*"]\n\n1. e4 {broadcast correction [%clk 0:04:58]} e5 *',
      );

      final merged = mergeBroadcastUpdateForTesting(oldGame, freshGame);

      expect(
        merged.mainline.first.clockTime,
        freshGame.mainline.first.clockTime,
      );
      expect(
        merged.mainline.first.clockTime,
        isNot(oldGame.mainline.first.clockTime),
      );
      expect(
        (merged.mainline.first.comments ?? const <String>[]).any(
          (comment) => comment.contains('broadcast correction'),
        ),
        isTrue,
      );
      expect(
        (merged.mainline.first.comments ?? const <String>[]).any(
          (comment) => comment.contains('local note'),
        ),
        isTrue,
      );
    },
  );

  test('incremental Board path accepts only a byte-prefix PGN append', () {
    const previous = '[Event "Live"]\n[Result "*"]\n\n1. e4 {[%clk 0:05:00]} *';
    const appended =
        '[Event "Live"]\n[Result "*"]\n\n1. e4 {[%clk 0:05:00]} e5 {[%clk 0:04:59]} *';
    const correctedEarlierClock =
        '[Event "Live"]\n[Result "*"]\n\n1. e4 {[%clk 0:04:58]} e5 {[%clk 0:04:59]} *';
    const correctedHeader =
        '[Event "Corrected"]\n[Result "*"]\n\n1. e4 {[%clk 0:05:00]} e5 *';

    expect(
      isStrictAppendOnlyBroadcastPgn(
        previousPgn: previous,
        incomingPgn: appended,
      ),
      isTrue,
    );
    expect(
      isStrictAppendOnlyBroadcastPgn(
        previousPgn: previous,
        incomingPgn: correctedEarlierClock,
      ),
      isFalse,
    );
    expect(
      isStrictAppendOnlyBroadcastPgn(
        previousPgn: previous,
        incomingPgn: correctedHeader,
      ),
      isFalse,
    );
  });

  test('accepted live player correction wins over lagging PGN headers', () {
    final corrected = PlayerCard(
      name: 'Corrected Player',
      federation: 'TUR',
      title: 'GM',
      rating: 2712,
      countryCode: 'TUR',
      fideId: 123456,
      team: null,
    );

    final resolved = resolveBoardPlayerHeaderMetadata(
      sourcePlayer: corrected,
      sourceIsAuthoritative: true,
      pgnName: 'Old Name',
      pgnFederation: 'USA',
      pgnTitle: 'IM',
      pgnRating: 2500,
      pgnFideId: 999,
      fallbackName: 'Fallback Name',
      fallbackFederation: 'GER',
      fallbackTitle: 'FM',
      fallbackRating: 2400,
      fallbackFideId: 111,
    );

    expect(resolved.name, 'Corrected Player');
    expect(resolved.federation, 'TUR');
    expect(resolved.title, 'GM');
    expect(resolved.rating, 2712);
    expect(resolved.fideId, 123456);
  });

  test('regression confirmation guard includes result and player metadata', () {
    final current = _liveGame(
      pgn: '1. e4 e5 *',
      fen: _afterE4E5,
      lastMove: 'e7e5',
      lastMoveTime: DateTime.utc(2026, 1, 1, 12, 0, 6),
      whiteClockSeconds: 296,
      blackClockSeconds: 294,
    );
    const rejected = LiveGameUpdate(
      gameId: 'game-1',
      pgn: '1. e4 *',
      fen: _afterE4,
      lastMove: 'e2e4',
      lastMoveTime: '2026-01-01T12:00:05.000Z',
    );
    final key = LiveGameRegressionConfirmationKey.from(
      current: current,
      rejectedUpdate: rejected,
    );

    expect(key.matchesCurrentPosition(current), isTrue);
    expect(
      key.matchesCurrentPosition(current.copyWith(gameStatus: GameStatus.draw)),
      isFalse,
    );
    expect(
      key.matchesCurrentPosition(
        current.copyWith(
          whitePlayer: current.whitePlayer.copyWith(name: 'Corrected White'),
        ),
      ),
      isFalse,
    );
  });

  test(
    'rejected focused position retains all fields until exact confirmation',
    () {
      final current = _liveGame(
        pgn: '1. e4 e5 2. Nf3 *',
        fen: _afterNf3,
        lastMove: 'g1f3',
        lastMoveTime: DateTime.utc(2026, 1, 1, 12, 0, 10),
        whiteClockSeconds: 292,
        blackClockSeconds: 294,
      );
      final stalePositionWithCorrections = current.copyWith(
        whitePlayer: current.whitePlayer.copyWith(
          name: 'Corrected White',
          rating: 2512,
        ),
        blackPlayer: current.blackPlayer.copyWith(name: 'Corrected Black'),
        pgn: '1. e4 *',
        fen: _afterE4,
        lastMove: 'e2e4',
        lastMoveTime: DateTime.utc(2026, 1, 1, 12, 0, 5),
        whiteClockSeconds: 300,
        blackClockSeconds: 300,
        gameStatus: GameStatus.draw,
      );

      final merged = mergeIndependentLiveGameMetadata(
        current,
        stalePositionWithCorrections,
      );

      expect(merged.pgn, current.pgn);
      expect(merged.fen, current.fen);
      expect(merged.lastMove, current.lastMove);
      expect(merged.lastMoveTime, current.lastMoveTime);
      expect(merged.whiteClockSeconds, current.whiteClockSeconds);
      expect(merged.blackClockSeconds, current.blackClockSeconds);
      expect(merged.whitePlayer, current.whitePlayer);
      expect(merged.blackPlayer, current.blackPlayer);
      expect(merged.gameStatus, current.gameStatus);

      final terminal = current.copyWith(gameStatus: GameStatus.whiteWins);
      expect(
        mergeIndependentLiveGameMetadata(
          terminal,
          stalePositionWithCorrections,
        ).gameStatus,
        GameStatus.whiteWins,
        reason: 'A rejected initial snapshot cannot swap a known result.',
      );
    },
  );

  test('player-only corrections participate in live update equality', () {
    const first = LiveGameUpdate(
      gameId: 'game-1',
      status: 'live',
      players: <Object>[
        <String, Object>{'name': 'White', 'rating': 2500},
        <String, Object>{'name': 'Black', 'rating': 2490},
      ],
    );
    const same = LiveGameUpdate(
      gameId: 'game-1',
      status: 'live',
      players: <Object>[
        <String, Object>{'name': 'White', 'rating': 2500},
        <String, Object>{'name': 'Black', 'rating': 2490},
      ],
    );
    const corrected = LiveGameUpdate(
      gameId: 'game-1',
      status: 'live',
      players: <Object>[
        <String, Object>{'name': 'White', 'rating': 2512},
        <String, Object>{'name': 'Black', 'rating': 2490},
      ],
    );

    expect(first, same);
    expect(first.hashCode, same.hashCode);
    expect(first, isNot(corrected));
  });

  test(
    'focused live stream auto-disposes before a stalled first row',
    () async {
      var listens = 0;
      var cancels = 0;
      final source = StreamController<LiveGameUpdate?>.broadcast(
        onListen: () => listens++,
        onCancel: () => cancels++,
      );
      final container = ProviderContainer(
        overrides: [
          gameStreamRepositoryProvider.overrideWithValue(
            _StalledLiveStreamRepository(source.stream),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await source.close();
      });

      final provider = liveGameUpdateStreamProvider('game-1');
      final subscription = container.listen<AsyncValue<LiveGameUpdate?>>(
        provider,
        (_, __) {},
        fireImmediately: true,
      );
      await container.pump();

      expect(listens, 1);
      expect(container.read(provider), isA<AsyncData<LiveGameUpdate?>>());

      subscription.close();
      await container.pump();
      await Future<void>.delayed(Duration.zero);

      expect(cancels, 1);
    },
  );

  test('app pause cancels remote work without clearing the last row', () async {
    var listens = 0;
    var cancels = 0;
    final source = StreamController<LiveGameUpdate?>.broadcast(
      onListen: () => listens++,
      onCancel: () => cancels++,
    );
    final container = ProviderContainer(
      overrides: [
        gameStreamRepositoryProvider.overrideWithValue(
          _StalledLiveStreamRepository(source.stream),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await source.close();
    });

    final provider = liveGameUpdateStreamProvider('game-1');
    final subscription = container.listen<AsyncValue<LiveGameUpdate?>>(
      provider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.pump();

    const latest = LiveGameUpdate(
      gameId: 'game-1',
      fen: 'latest-fen',
      lastMove: 'e7e5',
      status: 'live',
    );
    source.add(latest);
    for (var attempt = 0; attempt < 5; attempt++) {
      await container.pump();
      await Future<void>.delayed(Duration.zero);
      if (container.read(provider).valueOrNull == latest) break;
    }
    expect(container.read(provider).valueOrNull, latest);

    container
        .read(liveGameStreamingLifecycleProvider.notifier)
        .didChangeAppLifecycleState(AppLifecycleState.paused);
    await container.pump();
    await Future<void>.delayed(Duration.zero);

    expect(cancels, 1);
    expect(container.read(provider).valueOrNull, latest);

    container
        .read(liveGameStreamingLifecycleProvider.notifier)
        .didChangeAppLifecycleState(AppLifecycleState.resumed);
    await container.pump();

    expect(listens, 2);
    expect(container.read(provider).valueOrNull, latest);
  });

  test(
    'arrival sequence resets when lifecycle recreates the channel',
    () async {
      final source = StreamController<LiveGameUpdate?>.broadcast();
      final container = ProviderContainer(
        overrides: [
          gameStreamRepositoryProvider.overrideWithValue(
            _StalledLiveStreamRepository(source.stream),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await source.close();
      });

      final provider = liveGameUpdateArrivalStreamProvider('game-1');
      final arrivals = <LiveStreamArrival<LiveGameUpdate?>>[];
      final subscription = container
          .listen<AsyncValue<LiveStreamArrival<LiveGameUpdate?>>>(provider, (
            _,
            next,
          ) {
            final value = next.valueOrNull;
            if (value != null) arrivals.add(value);
          }, fireImmediately: true);
      addTearDown(subscription.close);
      await container.pump();

      const first = LiveGameUpdate(gameId: 'game-1', pgn: '1. e4 *');
      const takeback = LiveGameUpdate(gameId: 'game-1', pgn: '*');
      source
        ..add(first)
        ..add(takeback);
      for (var attempt = 0; attempt < 10 && arrivals.length < 3; attempt++) {
        await container.pump();
        await Future<void>.delayed(Duration.zero);
      }

      expect(arrivals.first.isFallback, isTrue);
      expect(arrivals[arrivals.length - 2].sequence, 1);
      expect(arrivals.last.sequence, 2);
      expect(arrivals.last.isFallback, isFalse);

      container
          .read(liveGameStreamingLifecycleProvider.notifier)
          .didChangeAppLifecycleState(AppLifecycleState.paused);
      await container.pump();
      container
          .read(liveGameStreamingLifecycleProvider.notifier)
          .didChangeAppLifecycleState(AppLifecycleState.resumed);
      await container.pump();

      source.add(first);
      for (var attempt = 0; attempt < 10; attempt++) {
        await container.pump();
        await Future<void>.delayed(Duration.zero);
        if (arrivals.last.sessionEpoch > 0 && arrivals.last.sequence == 1) {
          break;
        }
      }
      expect(arrivals.last.sequence, 1);
      expect(arrivals.last.sessionEpoch, greaterThan(0));
    },
  );

  test('legacy focused stream forwards upstream errors', () async {
    final container = ProviderContainer(
      overrides: [
        gameStreamRepositoryProvider.overrideWithValue(
          _StalledLiveStreamRepository(
            Stream<LiveGameUpdate?>.error(StateError('stream failed')),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final errors = <Object>[];
    final provider = gameUpdatesStreamProvider('game-1');
    final subscription = container.listen<AsyncValue<Map<String, dynamic>?>>(
      provider,
      (_, next) {
        if (next.hasError) errors.add(next.error!);
      },
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    for (var attempt = 0; attempt < 10 && errors.isEmpty; attempt++) {
      await container.pump();
      await Future<void>.delayed(Duration.zero);
    }

    expect(errors, hasLength(1));
    expect(errors.single, isA<StateError>());
  });

  test(
    'completed realtime source reconnects and retains the last row',
    () async {
      final first = StreamController<LiveGameUpdate?>();
      final second = StreamController<LiveGameUpdate?>();
      final repository = _SequencedLiveStreamRepository([
        first.stream,
        second.stream,
      ]);
      final container = ProviderContainer(
        overrides: [gameStreamRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(() async {
        container.dispose();
        if (!first.isClosed) await first.close();
        if (!second.isClosed) await second.close();
      });

      final provider = liveGameUpdateStreamProvider('game-1');
      final subscription = container.listen<AsyncValue<LiveGameUpdate?>>(
        provider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.pump();

      const firstRow = LiveGameUpdate(gameId: 'game-1', pgn: '1. e4 *');
      first.add(firstRow);
      for (var attempt = 0; attempt < 10; attempt++) {
        await container.pump();
        await Future<void>.delayed(Duration.zero);
        if (container.read(provider).valueOrNull == firstRow) break;
      }
      expect(container.read(provider).valueOrNull, firstRow);

      await first.close();
      await Future<void>.delayed(const Duration(milliseconds: 325));
      await container.pump();
      expect(repository.subscriptionCount, 2);
      expect(
        container.read(provider).valueOrNull,
        firstRow,
        reason: 'A reconnect must never clear the last accurate row.',
      );

      const reconnectedRow = LiveGameUpdate(
        gameId: 'game-1',
        pgn: '1. e4 e5 *',
      );
      second.add(reconnectedRow);
      for (var attempt = 0; attempt < 10; attempt++) {
        await container.pump();
        await Future<void>.delayed(Duration.zero);
        if (container.read(provider).valueOrNull == reconnectedRow) break;
      }
      expect(container.read(provider).valueOrNull, reconnectedRow);
    },
  );

  test('pause cancels a queued reconnect until lifecycle resumes', () async {
    final first = StreamController<LiveGameUpdate?>();
    final second = StreamController<LiveGameUpdate?>();
    final repository = _SequencedLiveStreamRepository([
      first.stream,
      second.stream,
    ]);
    final container = ProviderContainer(
      overrides: [gameStreamRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(() async {
      container.dispose();
      if (!first.isClosed) await first.close();
      if (!second.isClosed) await second.close();
    });

    final subscription = container.listen(
      liveGameUpdateStreamProvider('game-1'),
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.pump();
    await first.close();
    container
        .read(liveGameStreamingLifecycleProvider.notifier)
        .didChangeAppLifecycleState(AppLifecycleState.paused);
    await container.pump();
    await Future<void>.delayed(const Duration(milliseconds: 325));
    await container.pump();
    expect(repository.subscriptionCount, 1);

    container
        .read(liveGameStreamingLifecycleProvider.notifier)
        .didChangeAppLifecycleState(AppLifecycleState.resumed);
    await container.pump();
    expect(repository.subscriptionCount, 2);
  });

  test('initial-row channel flapping escalates reconnect backoff', () async {
    final first = StreamController<LiveGameUpdate?>();
    final second = StreamController<LiveGameUpdate?>();
    final third = StreamController<LiveGameUpdate?>();
    final repository = _SequencedLiveStreamRepository([
      first.stream,
      second.stream,
      third.stream,
    ]);
    final container = ProviderContainer(
      overrides: [gameStreamRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(() async {
      container.dispose();
      if (!first.isClosed) await first.close();
      if (!second.isClosed) await second.close();
      if (!third.isClosed) await third.close();
    });

    final subscription = container.listen(
      liveGameUpdateStreamProvider('game-1'),
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.pump();

    first.add(const LiveGameUpdate(gameId: 'game-1', pgn: '1. e4 *'));
    await first.close();
    await Future<void>.delayed(const Duration(milliseconds: 325));
    await container.pump();
    expect(repository.subscriptionCount, 2);

    second.add(const LiveGameUpdate(gameId: 'game-1', pgn: '1. e4 *'));
    await second.close();
    await Future<void>.delayed(const Duration(milliseconds: 325));
    await container.pump();
    expect(
      repository.subscriptionCount,
      2,
      reason: 'An initial select must not reset the failure backoff to 250ms.',
    );

    await Future<void>.delayed(const Duration(milliseconds: 750));
    await container.pump();
    expect(repository.subscriptionCount, 3);
  });

  test('disposing a live provider cancels a queued reconnect', () async {
    final first = StreamController<LiveGameUpdate?>();
    // This controller should never gain a listener. A broadcast controller's
    // close future completes without one, so teardown can prove that outcome
    // without waiting forever on single-subscription stream semantics.
    final second = StreamController<LiveGameUpdate?>.broadcast();
    final repository = _SequencedLiveStreamRepository([
      first.stream,
      second.stream,
    ]);
    final container = ProviderContainer(
      overrides: [gameStreamRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(() async {
      container.dispose();
      if (!first.isClosed) await first.close();
      if (!second.isClosed) await second.close();
    });

    final subscription = container.listen(
      liveGameUpdateStreamProvider('game-1'),
      (_, __) {},
      fireImmediately: true,
    );
    await container.pump();
    await first.close();
    subscription.close();
    await container.pump();
    await Future<void>.delayed(const Duration(milliseconds: 325));
    expect(repository.subscriptionCount, 1);
  });
}

class _StalledLiveStreamRepository extends GameStreamRepository {
  _StalledLiveStreamRepository(this.stream);

  final Stream<LiveGameUpdate?> stream;

  @override
  Stream<LiveGameUpdate?> subscribeToLiveGameUpdate(String gameId) => stream;
}

class _SequencedLiveStreamRepository extends GameStreamRepository {
  _SequencedLiveStreamRepository(this.streams);

  final List<Stream<LiveGameUpdate?>> streams;
  int subscriptionCount = 0;

  @override
  Stream<LiveGameUpdate?> subscribeToLiveGameUpdate(String gameId) {
    final index = subscriptionCount++;
    return streams[index < streams.length ? index : streams.length - 1];
  }
}

const String _afterE4 =
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
const String _afterE4E5 =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
const String _afterNf3 =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';

GamesTourModel _liveGame({
  required String pgn,
  required String fen,
  required String lastMove,
  required DateTime lastMoveTime,
  required int whiteClockSeconds,
  required int blackClockSeconds,
}) {
  return GamesTourModel(
    gameId: 'game-1',
    whitePlayer: PlayerCard(
      name: 'White',
      federation: '',
      title: '',
      rating: 2500,
      countryCode: '',
      team: null,
    ),
    blackPlayer: PlayerCard(
      name: 'Black',
      federation: '',
      title: '',
      rating: 2500,
      countryCode: '',
      team: null,
    ),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    whiteClockSeconds: whiteClockSeconds,
    blackClockSeconds: blackClockSeconds,
    gameStatus: GameStatus.ongoing,
    fen: fen,
    pgn: pgn,
    lastMove: lastMove,
    lastMoveTime: lastMoveTime,
    roundId: 'round-1',
    tourId: 'tour-1',
  );
}
