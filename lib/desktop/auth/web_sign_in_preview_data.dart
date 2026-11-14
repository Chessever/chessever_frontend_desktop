import 'dart:convert';

import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/services/desktop_web_location.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/live_game_position_resolver.dart';
import 'package:flutter/services.dart';

/// A public, bounded visual snapshot. It contains no account identity, private
/// library content, PGN, credentials or entitlement state. Loading it never
/// creates a session or calls an authenticated feature API.
class WebSignInPreviewData {
  WebSignInPreviewData({
    required this.capturedAt,
    required this.likes,
    required this.labels,
    this.events = const [],
  });
  final DateTime? capturedAt;
  final Map<String, List<WebSignInPreviewGame>> likes;
  final Map<String, String> labels;
  final List<Map<String, dynamic>> events;

  static Future<WebSignInPreviewData> load() async =>
      WebSignInPreviewData.fromJson(
        jsonDecode(
              await rootBundle.loadString(
                'assets/web_preview/public_preview.json',
              ),
            )
            as Map<String, dynamic>,
      );

  factory WebSignInPreviewData.fromJson(Map<String, dynamic> json) {
    final raw = json['likes'] as Map? ?? const {};
    return WebSignInPreviewData(
      capturedAt: DateTime.tryParse(json['capturedAt']?.toString() ?? ''),
      likes: {
        for (final period in const ['today', 'week', 'month', 'year'])
          period: [
            for (final row in ((raw[period] as List?) ?? const []).take(12))
              if (row is Map)
                if (WebSignInPreviewGame.tryParse(
                      Map<String, dynamic>.from(row),
                    )
                    case final game?)
                  game,
          ],
      },
      labels: {
        for (final entry in (json['labels'] as Map? ?? const {}).entries)
          entry.key.toString(): entry.value.toString(),
      },
      events: [
        for (final row in (json['events'] as List? ?? const []).take(12))
          if (row is Map) Map<String, dynamic>.from(row),
      ],
    );
  }

  List<WebSignInPreviewGame> games(String period) => likes[period] ?? const [];
}

class WebSignInPreviewGame {
  const WebSignInPreviewGame({
    required this.card,
    required this.likes,
    required this.rank,
  });
  final GameCardData card;
  final int likes;
  final int rank;

  static WebSignInPreviewGame? tryParse(Map<String, dynamic> row) {
    String text(String key) => row[key]?.toString().trim() ?? '';
    int number(String key) =>
        row[key] is num
            ? (row[key] as num).toInt()
            : int.tryParse(text(key)) ?? 0;
    if (text('gameId').isEmpty ||
        text('whiteName').isEmpty ||
        text('blackName').isEmpty ||
        !isValidGameFen(text('fen'))) {
      return null;
    }
    return WebSignInPreviewGame(
      likes: number('likes'),
      rank: number('rank'),
      card: GameCardData(
        id: text('gameId'),
        title: text('event'),
        whiteName: text('whiteName'),
        blackName: text('blackName'),
        whiteTitle: text('whiteTitle'),
        blackTitle: text('blackTitle'),
        whiteFederation: text('whiteFederation'),
        blackFederation: text('blackFederation'),
        whiteRating: number('whiteRating'),
        blackRating: number('blackRating'),
        fen: text('fen'),
        status: GameStatus.fromString(text('result')),
        hasStarted: true,
        canResolveRemoteFen: false,
      ),
    );
  }
}

/// Presentation identity only. Never opens a tab, changes the URL, reads a
/// private cache, or admits work. The real router owns the destination after
/// authentication, including its complete path and query.
class WebSignInPreviewLocation {
  const WebSignInPreviewLocation(
    this.title,
    this.pane,
    this.kind, {
    this.period = 'week',
  });
  final String title;
  final DesktopPane pane;
  final String kind;
  final String period;

