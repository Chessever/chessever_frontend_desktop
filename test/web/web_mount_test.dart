import 'package:chessever/desktop/services/broadcast_video_streams.dart';
import 'package:chessever/desktop/services/desktop_deep_link_router.dart';
import 'package:chessever/web/web_mount.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('webMountPathOf', () {
    test('reads the directory of the document base', () {
      expect(webMountPathOf(Uri.parse('https://app.chessever.com/')), '/');
      expect(
        webMountPathOf(Uri.parse('https://chessever.com/webapp/')),
        '/webapp/',
      );
      expect(webMountPathOf(Uri.parse('http://localhost:8080')), '/');
    });

    test('native and test bases mount at the root', () {
      expect(webMountPathOf(Uri.parse('file:///Users/me/project/')), '/');
    });
  });

  group('app and browser paths', () {
    const mount = '/webapp/';

    test('the root mount is the identity', () {
      expect(
        webAppPath('/broadcast/x?tab=games', '/'),
        '/broadcast/x?tab=games',
      );
      expect(webBrowserPath('/analysis?fen=a', '/'), '/analysis?fen=a');
    });

    test('the /webapp/ mount strips and adds the prefix', () {
      expect(webAppPath('/webapp', mount), '/');
      expect(webAppPath('/webapp/', mount), '/');
      expect(webAppPath('/webapp?code=1', mount), '/?code=1');
      expect(
        webAppPath('/webapp/broadcast/x?tab=1', mount),
        '/broadcast/x?tab=1',
      );
      expect(webAppPath('/webapp/app/likes', mount), '/app/likes');
      expect(webBrowserPath('/app/likes', mount), '/webapp/app/likes');
      expect(webBrowserPath('/', mount), '/webapp/');
      expect(
        webBrowserPath('/version.json?t=1', mount),
        '/webapp/version.json?t=1',
      );
    });

    test('round trips', () {
      for (final path in ['/', '/broadcast', '/app/inbox', '/analysis?fen=x']) {
        expect(webAppPath(webBrowserPath(path, mount), mount), path);
      }
    });

    test('webOwnUrl builds the OAuth return address', () {
      final page = Uri.parse('https://chessever.com/webapp/broadcast/x?y=1');
      expect(
        webOwnUrl(page, '/', mount).toString(),
        'https://chessever.com/webapp/',
      );
      expect(
        webOwnUrl(
          Uri.parse('https://app.chessever.com/games/1'),
          '/',
          '/',
        ).toString(),
        'https://app.chessever.com/',
      );
    });
  });

  group('normalizeChesseverComWebAppUri', () {
    test('maps chessever.com/webapp/<path> to app.chessever.com/<path>', () {
      expect(
        normalizeChesseverComWebAppUri(
          Uri.parse('https://chessever.com/webapp/games/abc?tour=t'),
        ).toString(),
        'https://app.chessever.com/games/abc?tour=t',
      );
      expect(
        normalizeChesseverComWebAppUri(
          Uri.parse('https://chessever.com/webapp/app/inbox'),
        ).toString(),
        'https://app.chessever.com/app/inbox',
      );
    });

    test("never rewrites the phone app's /app links or other addresses", () {
      for (final raw in [
        'https://chessever.com/app',
        'https://chessever.com/app/feed',
        'https://chessever.com/app/games/abc',
        'https://chessever.com/app/likes/week',
        'https://chessever.com/app/my-space/prep',
        'https://chessever.com/webapps/x',
        'https://chessever.com/broadcast/x/y',
        'https://app.chessever.com/webapp/games',
      ]) {
        expect(normalizeChesseverComWebAppUri(Uri.parse(raw)), Uri.parse(raw));
      }
    });

    test('deep links through the mount route like their twin', () {
      final mounted = parseDesktopGameDeepLink(
        Uri.parse('https://chessever.com/webapp/games/abc123?tour=t1'),
      );
      expect(mounted?.id, 'abc123');
      expect(mounted?.tour, 't1');
      expect(
        parseDesktopBroadcastDeepLink(
          Uri.parse('https://chessever.com/webapp/broadcast/slug/id1'),
        )?.id,
        'id1',
      );
    });
  });

  test('the broadcast relay follows the mount', () {
    expect(
      broadcastApiDefaultBase(
        inBrowser: true,
        pageUri: Uri.parse('https://chessever.com/webapp/broadcast/x'),
        mount: '/webapp/',
      ).toString(),
      'https://chessever.com/webapp/_broadcast',
    );
  });
}
