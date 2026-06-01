import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/models.dart';

/// Repository for Gamebase API calls.
/// Handles communication with the Chess Database API.
class GamebaseRepository {
  GamebaseRepository({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      _baseUrl = baseUrl ?? _resolveBaseUrl();

  final http.Client _client;
  final String _baseUrl;

  static const Map<String, String> _releaseEnvValues = <String, String>{
    'SUPABASE_URL': String.fromEnvironment('SUPABASE_URL', defaultValue: ''),
    'SUPABASE_ANON_KEY': String.fromEnvironment(
      'SUPABASE_ANON_KEY',
      defaultValue: '',
    ),
    'GAMEBASE_PROXY_BASE': String.fromEnvironment(
      'GAMEBASE_PROXY_BASE',
      defaultValue: '',
    ),
  };

  static String _resolveBaseUrl() {
    final explicitProxy = _env('GAMEBASE_PROXY_BASE');
    if (explicitProxy != null && explicitProxy.isNotEmpty) {
      return _trimTrailingSlash(explicitProxy);
    }

    final supabaseUrl = _env('SUPABASE_URL');
    if (supabaseUrl != null && supabaseUrl.isNotEmpty) {
      return '${_trimTrailingSlash(supabaseUrl)}/functions/v1/gamebase-proxy';
    }

    return 'https://invalid.local/gamebase-proxy-not-configured';
  }

  static String? _env(String key) {
    final releaseValue = _releaseEnvValues[key]?.trim() ?? '';
    if (releaseValue.isNotEmpty) return releaseValue;
    if (kDebugMode) {
      try {
        final value = dotenv.env[key]?.trim();
        if (value != null && value.isNotEmpty) return value;
      } catch (_) {
        // dotenv not initialized; caller handles the missing value.
      }
    }
    return null;
  }

  static String _trimTrailingSlash(String value) =>
      value.endsWith('/') ? value.substring(0, value.length - 1) : value;

  Map<String, String> get _headers {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };

    final anonKey = _env('SUPABASE_ANON_KEY');
    if (anonKey == null || anonKey.isEmpty) return headers;

    String? accessToken;
    try {
      accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
    } catch (_) {
      accessToken = null;
    }

    headers['apikey'] = anonKey;
    headers['Authorization'] = 'Bearer ${accessToken ?? anonKey}';
    return headers;
  }

  /// Get move aggregates for a given FEN position.
  ///
  /// [fen] - FEN notation of the position to query
  /// [timeControl] - Optional time control filter (CLASSICAL, RAPID, BLITZ)
  /// [minRating] - Optional minimum rating filter
  /// [maxRating] - Optional maximum rating filter
  /// [playerId] - Optional player UUID to filter by
  Future<List<MoveAggregate>> getPositionAggregates({
    required String fen,
    TimeControl? timeControl,
    int? minRating,
    int? maxRating,
    String? playerId,
  }) async {
    try {
      final queryParams = <String, String>{'fen': fen};

      if (timeControl != null) {
        queryParams['timeControl'] = timeControl.name.toUpperCase();
      }

      if (minRating != null) {
        queryParams['minRating'] = minRating.toString();
      }

      if (maxRating != null) {
        queryParams['maxRating'] = maxRating.toString();
      }

      if (playerId != null && playerId.isNotEmpty) {
        queryParams['playerId'] = playerId;
      }

      final uri = Uri.parse(
        '$_baseUrl/api/game-position/aggregates',
      ).replace(queryParameters: queryParams);

      final response = await _client.get(uri, headers: _headers);

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseBody = json.decode(response.body);
        final List<dynamic> moves = responseBody['data']['moves'] ?? [];
        return moves.map((e) => MoveAggregate.fromJson(e)).toList();
      } else if (response.statusCode == 404) {
        // No games found for this position - return empty list
        return [];
      } else {
        throw GamebaseApiException(
          'Failed to get position aggregates',
          statusCode: response.statusCode,
          body: response.body,
        );
      }
    } catch (e) {
      if (e is GamebaseApiException) rethrow;
      throw GamebaseApiException('Network error: $e');
    }
  }

  /// Get a list of players matching the search criteria.
  ///
  /// [name] - Optional name to search for
  /// [pageNumber] - Page number for pagination (0-indexed per API spec)
  /// [pageSize] - Results per page (default: 20)
  Future<List<GamebasePlayer>> getPlayers({
    String? name,
    int pageNumber = 0,
    int pageSize = 20,
  }) async {
    try {
      final queryParams = <String, String>{
        'pageNumber': pageNumber.toString(),
        'pageSize': pageSize.toString(),
      };

      if (name != null && name.isNotEmpty) {
        queryParams['name'] = name;
      }

      final uri = Uri.parse(
        '$_baseUrl/api/player',
      ).replace(queryParameters: queryParams);

      final response = await _client.get(uri, headers: _headers);

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseBody = json.decode(response.body);
        final List<dynamic> data = responseBody['data'] ?? [];
        return data.map((e) => GamebasePlayer.fromJson(e)).toList();
      } else {
        throw GamebaseApiException(
          'Failed to get players',
          statusCode: response.statusCode,
          body: response.body,
        );
      }
    } catch (e) {
      if (e is GamebaseApiException) rethrow;
      throw GamebaseApiException('Network error: $e');
    }
  }

  /// Get a player by their ID.
  ///
  /// [id] - The player's UUID
  Future<GamebasePlayer?> getPlayerById(String id) async {
    try {
      final uri = Uri.parse('$_baseUrl/api/player/$id');
      final response = await _client.get(uri, headers: _headers);

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseBody = json.decode(response.body);
        return GamebasePlayer.fromJson(responseBody['data']);
      } else if (response.statusCode == 404) {
        return null;
      } else {
        throw GamebaseApiException(
          'Failed to get player',
          statusCode: response.statusCode,
          body: response.body,
        );
      }
    } catch (e) {
      if (e is GamebaseApiException) rethrow;
      throw GamebaseApiException('Network error: $e');
    }
  }

  /// Get a game by its ID.
  ///
  /// [id] - The game's UUID
  Future<GamebaseGame?> getGameById(String id) async {
    try {
      final uri = Uri.parse('$_baseUrl/api/game/$id');
      final response = await _client.get(uri, headers: _headers);

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseBody = json.decode(response.body);
        return GamebaseGame.fromJson(responseBody['data']);
      } else if (response.statusCode == 404) {
        return null;
      } else {
        throw GamebaseApiException(
          'Failed to get game',
          statusCode: response.statusCode,
          body: response.body,
        );
      }
    } catch (e) {
      if (e is GamebaseApiException) rethrow;
      throw GamebaseApiException('Network error: $e');
    }
  }

  /// Dispose the HTTP client when done.
  void dispose() {
    _client.close();
  }
}

/// Exception thrown when Gamebase API calls fail.
class GamebaseApiException implements Exception {
  GamebaseApiException(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  @override
  String toString() {
    final buffer = StringBuffer('GamebaseApiException: $message');
    if (statusCode != null) {
      buffer.write(' (status: $statusCode)');
    }
    if (body != null && kDebugMode) {
      buffer.write('\nResponse: $body');
    }
    return buffer.toString();
  }
}
