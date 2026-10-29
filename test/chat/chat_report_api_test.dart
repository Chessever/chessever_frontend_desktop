import 'dart:async';
import 'dart:convert';

import 'package:chessever/chat/chat_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _account = '00000000-0000-4000-8000-000000000001';
const _conversation = '00000000-0000-4000-8000-000000000002';
const _message = '00000000-0000-4000-8000-000000000003';

Map<String, dynamic> _session(
  String account, {
  int revision = 1,
  bool anonymous = false,
}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return {
    'access_token':
        '${part({'alg': 'HS256'})}.${part({'sub': account, 'iat': now, 'exp': now + 3600, 'revision': revision})}.test',
    'refresh_token': 'test-refresh',
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': now + 3600,
    'user': {
      'id': account,
      'aud': 'authenticated',
      'role': 'authenticated',
      'is_anonymous': anonymous,
      'app_metadata': {},
      'user_metadata': {},
      'created_at': '2026-10-29T00:00:00Z',
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ChatApi api;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) respond;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.invalid',
      anonKey: 'test-public-key',
      httpClient: MockClient((_) async => http.Response('{}', 200)),
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
      debug: false,
    );
    await Supabase.instance.client.auth.recoverSession(
      jsonEncode(_session(_account)),
    );
    requests = [];
    respond = (_) async => http.Response('{"reported":true}', 200);
    api = ChatApi(
      client: MockClient((request) async {
        requests.add(request);
        return respond(request);
      }),
    );
  });

  tearDown(() async {
    api.close();
    await Supabase.instance.dispose();
  });

  Future<void> report({
    String accountId = _account,
    String messageId = _message,
  }) => api.reportMessage(
    accountId: accountId,
    conversationId: _conversation,
    messageId: messageId,
  );

  test('posts only original IDs and reason using the latest JWT', () async {
    final refreshed = _session(_account, revision: 2);
    await Supabase.instance.client.auth.recoverSession(jsonEncode(refreshed));
    await report();
    final request = requests.single;
    expect(request.method, 'POST');
    expect(
      request.url.path,
      '/v1/chat/conversations/$_conversation/messages/$_message/report',
    );
    expect(
      request.headers['authorization'],
      'Bearer ${refreshed['access_token']}',
    );
    expect(jsonDecode(request.body), {'reason': 'other'});
    expect(request.headers.containsKey('x-rewarded-session'), isFalse);
  });

  test(
    'rejects switched accounts, anonymous sessions and temporary answers before HTTP',
    () async {
      await expectLater(
        report(accountId: 'another-account'),
        throwsA(isA<ChatApiException>()),
      );
      await expectLater(
        report(messageId: 'local-assistant'),
        throwsA(isA<ChatApiException>()),
      );
      await Supabase.instance.client.auth.recoverSession(
        jsonEncode(_session(_account, anonymous: true)),
      );
      await expectLater(
        report(),
        throwsA(
          isA<ChatApiException>().having((e) => e.statusCode, 'status', 401),
        ),
      );
      expect(requests, isEmpty);
    },
  );

  test(
    'does not complete successfully when the identity switches during HTTP',
    () async {
      final reached = Completer<void>();
      final response = Completer<http.Response>();
      respond = (_) {
        reached.complete();
        return response.future;
      };
      final pending = report();
      await reached.future;
      await Supabase.instance.client.auth.recoverSession(
        jsonEncode(_session('another-account')),
      );
      response.complete(http.Response('{"reported":true}', 200));
      await expectLater(
        pending,
        throwsA(
          isA<ChatApiException>().having(
            (e) => e.message,
            'message',
            contains('account changed'),
          ),
        ),
      );
      expect(
        requests.single.url.path,
        contains('/$_conversation/messages/$_message/report'),
      );
    },
  );

  test(
    'preserves report rate status and requires explicit acknowledgement',
    () async {
      respond =
          (_) async => http.Response(
            '{"error":"report_limit","message":"Please try again tomorrow."}',
            429,
          );
      await expectLater(
        report(),
        throwsA(
          isA<ChatApiException>().having((e) => e.statusCode, 'status', 429),
        ),
      );
      respond = (_) async => http.Response('{}', 200);
      await expectLater(
        report(),
        throwsA(
          isA<ChatApiException>().having(
            (e) => e.message,
            'message',
            contains('not confirmed'),
          ),
        ),
      );
    },
  );
}
