import 'dart:async';

import 'package:chessever/repository/freemium/freemium_quota.dart';
import 'package:chessever/repository/freemium/freemium_quota_queue.dart';
import 'package:chessever/repository/freemium/freemium_quota_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

Map<String, Object?> _answer({
  required bool allowed,
  required String reason,
  int? used,
  int? limit,
  bool premium = false,
  String kind = 'saved_games',
  int requested = 1,
}) => <String, Object?>{
  'allowed': allowed,
  'reason': reason,
  'used': used,
  'limit': limit,
  'is_premium': premium,
  'kind': kind,
  'requested': requested,
};

FreemiumQuotaRepository _serverRepo(
  Object? Function(String kind, int additions) answer, {
  List<int>? additionsSeen,
  FreemiumQuotaUsageCounter? fallbackUsage,
}) => FreemiumQuotaRepository(
  rpc: (kind, additions) async {
    additionsSeen?.add(additions);
    return answer(kind, additions);
  },
  fallbackUsage:
      fallbackUsage ??
      (_) async => fail('fallback must not run while the server answers'),
  queue: FreemiumQuotaQueue(),
);

void main() {
  group('server answers', () {
    test('every reason maps to one outcome', () async {
      const expected = <String, (bool, FreemiumQuotaOutcome)>{
        'premium': (true, FreemiumQuotaOutcome.allowed),
        'no_new_slot': (true, FreemiumQuotaOutcome.allowed),
        'within_limit': (true, FreemiumQuotaOutcome.allowed),
        'quota_exceeded': (false, FreemiumQuotaOutcome.quotaExceeded),
        'auth_required': (false, FreemiumQuotaOutcome.accountRequired),
        'invalid_kind': (false, FreemiumQuotaOutcome.temporarilyUnavailable),
        'invalid_additions': (
          false,
          FreemiumQuotaOutcome.temporarilyUnavailable,
        ),
      };
      for (final entry in expected.entries) {
        final repo = _serverRepo(
          (_, _) => _answer(allowed: entry.value.$1, reason: entry.key),
        );
        final result = await repo.check(FreemiumQuotaKind.savedGames);
        expect(result.outcome, entry.value.$2, reason: entry.key);
        expect(result.reason, entry.key);
        expect(result.source, FreemiumQuotaSource.server);
      }
    });

    test('a spent allowance names its capacity', () async {
      final repo = _serverRepo(
        (_, _) => _answer(
          allowed: false,
          reason: 'quota_exceeded',
          used: 10,
          limit: 10,
        ),
      );
      final result = await repo.check(FreemiumQuotaKind.savedGames);
      expect(result.capacityLabel, '10 of 10 saved games used');
      expect(
        freemiumQuotaBlockedMessage(result),
        '10 of 10 saved games used. Premium removes the limit.',
      );
    });

    test('a bulk save asks for every destination copy', () async {
      final seen = <int>[];
      final repo = _serverRepo(
        (_, additions) => _answer(
          allowed: false,
          reason: 'quota_exceeded',
          used: 3,
          limit: 10,
          requested: additions,
        ),
        additionsSeen: seen,
      );
      // 4 games into 3 databases.
      final result = await repo.check(
        FreemiumQuotaKind.savedGames,
        additions: 4 * 3,
      );
      expect(seen, [12]);
      expect(result.requested, 12);
      expect(result.outcome, FreemiumQuotaOutcome.quotaExceeded);
    });

    test('zero additions pass for an account over its limit', () async {
      final repo = _serverRepo(
        (_, additions) => _answer(
          allowed: true,
          reason: 'no_new_slot',
          used: 14,
          limit: 10,
          requested: additions,
        ),
      );
      final result = await repo.check(
        FreemiumQuotaKind.savedGames,
        additions: 0,
      );
      expect(result.isAllowed, isTrue);
    });

    test('an unparseable answer never grants a slot', () async {
      final repo = _serverRepo((_, _) => 'not json');
      final result = await repo.check(FreemiumQuotaKind.favoritePlayers);
      expect(result.outcome, FreemiumQuotaOutcome.temporarilyUnavailable);
    });
  });

  group('temporary client fallback', () {
    for (final code in const ['PGRST202', '42883']) {
      test('runs only when the function is missing ($code)', () async {
        var counted = 0;
        final repo = FreemiumQuotaRepository(
          rpc:
              (_, _) async =>
                  throw PostgrestException(message: 'missing', code: code),
          fallbackUsage: (_) async {
            counted++;
            return 9;
          },
          queue: FreemiumQuotaQueue(),
        );
        final result = await repo.check(FreemiumQuotaKind.savedGames);
        expect(counted, 1);
        expect(result.source, FreemiumQuotaSource.clientFallback);
        expect(result.isAllowed, isTrue);
        expect(result.used, 9);
      });
    }

    test('any other failure is Retry, never the fallback', () async {
      for (final error in <Object>[
        const PostgrestException(message: 'timeout', code: '57014'),
        Exception('offline'),
      ]) {
        final repo = FreemiumQuotaRepository(
          rpc: (_, _) async => throw error,
          fallbackUsage: (_) async => fail('fallback must not run for $error'),
          queue: FreemiumQuotaQueue(),
        );
        final result = await repo.check(FreemiumQuotaKind.savedGames);
        expect(result.outcome, FreemiumQuotaOutcome.temporarilyUnavailable);
        expect(result.source, FreemiumQuotaSource.server);
      }
    });

    FreemiumQuotaRepository fallbackRepo(
      int used, {
      bool subscribed = false,
      void Function()? onCount,
    }) => FreemiumQuotaRepository(
      rpc:
          (_, _) async =>
              throw const PostgrestException(message: 'x', code: 'PGRST202'),
      fallbackUsage: (_) async {
        onCount?.call();
        return used;
      },
      fallbackIsSubscribed: () => subscribed,
      queue: FreemiumQuotaQueue(),
    );

    test('enforces the shared saved-game and favourite caps', () async {
      expect(
        (await fallbackRepo(9).check(FreemiumQuotaKind.savedGames)).isAllowed,
        isTrue,
      );
      final full = await fallbackRepo(10).check(FreemiumQuotaKind.savedGames);
      expect(full.outcome, FreemiumQuotaOutcome.quotaExceeded);
      expect(full.capacityLabel, '10 of 10 saved games used');
      final favorites = await fallbackRepo(
        3,
      ).check(FreemiumQuotaKind.favoritePlayers);
      expect(favorites.outcome, FreemiumQuotaOutcome.quotaExceeded);
      final edit = await fallbackRepo(
        14,
      ).check(FreemiumQuotaKind.savedGames, additions: 0);
      expect(edit.isAllowed, isTrue);
    });

    test('enforces the shared owned-database cap', () async {
      expect(
        (await fallbackRepo(2).check(FreemiumQuotaKind.ownedDatabases))
            .isAllowed,
        isTrue,
      );
      final full = await fallbackRepo(
        3,
      ).check(FreemiumQuotaKind.ownedDatabases);
      expect(full.outcome, FreemiumQuotaOutcome.quotaExceeded);
      expect(full.used, 3);
      expect(full.limit, 3);
      expect(full.capacityLabel, contains('3 of 3'));
      // Over the cap after a downgrade: creating nothing new stays allowed,
      // and the retained databases are never trimmed.
      final retained = await fallbackRepo(
        4,
      ).check(FreemiumQuotaKind.ownedDatabases, additions: 0);
      expect(retained.isAllowed, isTrue);
    });

    test('premium skips the count', () async {
      var counted = 0;
      final result = await fallbackRepo(
        50,
        subscribed: true,
        onCount: () => counted++,
      ).check(FreemiumQuotaKind.savedGames);
      expect(result.isAllowed, isTrue);
      expect(counted, 0);
    });

    test('no session is account-required', () async {
      final repo = FreemiumQuotaRepository(
        rpc:
            (_, _) async =>
                throw const PostgrestException(message: 'x', code: '42883'),
        fallbackUsage:
            (_) async => throw const FreemiumQuotaNoSessionException(),
        queue: FreemiumQuotaQueue(),
      );
      final result = await repo.check(FreemiumQuotaKind.savedGames);
      expect(result.outcome, FreemiumQuotaOutcome.accountRequired);
    });

    test('counts exclude Likes and organisational folders', () {
      final rows = <Map<String, Object?>>[
        {'id': 'likes', 'node_type': 'database', 'is_liked_games': true},
        {'id': 'org', 'node_type': 'folder', 'is_liked_games': false},
        {'id': 'db-1', 'node_type': 'database', 'is_liked_games': false},
        {'id': 'db-2', 'node_type': 'database', 'is_liked_games': false},
      ];
      expect(freemiumFallbackOwnedDatabaseCount(rows), 2);
      expect(
        freemiumFallbackCountedGameFolderIds(rows),
        isNot(contains('likes')),
      );
    });
  });

  group('write rejected by the quota trigger', () {
    test('carries the server capacity', () {
      const error = PostgrestException(
        message: 'freemium_quota_exceeded',
        code: 'P0001',
        details:
            '{"allowed": false, "reason": "quota_exceeded", "used": 10, '
            '"limit": 10, "is_premium": false, "kind": "saved_games", '
            '"requested": 2}',
        hint: 'saved_games',
      );
      final result = freemiumQuotaRejection(
        error,
        fallbackKind: FreemiumQuotaKind.ownedDatabases,
      );
      expect(result, isNotNull);
      expect(result!.kind, FreemiumQuotaKind.savedGames);
      expect(result.outcome, FreemiumQuotaOutcome.quotaExceeded);
      expect(result.capacityLabel, '10 of 10 saved games used');
    });

    test('is recognised after BaseRepository rewraps it', () {
      final result = freemiumQuotaRejection(
        Exception('Database error: freemium_quota_exceeded'),
        fallbackKind: FreemiumQuotaKind.favoritePlayers,
      );
      expect(result?.kind, FreemiumQuotaKind.favoritePlayers);
      expect(result?.outcome, FreemiumQuotaOutcome.quotaExceeded);
    });

    test('other errors are not quota rejections', () {
      expect(
        freemiumQuotaRejection(
          const PostgrestException(message: 'duplicate', code: '23505'),
          fallbackKind: FreemiumQuotaKind.savedGames,
        ),
        isNull,
      );
    });
  });

  group('FIFO queue', () {
    test('releases its slot when the action throws', () async {
      final queue = FreemiumQuotaQueue();
      await expectLater(
        queue.run<void>(() async => throw StateError('boom')),
        throwsStateError,
      );
      expect(await queue.run(() async => 'next'), 'next');
    });

    test('runs one request at a time, in order', () async {
      final queue = FreemiumQuotaQueue();
      final gate = Completer<void>();
      final order = <String>[];
      final first = queue.run(() async {
        order.add('first:start');
        await gate.future;
        order.add('first:end');
      });
      final second = queue.run(() async => order.add('second'));
      await Future<void>.delayed(Duration.zero);
      expect(order, ['first:start']);
      gate.complete();
      await Future.wait([first, second]);
      expect(order, ['first:start', 'first:end', 'second']);
    });

    test('a repository cannot race itself between check and write', () async {
      final gate = Completer<void>();
      var inFlight = 0;
      var maxInFlight = 0;
      final repo = FreemiumQuotaRepository(
        rpc: (_, _) async {
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          await gate.future;
          inFlight--;
          return _answer(allowed: true, reason: 'within_limit');
        },
        queue: FreemiumQuotaQueue(),
      );
      final a = repo.check(FreemiumQuotaKind.savedGames);
      final b = repo.check(FreemiumQuotaKind.savedGames);
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future.wait([a, b]);
      expect(maxInFlight, 1);
    });
  });
}
