import 'package:chessever/desktop/services/desktop_deep_link_router.dart';
import 'package:flutter_test/flutter_test.dart';

DesktopIncomingLink _parse(String link) {
  final parsed = parseDesktopIncomingLink(Uri.parse(link));
  expect(parsed, isNotNull, reason: link);
  return parsed!;
}

void main() {
  test('dispatch priority matches the phone', () {
    expect(DesktopIncomingLinkTarget.values, [
      DesktopIncomingLinkTarget.game,
      DesktopIncomingLinkTarget.book,
      DesktopIncomingLinkTarget.folder,
      DesktopIncomingLinkTarget.playerScoreCard,
      DesktopIncomingLinkTarget.teamScoreCard,
      DesktopIncomingLinkTarget.broadcast,
      DesktopIncomingLinkTarget.playerProfile,
    ]);
  });

  group('shared books', () {
    test('web and app-scheme book links carry the share token', () {
      final web = _parse('https://chessever.com/books/aB3dE5fG7h');
      expect(web.target, DesktopIncomingLinkTarget.book);
      expect(web.shareToken, 'aB3dE5fG7h');

      final scheme = _parse('com.chessever.app://books/aB3dE5fG7h');
      expect(scheme.target, DesktopIncomingLinkTarget.book);
      expect(scheme.shareToken, 'aB3dE5fG7h');
    });

    test('/books alone is not a link', () {
      expect(
        parseDesktopIncomingLink(Uri.parse('https://chessever.com/books')),
        isNull,
      );
    });
  });

  test('databases and folders both open a folder id', () {
    for (final link in [
      'https://chessever.com/databases/folder-1',
      'https://www.chessever.com/folders/folder-1',
      'com.chessever.app://databases/folder-1',
      'com.chessever.app://folders/folder-1',
    ]) {
      final parsed = _parse(link);
      expect(parsed.target, DesktopIncomingLinkTarget.folder, reason: link);
      expect(parsed.folderId, 'folder-1', reason: link);
    }
  });

  group('player profile', () {
    test('plain FIDE id form', () {
      final parsed = _parse('https://chessever.com/player/1503014');
      expect(parsed.target, DesktopIncomingLinkTarget.playerProfile);
      expect(parsed.profileId, '1503014');
    });

    test('SEO form uses the last segment as the identity', () {
      final parsed = _parse(
        'https://chessever.com/player/magnus-carlsen/1503014',
      );
      expect(parsed.target, DesktopIncomingLinkTarget.playerProfile);
      expect(parsed.profileId, '1503014');

      final memorial = _parse(
        'https://chessever.com/player/mikhail-tal/tal-mikhail-1936',
      );
      expect(memorial.profileId, 'tal-mikhail-1936');
    });

    test('app-scheme profile link', () {
      final parsed = _parse('com.chessever.app://player/1503014');
      expect(parsed.target, DesktopIncomingLinkTarget.playerProfile);
      expect(parsed.profileId, '1503014');
    });
  });

  group('event scorecards', () {
    test('player scorecard beats the plain broadcast', () {
      final parsed = _parse(
        'https://chessever.com/broadcast/tata-steel-2026/4TdB92Cj/player/1503014',
      );
      expect(parsed.target, DesktopIncomingLinkTarget.playerScoreCard);
      expect(parsed.broadcast!.id, '4TdB92Cj');
      expect(parsed.broadcast!.slug, 'tata-steel-2026');
      expect(parsed.fideId, 1503014);
    });

    test('a non-numeric player id degrades to the broadcast', () {
      final parsed = _parse(
        'https://chessever.com/broadcast/event/4TdB92Cj/player/not-a-fide-id',
      );
      expect(parsed.target, DesktopIncomingLinkTarget.broadcast);
      expect(parsed.broadcast!.id, '4TdB92Cj');
    });

    test('team scorecard decodes a percent-encoded team name', () {
      final teamName = 'Åland & Co. Rīga';
      final link =
          'https://chessever.com/broadcast/olympiad/4TdB92Cj/team/'
          '${Uri.encodeComponent(teamName)}';
      expect(link, contains('%C3%85land%20%26%20Co.%20R%C4%ABga'));
      final parsed = _parse(link);
      expect(parsed.target, DesktopIncomingLinkTarget.teamScoreCard);
      expect(parsed.teamName, teamName);
      expect(parsed.broadcast!.id, '4TdB92Cj');
    });

    test('an empty team name degrades to the broadcast', () {
      final parsed = _parse(
        'https://chessever.com/broadcast/olympiad/4TdB92Cj/team/%20',
      );
      expect(parsed.target, DesktopIncomingLinkTarget.broadcast);
    });

    test('app-scheme scorecard shapes', () {
      final player = _parse(
        'com.chessever.app://broadcast/event/4TdB92Cj/player/1503014',
      );
      expect(player.target, DesktopIncomingLinkTarget.playerScoreCard);
      expect(player.broadcast!.id, '4TdB92Cj');
      expect(player.fideId, 1503014);

      final team = _parse(
        'com.chessever.app://broadcast/event/4TdB92Cj/team/Team%20Norway',
      );
      expect(team.target, DesktopIncomingLinkTarget.teamScoreCard);
      expect(team.teamName, 'Team Norway');
    });
  });

  test('games still win over every other target', () {
    final parsed = _parse('https://chessever.com/games/5Hkz1dp9?tour=open');
    expect(parsed.target, DesktopIncomingLinkTarget.game);
    expect(parsed.game!.id, '5Hkz1dp9');
    expect(parsed.game!.tour, 'open');
  });

  test('new shapes are routed in-app and survive launch arguments', () {
    for (final link in [
      'https://chessever.com/books/aB3dE5fG7h',
      'https://chessever.com/databases/folder-1',
      'https://chessever.com/player/magnus-carlsen/1503014',
      'https://chessever.com/broadcast/olympiad/4TdB92Cj/team/Team%20Norway',
    ]) {
      expect(isDesktopRoutableWebDeepLink(Uri.parse(link)), isTrue,
          reason: link);
    }
    expect(
      isDesktopRoutableWebDeepLink(Uri.parse('https://chessever.com/account')),
      isFalse,
    );
    expect(
      isDesktopRoutableWebDeepLink(Uri.parse('https://chessever.com/player')),
      isFalse,
    );

    final uris = desktopDeepLinkUrisFromArguments([
      '--updated',
      'https://chessever.com/books/aB3dE5fG7h',
      'https://chessever.com/pricing',
      'com.chessever.app://player/1503014',
    ]);
    expect(uris.map((uri) => uri.toString()), [
      'https://chessever.com/books/aB3dE5fG7h',
      'com.chessever.app://player/1503014',
    ]);
  });

  test('unrelated hosts are ignored', () {
    expect(
      parseDesktopIncomingLink(Uri.parse('https://example.com/books/abc')),
      isNull,
    );
  });
}
