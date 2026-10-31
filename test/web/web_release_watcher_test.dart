import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/web/web_release_watcher.dart';

void main() {
  group('parseVersionJson', () {
    test('reads Flutter version.json as version+build', () {
      expect(
        WebReleaseWatcher.parseVersionJson(
          '{"app_name":"chessever","version":"22.19.0","build_number":"535",'
          '"package_name":"chessever"}',
        ),
        '22.19.0+535',
      );
    });

    test('rejects a challenge page and malformed bodies', () {
      expect(
        WebReleaseWatcher.parseVersionJson('<!DOCTYPE html><title>Just a'),
        isNull,
      );
      expect(WebReleaseWatcher.parseVersionJson('[]'), isNull);
      expect(WebReleaseWatcher.parseVersionJson('{"version":""}'), isNull);
    });
  });

  group('check', () {
    late List<String> newer;
    late int current;
    late String? body;
    late DateTime clock;
    late int fetches;

    WebReleaseWatcher watcher({String running = '22.19.0+535'}) {
      return WebReleaseWatcher(
        runningVersion: running,
        onNewerRelease: newer.add,
        onCurrent: () => current++,
        fetchVersionJson: () async {
          fetches++;
          return body;
        },
        now: () => clock,
      );
    }

    String versionJson(String version, String build) =>
        '{"version":"$version","build_number":"$build"}';

    setUp(() {
      newer = [];
      current = 0;
      body = null;
      clock = DateTime(2026, 10, 31, 12);
      fetches = 0;
    });

    test('reports a newer deploy, including a build-only bump', () async {
      body = versionJson('22.19.0', '536');
      await watcher().check();
      expect(newer, ['22.19.0+536']);
      expect(current, 0);
    });

    test('reports current for the same build and for a rollback', () async {
      final w = watcher();
      body = versionJson('22.19.0', '535');
      await w.check();
      body = versionJson('22.18.4', '534');
      await w.check();
      expect(newer, isEmpty);
      expect(current, 2);
    });

    test('a failed or unreadable fetch changes nothing', () async {
      final w = watcher();
      body = null;
      await w.check();
      body = '<!DOCTYPE html>';
      await w.check();
      expect(newer, isEmpty);
      expect(current, 0);
    });

    test('does not check without a compiled version', () async {
      body = versionJson('22.19.0', '536');
      await watcher(running: '').check();
      expect(fetches, 0);
    });

    test('focus checks are throttled, explicit checks are not', () async {
      final w = watcher();
      body = versionJson('22.19.0', '535');
      await w.checkIfStale();
      clock = clock.add(const Duration(seconds: 10));
      await w.checkIfStale();
      expect(fetches, 1);
      await w.check();
      expect(fetches, 2);
      clock = clock.add(WebReleaseWatcher.minFocusGap);
      await w.checkIfStale();
      expect(fetches, 3);
    });
  });
}
