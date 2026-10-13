import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chessever/desktop/services/editorial/discovery_dots_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native clients use the public production origin when the website requires a browser',
    () async {
      SharedPreferences.setMockInitialValues({});
      final hosts = <String>[];
      final client = MockClient((request) async {
        hosts.add(request.url.host);
        expect(request.url.path, '/api/nudges');
        return hosts.length == 1
            ? http.Response('Cloudflare browser challenge', 403)
            : http.Response(jsonEncode({'dots': []}), 200);
      });
      expect(
        await DesktopDiscoveryDotsSource(client: client).fetch(),
        '{"dots":[]}',
      );
      expect(hosts, [
        'chessever.com',
        'chessever-web.young-sun-69a8.workers.dev',
      ]);
      client.close();
    },
  );
  test(
    'a server error is retained as an error rather than clearing active markers',
    () async {
      final hosts = <String>[];
      final client = MockClient((request) async {
        hosts.add(request.url.host);
        return http.Response('{}', 503);
      });
      await expectLater(
        DesktopDiscoveryDotsSource(client: client).fetch(),
        throwsStateError,
      );
      expect(hosts, ['chessever.com']);
      client.close();
    },
  );
}
