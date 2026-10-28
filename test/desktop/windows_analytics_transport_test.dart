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
}
