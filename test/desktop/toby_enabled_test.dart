import 'dart:async';

import 'package:chessever/desktop/panes/board_pane.dart'
    show shouldShowDesktopBoardTobyBar;
import 'package:chessever/desktop/services/toby/toby_performance.dart';
import 'package:chessever/desktop/services/toby/toby_prediction.dart';
import 'package:chessever/desktop/state/board_analysis_preferences.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/desktop/state/play_help_modules.dart';
import 'package:chessever/desktop/state/toby_enabled.dart';
import 'package:chessever/desktop/widgets/play_help_modules_panel.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _user = '11111111-2222-4333-8444-555555555555';

/// The account side, answering each read when the test says so.
class _Store implements TobyAccountStore {
  final reads = <Completer<bool?>>[];
  final writes = <(String, bool)>[];

  @override
  Future<bool?> read(String userId) {
    final read = Completer<bool?>();
    reads.add(read);
    return read.future;
  }

  @override
  Future<void> write(String userId, bool value) async {
    writes.add((userId, value));
  }
}

class _Identity extends DesktopAccountIdentityNotifier {
  _Identity(this.initial);

  final DesktopAccountIdentity initial;

  @override
  DesktopAccountIdentity build() => initial;
}

/// A fixed Toby switch the test can flip, for the surfaces that read it.
class _Toby extends TobyEnabledNotifier {
  _Toby(this.initial);

  final bool initial;

  @override
  bool build() => initial;

  void flip(bool value) => state = value;
}

class _Gamebase extends GamebaseRepository {
  _Gamebase() : super(Dio(), baseUrl: 'http://example.test');

  int readings = 0;
  int performances = 0;

  @override
  Future<GamebaseTobyReply> getTobyReading(
    Map<String, Object?> body,
    CancelToken cancelToken, {
    bool recheckAccess = false,
  }) async {
    readings++;
    return (statusCode: null, data: null, retryAfter: null);
  }

  @override
  Future<GamebaseTobyReply> getTobyPerformance(
    Map<String, Object?> body,
    CancelToken cancelToken, {
    bool recheckAccess = false,
  }) async {
    performances++;
    return (statusCode: null, data: null, retryAfter: null);
  }
}

const _signedIn = DesktopAccountIdentity(userId: _user, generation: 1);
const _guest = DesktopAccountIdentity(
  userId: _user,
  isAnonymous: true,
  generation: 1,
);

