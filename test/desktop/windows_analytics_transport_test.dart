import 'dart:convert';

import 'package:chessever/desktop/services/windows_analytics_transport.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'persists installation ID and strips private metadata before HTTP',
    () async {
      String? savedId;
      final requests = <Map<String, dynamic>>[];
      final transport = WindowsAnalyticsTransport(
        enabled: true,
        readClientId: () async => savedId,
        saveClientId: (value) async {
          savedId = value;
        },
        client: MockClient((request) async {
          expect(request.url, WindowsAnalyticsTransport.endpoint);
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('', 204);
        }),
      );
      addTearDown(transport.dispose);
      await transport.initialize(observeLifecycle: false);
      expect(savedId, matches(RegExp(r'^[a-f0-9]{32}$')));
      transport.addEvent('auth_event', {
        'email': 'private@example.com',
        'user_id': 'private-id',
        'query': 'private search',
        'reason': '/private/path',
        'success': 'true',
      });
      await transport.flush();
      expect(requests.single['client_id'], savedId);
      final params =
          (requests.single['events'] as List).single['params'] as Map;
      expect(params['success'], 'true');
      for (final key in ['email', 'user_id', 'query', 'reason']) {
        expect(params.containsKey(key), false);
      }
      final reused = WindowsAnalyticsTransport(
        enabled: true,
        readClientId: () async => savedId,
        saveClientId: (_) async => fail('Existing ID must not be replaced'),
        client: MockClient((_) async => http.Response('', 204)),
      );
      addTearDown(reused.dispose);
      await reused.initialize(observeLifecycle: false);
    },
  );

  test(
    'counts foreground time and starts a new session after 30 minutes away',
    () async {
      var now = DateTime.utc(2026, 10, 21, 12);
      final batches = <Map<String, dynamic>>[];
      final transport = WindowsAnalyticsTransport(
        enabled: true,
        now: () => now,
        readClientId: () async => 'a' * 32,
        saveClientId: (_) async {},
        client: MockClient((request) async {
          batches.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('', 204);
        }),
      );
      addTearDown(transport.dispose);
      await transport.initialize(observeLifecycle: false);
      now = now.add(const Duration(seconds: 10));
      transport.addEvent('app_launched', {});
      await transport.flush();
      final first = (batches.single['events'] as List).single['params'] as Map;
      expect(first['engagement_time_msec'], 10000);
      transport.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await transport.flush();
      now = now.add(const Duration(minutes: 31));
      transport.didChangeAppLifecycleState(AppLifecycleState.resumed);
      now = now.add(const Duration(seconds: 5));
      transport.addEvent('screen_viewed', {});
      await transport.flush();
      final last = (batches.last['events'] as List).single['params'] as Map;
      expect(last['session_id'], isNot(first['session_id']));
      expect(last['engagement_time_msec'], 5000);
    },
  );

  test(
    'retries transient failures with backoff, drops invalid payload responses',
    () async {
      var now = DateTime.utc(2026, 10, 21);
      var calls = 0;
      final transport = WindowsAnalyticsTransport(
        enabled: true,
        now: () => now,
        readClientId: () async => 'a' * 32,
        saveClientId: (_) async {},
        client: MockClient(
          (_) async => http.Response('', ++calls == 1 ? 503 : 400),
        ),
      );
      addTearDown(transport.dispose);
      await transport.initialize(observeLifecycle: false);
      transport.addEvent('app_launched', {});
      await transport.flush();
      await transport.flush();
      expect(calls, 1);
      now = now.add(const Duration(minutes: 1));
      await transport.flush();
      expect(calls, 2);
      await transport.flush();
      expect(calls, 2);
    },
  );

  test(
    'disabled transport and storage failures never send or break startup',
    () async {
      for (final enabled in [true, false]) {
        final transport = WindowsAnalyticsTransport(
          enabled: enabled,
          readClientId: () async => throw StateError('storage unavailable'),
          saveClientId: (_) async {},
          client: MockClient((_) async {
            fail('Must not send');
          }),
        );
        addTearDown(transport.dispose);
        await transport.initialize(observeLifecycle: false);
        transport.addEvent('app_launched', {});
        await transport.flush();
      }
    },
  );

  test(
    'snapshots account identity and separates sign-in, switching and sign-out',
    () async {
      const accountA = '11111111-1111-4111-8111-111111111111';
      const accountB = '22222222-2222-4222-8222-222222222222';
      final requests = <Map<String, dynamic>>[];
      final transport = WindowsAnalyticsTransport(
        enabled: true,
        readClientId: () async => 'a' * 32,
        saveClientId: (_) async {},
        client: MockClient((request) async {
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('', 204);
        }),
      );
      addTearDown(transport.dispose);
      await transport.initialize(observeLifecycle: false);
      transport.addEvent('app_launched', {});
      transport.setUserId(accountA);
      transport.addEvent('screen_viewed', {'user_id': accountB});
      transport.addEvent('desktop_tab_opened', {});
      transport.setUserId(accountB);
      transport.addEvent('screen_viewed', {});
      transport.setUserId(null);
      transport.addEvent('screen_viewed', {});
      for (var i = 0; i < 4; i++) {
        await transport.flush();
      }
      expect(requests.map((r) => r['user_id']), [
        null,
        accountA,
        accountB,
        null,
      ]);
      expect(requests.map((r) => (r['events'] as List).length), [1, 2, 1, 1]);
      expect(requests.map((r) => r['client_id']).toSet(), {'a' * 32});
      for (final request in requests) {
        for (final event in request['events'] as List) {
          expect((event['params'] as Map).containsKey('user_id'), false);
        }
      }
    },
  );

  test(
    'retry keeps the original account after switching and clearing identity',
    () async {
      const accountA = '11111111-1111-4111-8111-111111111111';
      const accountB = '22222222-2222-4222-8222-222222222222';
      var now = DateTime.utc(2026, 11, 4);
      final requests = <Map<String, dynamic>>[];
      final transport = WindowsAnalyticsTransport(
        enabled: true,
        now: () => now,
        readClientId: () async => 'a' * 32,
        saveClientId: (_) async {},
        client: MockClient((request) async {
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('', requests.length == 1 ? 503 : 204);
        }),
      );
      addTearDown(transport.dispose);
      await transport.initialize(observeLifecycle: false);
      transport.setUserId(accountA);
      transport.addEvent('screen_viewed', {});
      await transport.flush();
      transport.setUserId(accountB);
      transport.addEvent('screen_viewed', {});
      // Non-UUID input cannot leak an email or keep the previous identity.
      transport.setUserId('private@example.com');
      transport.addEvent('screen_viewed', {});
      now = now.add(const Duration(minutes: 1));
      for (var i = 0; i < 3; i++) {
        await transport.flush();
      }
      expect(requests.map((r) => r['user_id']), [
        accountA,
        accountA,
        accountB,
        null,
      ]);
      expect(requests[0]['events'], requests[1]['events']);
    },
  );
}
