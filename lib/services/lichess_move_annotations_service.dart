import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

enum LichessMoveAnnotationType {
  brilliant,
  missedWin,
  mistake,
  blunder,
  inaccuracy,
  goodMove,
  bestMove,
  forced,
  bookMove,
}

class LichessMoveAnnotation {
  final LichessMoveAnnotationType type;
  final String comment;
  final bool useClassificationIcon;
  final bool reportOwnsMoveQuality;

  const LichessMoveAnnotation({
    required this.type,
    required this.comment,
    this.useClassificationIcon = false,
    this.reportOwnsMoveQuality = false,
  });
}

class LichessMoveAnnotationsService {
  LichessMoveAnnotationsService._();

  static final Map<String, Map<int, LichessMoveAnnotation>?> _cache = {};
  static final Set<String> _attemptedFetches = {};
  static final _broadcastRequests =
      <String, Future<Map<int, LichessMoveAnnotation>?>>{};
  static final _lichessId = RegExp(r'^[A-Za-z0-9]{8}$');
  static final _sanCheckSuffix = RegExp(r'[+#]+$');
  static final _broadcastJudgment = RegExp(
    r'^(Inaccuracy|Mistake|Blunder)\.\s+\S',
  );

  static ({String roundId, String gameId})? broadcastIdsFromUrl(String? url) {
    final uri = Uri.tryParse(url?.trim() ?? '');
    if (uri == null || uri.scheme != 'https' || uri.host != 'lichess.org') {
      return null;
    }
    final path = uri.pathSegments;
    if (path.length != 5 || path.first != 'broadcast') return null;
    final roundId = path[3];
    final gameId = path[4];
    if (!_lichessId.hasMatch(roundId) || !_lichessId.hasMatch(gameId)) {
      return null;
    }
    return (roundId: roundId, gameId: gameId);
  }

  static Future<Map<int, LichessMoveAnnotation>?> getAnnotations({
    required String lichessGameId,
    required List<String> moveSans,
    required String signature,
    String? siteUrl,
    String? broadcastRoundId,
    bool forceRefresh = false,
  }) async {
    if (lichessGameId.isEmpty || moveSans.isEmpty) return null;

    if (broadcastRoundId != null &&
        _lichessId.hasMatch(broadcastRoundId) &&
        _lichessId.hasMatch(lichessGameId)) {
      final uri = Uri.https(
        'lichess.org',
        '/api/study/$broadcastRoundId/$lichessGameId.pgn',
        {'comments': 'true', 'variations': 'false'},
      );
      final key = '$uri::$signature';
      if (!forceRefresh && _cache.containsKey(key)) return _cache[key];
      final request = _broadcastRequests.putIfAbsent(
        key,
        () => _fetchBroadcastAnnotations(uri, moveSans),
      );
      try {
        final annotations = await request;
        if (annotations != null) _cache[key] = annotations;
        return annotations;
      } finally {
        if (identical(_broadcastRequests[key], request)) {
          _broadcastRequests.remove(key);
        }
      }
    }

    final cacheKey = '$lichessGameId::$signature';
    if (!forceRefresh) {
      if (_cache.containsKey(cacheKey)) {
        final cached = _cache[cacheKey];
        debugPrint(
          '🔍 [AnnotationsService] Cache HIT for $lichessGameId: ${cached?.length ?? 0} annotations',
        );
        return cached;
      }
      if (_attemptedFetches.contains(cacheKey)) {
        debugPrint(
          '🔍 [AnnotationsService] Already attempted fetch for $lichessGameId, skipping',
        );
        return null;
      }
    }

    try {
      final response = await Supabase.instance.client.functions.invoke(
        'fetch-lichess-annotations',
        body: {
          'game_id': lichessGameId,
          'moves_signature': signature,
          'moves': moveSans,
          'force_refresh': forceRefresh,
          if (siteUrl != null) 'site_url': siteUrl,
        },
      );

      _attemptedFetches.add(cacheKey);

      final rawData = response.data;
      if (rawData is! Map) {
        debugPrint('Lichess annotations error: unexpected response shape');
        _cache[cacheKey] = null;
        return null;
      }

      final data = Map<String, dynamic>.from(rawData);
      final responseSignature = data['moves_signature'] as String?;
      if (responseSignature != null && responseSignature != signature) {
        debugPrint('🔍 [AnnotationsService] Signature mismatch!');
        debugPrint('🔍 [AnnotationsService] Requested: $signature');
        debugPrint('🔍 [AnnotationsService] Response:  $responseSignature');
        _cache[cacheKey] = null;
        return null;
      }

      final annotationsRaw = data['annotations'];
      if (annotationsRaw is! Map<String, dynamic>) {
        _cache[cacheKey] = null;
        return null;
      }

      final annotations = <int, LichessMoveAnnotation>{};
      for (final entry in annotationsRaw.entries) {
        final index = int.tryParse(entry.key);
        if (index == null) continue;
        if (entry.value is! Map<String, dynamic>) continue;
        final payload = entry.value as Map<String, dynamic>;
        final name = payload['name'] as String?;
        final comment = (payload['comment'] as String?) ?? '';
        final type = _annotationTypeFromName(name);
        if (type == null) continue;
        annotations[index] = LichessMoveAnnotation(
          type: type,
          comment: comment,
        );
      }

      debugPrint(
        '🔍 [AnnotationsService] Parsed ${annotations.length} annotations: ${annotations.keys.toList()}',
      );
      _cache[cacheKey] = annotations;
      return annotations;
    } catch (e) {
      debugPrint('Failed to fetch Lichess annotations: $e');
      _attemptedFetches.add(cacheKey);
      _cache[cacheKey] = null;
      return null;
    }
  }