ProviderContainer _account(_Store store, {DesktopAccountIdentity? identity}) {
  final container = ProviderContainer(
    overrides: [
      tobyAccountStoreProvider.overrideWithValue(store),
      desktopAccountIdentityProvider.overrideWith(
        () => _Identity(identity ?? _signedIn),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

ProviderContainer _withToby(bool on, {_Gamebase? gamebase}) {
  final container = ProviderContainer(
    overrides: [
      tobyEnabledProvider.overrideWith(() => _Toby(on)),
      if (gamebase != null)
        gamebaseRepositoryProvider.overrideWithValue(gamebase),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('the account switch', () {
    test(
      'an account that never chose reads as on, and writes nothing',
      () async {
        final store = _Store();
        final container = _account(store);
        expect(container.read(tobyEnabledProvider), isTrue);
        await pumpEventQueue();
        expect(store.reads, hasLength(1));
        store.reads.single.complete(null);
        await container.read(tobyEnabledProvider.notifier).idle();
        expect(container.read(tobyEnabledProvider), isTrue);
        expect(store.writes, isEmpty);
      },
    );

    test('the account value wins over the device on sign-in', () async {
      final store = _Store();
      final container = _account(store);
      container.read(tobyEnabledProvider);
      await pumpEventQueue();
      store.reads.single.complete(false);
      await container.read(tobyEnabledProvider.notifier).idle();
      expect(container.read(tobyEnabledProvider), isFalse);
      expect(store.writes, isEmpty);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool(kTobyEnabledPrefKey), isFalse);
    });

    test('a flip is written to the account', () async {
      final store = _Store();
      final container = _account(store);
      container.read(tobyEnabledProvider);
      await pumpEventQueue();
      store.reads.single.complete(true);
      await container.read(tobyEnabledProvider.notifier).idle();

      container
          .read(boardAnalysisPreferencesProvider.notifier)
          .setTobyAnalysis(false);
      await container.read(tobyEnabledProvider.notifier).idle();
      expect(container.read(tobyEnabledProvider), isFalse);
      expect(store.writes, [(_user, false)]);

      container.read(tobyEnabledProvider.notifier).set(true);
      await container.read(tobyEnabledProvider.notifier).idle();
      expect(store.writes, [(_user, false), (_user, true)]);
    });

    test('a late pull does not undo a switch flipped meanwhile', () async {
      final store = _Store();
      final container = _account(store);
      container.read(tobyEnabledProvider);
      await pumpEventQueue();
      expect(store.reads, hasLength(1));

      // The reader turns Toby off while the account is still being read.
      container.read(tobyEnabledProvider.notifier).set(false);
      store.reads.single.complete(true);
      await container.read(tobyEnabledProvider.notifier).idle();

      expect(container.read(tobyEnabledProvider), isFalse);
      expect(store.writes, [(_user, false)]);
    });

    test('an old device "off" moves to an account that never chose', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kTobyEnabledPrefKey: false,
      });
      final store = _Store();
      final container = _account(store);
      container.read(tobyEnabledProvider);
      await pumpEventQueue();
      expect(container.read(tobyEnabledProvider), isFalse);
      store.reads.single.complete(null);
      await container.read(tobyEnabledProvider.notifier).idle();
      expect(container.read(tobyEnabledProvider), isFalse);
      expect(store.writes, [(_user, false)]);
    });

    test('a guest keeps the switch on this device', () async {
      final store = _Store();
      final container = _account(store, identity: _guest);
      container.read(tobyEnabledProvider.notifier).set(false);
      await container.read(tobyEnabledProvider.notifier).idle();
      expect(container.read(tobyEnabledProvider), isFalse);
      expect(store.reads, isEmpty);
      expect(store.writes, isEmpty);
    });

    test('a pull for an account that was left is dropped', () async {
      var local = true;
      final writes = <bool>[];
      final reads = <Completer<bool?>>[];
      final sync = TobyAccountSync(
        readRemote: (_) {
          final read = Completer<bool?>();
          reads.add(read);
          return read.future;
        },
        writeRemote: (_, value) async => writes.add(value),
        readLocal: () => local,
        writeLocal: (value) => local = value,
      );
      sync.setUser(_user);
      sync.setUser(null);
      reads.single.complete(false);
      await sync.idle();
      expect(local, isTrue);
      expect(writes, isEmpty);
    });

    test('the upsert names only its own columns', () {
      final body = tobyEnabledUpsertBody(_user, false, DateTime.utc(2026));
      expect(
        body.keys,
        unorderedEquals(['user_id', 'toby_enabled', 'updated_at']),
      );
      expect(parseTobyEnabledRow(null), isNull);
      expect(parseTobyEnabledRow({'toby_enabled': null}), isNull);
      expect(parseTobyEnabledRow({'toby_enabled': false}), isFalse);
    });
  });

  group('Toby off', () {
    test('the Board drops Toby Predicts, the bar and his arrows', () {
      final container = _withToby(false);
      final board = container.read(boardAnalysisPreferencesProvider.notifier);
      board.setArrows(BoardAnalysisArrows.toby);
      final prefs = container.read(boardAnalysisPreferencesProvider);
      const engine = EngineSettings();
      expect(prefs.tobyAnalysis, isFalse);
      expect(prefs.tobyEnabled, isFalse);
      expect(prefs.arrows(engine), BoardAnalysisArrows.stockfish);
      expect(shouldShowDesktopBoardTobyBar(engine, null, prefs), isFalse);
      expect(
        boardArrowSources(tobyEnabled: false),
        isNot(contains(BoardAnalysisArrows.toby)),
      );

      (container.read(tobyEnabledProvider.notifier) as _Toby).flip(true);
      final on = container.read(boardAnalysisPreferencesProvider);
      expect(on.tobyAnalysis, isTrue);
      expect(on.arrows(engine), BoardAnalysisArrows.toby);
      expect(shouldShowDesktopBoardTobyBar(engine, null, on), isTrue);
    });

    test('nothing is asked of Toby, and the rating row is hidden', () async {
      final gamebase = _Gamebase();
      final container = _withToby(false, gamebase: gamebase);
      final reading = tobyReadingProvider(
        TobyQuery(
          request: TobyRequest(moves: const ['e2e4'], whiteRating: 2500),
          session: 'toby-off-0001',
        ),
      );
      final performance = tobyPerformanceProvider(
        TobyPerformanceQuery(
          fingerprint: 'fp-off',
          accountId: null,
          request: TobyPerformanceRequest(
            moves: const ['e2e4', 'e7e5'],
            values: const [(best: 30, played: 25), null],
            whiteRating: 2500,
            timeControl: '5400+30',
          ),
        ),
      );
      container.listen(reading, (_, _) {});
      container.listen(performance, (_, _) {});
      await Future<void>.delayed(tobySettleDelay * 3);
      expect(container.read(reading).status, TobyStatus.notApplicable);
      expect(container.read(performance), TobyPerformanceState.unavailable);
      expect(gamebase.readings, 0);
      expect(gamebase.performances, 0);
    });

    test('Play shows none of Toby\'s help and keeps it for later', () {
      final container = _withToby(true);
      final modules = container.read(playHelpModulesProvider.notifier);
      modules.set(
        const PlayHelpModules(
          engineLines: true,
          tobyPredictions: true,
          tobyBar: true,
          arrows: PlayHelpArrows.toby,
        ),
      );
      final toby = container.read(tobyEnabledProvider.notifier) as _Toby;

      toby.flip(false);
      expect(
        container.read(playHelpModulesProvider),
        const PlayHelpModules(engineLines: true),
      );
      modules.update((m) => m.copyWith(evalBar: true));
      expect(
        container.read(playHelpModulesProvider),
        const PlayHelpModules(engineLines: true, evalBar: true),
      );

      toby.flip(true);
      expect(
        container.read(playHelpModulesProvider),
        const PlayHelpModules(
          engineLines: true,
          evalBar: true,
          tobyPredictions: true,
          tobyBar: true,
          arrows: PlayHelpArrows.toby,
        ),
      );
    });

    testWidgets('Play\'s help list offers no Toby switches or arrows', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [tobyEnabledProvider.overrideWith(() => _Toby(false))],
          child: FTheme(
            data: FThemes.zinc.dark,
            child: const MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(child: PlayHelpModulesList()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Toby Predicts'), findsNothing);
      expect(find.text('Toby bar'), findsNothing);
      expect(find.text('Toby'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
