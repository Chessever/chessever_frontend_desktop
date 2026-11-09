import 'dart:convert';

import 'package:chessever/desktop/services/likes/community_likes_models.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/live_game_position_resolver.dart';
import 'package:chessever/web/sign_in_preview_time_zone.dart';
import 'package:chessever/web/web_mount.dart';
import 'package:http/http.dart' as http;

/// A bounded read from our own public, server-side projection. This client
/// never receives a privileged key, creates a session, or calls protected RPCs.
class WebSignInPublicDataClient {
  WebSignInPublicDataClient({
    Uri? origin,
    String? mount,
    http.Client? client,
    String Function()? timeZone,
  }) : _origin = origin ?? Uri.base,
       _mount = mount ?? webMountPath,
       _client = client ?? http.Client(),
       _timeZone = timeZone ?? signInPreviewTimeZone;

  final Uri _origin;
  // '/' on app.chessever.com, '/webapp/' on chessever.com (web_mount.dart).
  final String _mount;
  final http.Client _client;
  final String Function() _timeZone;

  Future<PublicLikesPreview> likes(CommunityLikesQuery query) async {
    final raw = await _get('likes', {
      'period': query.period.name,
      'from': query.start.toUtc().toIso8601String(),
      'to': query.end.toUtc().toIso8601String(),
      'timeZone': _timeZone(),
    });
    return PublicLikesPreview.fromJson(raw, query);
  }

  /// Decoding into the actual For You presentation models belongs to the
  /// Events presentation adapter, not an alternative event selection query.
  Future<Map<String, dynamic>> events() async {
    final raw = await _get('events', const {});
    _validateEnvelope(raw, 'for-you');
    if (raw['events'] is! List ||
        raw['games'] is! List ||
        (raw['events'] as List).length > 20 ||
        (raw['games'] as List).length > 240) {
      throw const FormatException('Invalid public Events projection');
    }
    return raw;
  }

  Future<Map<String, dynamic>> _get(
    String resource,
    Map<String, String> parameters,
  ) async {
    if (!const {'http', 'https'}.contains(_origin.scheme) ||
        _origin.host.isEmpty ||
        _origin.userInfo.isNotEmpty) {
      throw StateError('Public preview requires an application origin');
    }
    final uri = _origin.replace(
      path: webBrowserPath('/api/signin-preview/$resource', _mount),
      queryParameters: parameters.isEmpty ? null : parameters,
      fragment: '',
    );
    final response = await _client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      // Never turn denied/missing APIs into zero counts or an empty success,
      // and never copy a backend response (which could contain diagnostics).
      throw StateError('Public destination preview is unavailable');
    }
    if (response.bodyBytes.length > 1024 * 1024) {
      throw const FormatException('Public destination preview exceeds its cap');
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid public destination projection');
    }
    return json;
  }

  void close() => _client.close();
}

/// Real identities and aggregate counts, decoded through the same models and
/// deterministic ranking helpers as the authenticated production Likes pane.
class PublicLikesPreview {
  const PublicLikesPreview({required this.generatedAt, required this.result});

  final DateTime generatedAt;
  final CommunityLikesResult result;

  factory PublicLikesPreview.fromJson(
    Map<String, dynamic> json,
    CommunityLikesQuery query,
  ) {
    final generatedAt = _validateEnvelope(json, 'community-likes');
    final from = DateTime.tryParse(json['from']?.toString() ?? '');
    final to = DateTime.tryParse(json['to']?.toString() ?? '');
    if (json['period'] != query.period.name ||
        from == null ||
        to == null ||
        !from.isAtSameMomentAs(query.start) ||
        !to.isAtSameMomentAs(query.end)) {
      throw const FormatException('Public ranking window does not match');
    }
    final rows = json['rows'];
    final games = json['games'];
    if (rows is! List ||
        games is! List ||
        rows.length > kCommunityLikesPageSize ||
        games.length > kCommunityLikesPageSize) {
      throw const FormatException('Invalid bounded ranking projection');
    }
    final ids = <String>{};
    for (final row in rows) {
      if (row is! Map ||
          row['source_game_id'] is! String ||
          (row['source_game_id'] as String).isEmpty ||
          row['source_game_id'] != (row['source_game_id'] as String).trim() ||
          row['like_count'] is! int ||
          (row['like_count'] as int) < 2 ||
          !ids.add(row['source_game_id'] as String)) {
        throw const FormatException(
          'Unknown or invalid ranking identity/count',
        );
      }
    }
    final models = <String, GamesTourModel>{};
    for (final raw in games) {
      if (raw is! Map ||
          raw.containsKey('pgn') ||
          raw['id'] is! String ||
          !ids.contains(raw['id']) ||
          !isValidGameFen(raw['fen']?.toString() ?? '')) {
        throw const FormatException('Invalid public ranking game');
      }
      final game = Games.fromJson(Map<String, dynamic>.from(raw));
      final model = GamesTourModel.fromGame(game);
      final event = model.tourName?.trim();
      if (models.containsKey(game.id)) {
        throw const FormatException('Repeated public ranking game');
      }
      models[game.id] =
          (event != null && event.isNotEmpty && model.eventName == null)
              ? model.copyWith(eventName: event)
              : model;
    }
    if (models.length != ids.length) {
      throw const FormatException('Public ranking has unresolved games');
    }
    return PublicLikesPreview(
      generatedAt: generatedAt,
      result: CommunityLikesResult.ranked(
        assembleCommunityLikesEntries(
          counts: parseCommunityLikesRows(rows),
          gamesById: models,
        ),
      ),
    );
  }
}

DateTime _validateEnvelope(Map<String, dynamic> json, String dataset) {
  final generatedAt = DateTime.tryParse(json['generatedAt']?.toString() ?? '');
  if (json['schemaVersion'] != 1 ||
      json['dataset'] != dataset ||
      generatedAt == null ||
      !generatedAt.isUtc) {
    throw const FormatException('Invalid public destination envelope');
  }
  return generatedAt;
}