  factory WebSignInPreviewLocation.fromKind(TabKind kind) => switch (kind) {
    TabKind.board => const WebSignInPreviewLocation(
      'Board',
      DesktopPane.board,
      'board',
    ),
    TabKind.tournaments => const WebSignInPreviewLocation(
      'Home',
      DesktopPane.tournaments,
      'events',
    ),
    TabKind.tournamentDetail => const WebSignInPreviewLocation(
      'Event',
      DesktopPane.tournaments,
      'games',
    ),
    TabKind.smartGames => const WebSignInPreviewLocation(
      'Games',
      DesktopPane.tournaments,
      'games',
    ),
    TabKind.likes => const WebSignInPreviewLocation(
      'Likes',
      DesktopPane.tournaments,
      'likes',
    ),
    TabKind.library || TabKind.databaseWorkspace =>
      const WebSignInPreviewLocation('Library', DesktopPane.library, 'library'),
    TabKind.collections ||
    TabKind.collectionWorkspace => const WebSignInPreviewLocation(
      'Collections',
      DesktopPane.collections,
      'collections',
    ),
    TabKind.favorites => const WebSignInPreviewLocation(
      'Favorites',
      DesktopPane.favorites,
      'private',
    ),
    TabKind.players => const WebSignInPreviewLocation(
      'Prepare',
      DesktopPane.players,
      'players',
    ),
    TabKind.rankings => const WebSignInPreviewLocation(
      'Rankings',
      DesktopPane.rankings,
      'players',
    ),
    TabKind.calendar => const WebSignInPreviewLocation(
      'Home',
      DesktopPane.tournaments,
      'events',
    ),
    TabKind.countrymen => const WebSignInPreviewLocation(
      'Countrymen',
      DesktopPane.countrymen,
      'games',
    ),
    TabKind.openingExplorer => const WebSignInPreviewLocation(
      'Opening Explorer',
      DesktopPane.openingExplorer,
      'board',
    ),
    TabKind.boardEditor => const WebSignInPreviewLocation(
      'Board Editor',
      DesktopPane.boardEditor,
      'board',
    ),
    TabKind.play => const WebSignInPreviewLocation(
      'Play',
      DesktopPane.play,
      'board',
    ),
    TabKind.watch => const WebSignInPreviewLocation(
      'Watch',
      DesktopPane.board,
      'board',
    ),
    TabKind.settings || TabKind.boardSettings => const WebSignInPreviewLocation(
      'Settings',
      DesktopPane.settings,
      'private',
    ),
    TabKind.inbox => const WebSignInPreviewLocation(
      'Inbox',
      DesktopPane.inbox,
      'private',
    ),
    TabKind.howToUse => const WebSignInPreviewLocation(
      'Home',
      DesktopPane.tournaments,
      'events',
    ),
    TabKind.playerProfile || TabKind.playerScoreCard =>
      const WebSignInPreviewLocation('Player', DesktopPane.players, 'players'),
    TabKind.teamScoreCard => const WebSignInPreviewLocation(
      'Team',
      DesktopPane.tournaments,
      'players',
    ),
    TabKind.userProfile => const WebSignInPreviewLocation(
      'Account',
      DesktopPane.settings,
      'private',
    ),
  };

  factory WebSignInPreviewLocation.fromUri(Uri uri) {
    final known = desktopWebListKind(uri);
    if (known != null) return WebSignInPreviewLocation.fromKind(known);
    final p = uri.pathSegments;
    final first = p.firstOrNull ?? '';
    final app = first == 'app' && p.length > 1 ? p[1] : first;
    if (first == 'broadcast' && p.length > 1) {
      return WebSignInPreviewLocation.fromKind(TabKind.tournamentDetail);
    }
    if (app == 'likes') {
      return WebSignInPreviewLocation(
        'Likes',
        DesktopPane.tournaments,
        'likes',
        period:
            p
                .where(const ['today', 'week', 'month', 'year'].contains)
                .firstOrNull ??
            'week',
      );
    }
    if (app == 'miniatures') {
      return const WebSignInPreviewLocation(
        'Miniatures',
        DesktopPane.tournaments,
        'games',
      );
    }
    if (first == 'games' || first == 'analysis') {
      return const WebSignInPreviewLocation(
        'Board',
        DesktopPane.board,
        'board',
      );
    }
    if (first == 'player' ||
        first == 'players' ||
        first == 'chess-players' ||
        app == 'prepare') {
      return const WebSignInPreviewLocation(
        'Prepare',
        DesktopPane.players,
        'players',
      );
    }
    if (first == 'rankings') {
      return const WebSignInPreviewLocation(
        'Rankings',
        DesktopPane.rankings,
        'players',
      );
    }
    if (first == 'calendar') {
      return const WebSignInPreviewLocation(
        'Home',
        DesktopPane.tournaments,
        'events',
      );
    }
    if (first == 'collections') {
      return const WebSignInPreviewLocation(
        'Collections',
        DesktopPane.collections,
        'collections',
      );
    }
    if (const ['databases', 'library', 'folders', 'books'].contains(first) ||
        app == 'library') {
      return const WebSignInPreviewLocation(
        'Library',
        DesktopPane.library,
        'library',
      );
    }
    if (first == 'favorites') {
      return const WebSignInPreviewLocation(
        'Favorites',
        DesktopPane.favorites,
        'private',
      );
    }
    if (first == 'countrymen') {
      return const WebSignInPreviewLocation(
        'Countrymen',
        DesktopPane.countrymen,
        'games',
      );
    }
    if (first == 'play') {
      return const WebSignInPreviewLocation('Play', DesktopPane.play, 'board');
    }
    if (app == 'inbox') {
      return const WebSignInPreviewLocation(
        'Inbox',
        DesktopPane.inbox,
        'private',
      );
    }
    if (app == 'botvinnik') {
      return const WebSignInPreviewLocation(
        'Botvinnik',
        DesktopPane.inbox,
        'private',
      );
    }
    if (first == 'account' ||
        uri.queryParameters['section'] != null ||
        uri.path.contains('/settings')) {
      return const WebSignInPreviewLocation(
        'Settings',
        DesktopPane.settings,
        'private',
      );
    }
    if (first == 'learn') {
      return const WebSignInPreviewLocation(
        'Home',
        DesktopPane.tournaments,
        'events',
      );
    }
    return const WebSignInPreviewLocation(
      'Home',
      DesktopPane.tournaments,
      'events',
    );
  }
}