  static Future<Map<int, LichessMoveAnnotation>?> _fetchBroadcastAnnotations(
    Uri uri,
    List<String> moveSans,
  ) async {
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      return _parseBroadcastAnnotations(response.body, moveSans);
    } catch (error) {
      debugPrint('Failed to fetch Lichess broadcast annotations: $error');
      return null;
    }
  }

  static Map<int, LichessMoveAnnotation>? _parseBroadcastAnnotations(
    String pgn,
    List<String> moveSans,
  ) {
    final moves = PgnGame.parsePgn(pgn).moves.mainline().toList();
    if (moves.length != moveSans.length) return null;
    final annotations = <int, LichessMoveAnnotation>{};
    for (var i = 0; i < moves.length; i++) {
      final move = moves[i];
      if (move.san.replaceFirst(_sanCheckSuffix, '') !=
          moveSans[i].replaceFirst(_sanCheckSuffix, '')) {
        return null;
      }
      for (final rawComment in move.comments ?? const <String>[]) {
        final comment = rawComment.trim();
        final name = _broadcastJudgment.firstMatch(comment)?.group(1);
        final type = _annotationTypeFromName(name);
        if (type != null) {
          annotations[i] = LichessMoveAnnotation(type: type, comment: comment);
          break;
        }
      }
    }
    return Map.unmodifiable(annotations);
  }

  static void clearCache() {
    _cache.clear();
    _attemptedFetches.clear();
  }

  static LichessMoveAnnotationType? _annotationTypeFromName(String? name) {
    if (name == null || name.trim().isEmpty) return null;
    final normalized = name.trim().toLowerCase();
    switch (normalized) {
      case 'brilliant':
        return LichessMoveAnnotationType.brilliant;
      case 'missed win':
      case 'missed_win':
      case 'miss':
        return LichessMoveAnnotationType.missedWin;
      case 'mistake':
        return LichessMoveAnnotationType.mistake;
      case 'blunder':
        return LichessMoveAnnotationType.blunder;
      case 'inaccuracy':
        return LichessMoveAnnotationType.inaccuracy;
      case 'good move':
      case 'good_move':
      case 'good':
        return LichessMoveAnnotationType.goodMove;
      case 'best move':
      case 'best_move':
      case 'best':
        return LichessMoveAnnotationType.bestMove;
      case 'forced':
      case 'forced move':
      case 'forced_move':
        return LichessMoveAnnotationType.forced;
      case 'book move':
      case 'book_move':
      case 'book':
        return LichessMoveAnnotationType.bookMove;
      default:
        return null;
    }
  }
}
