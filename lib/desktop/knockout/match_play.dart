/// MATCH-PLAY KNOCKOUT ROUNDS: one round file, a whole match per pairing.
///
/// Chess.com's Speed Chess Championship publishes every match of a stage in
/// ONE round. Game 1 and game 2 of every match are created up front as 0-move
/// `*` shells, then each match grows game by game (blitz, then bullet) on its
/// own day, until the round holds ~200 boards a month later. Read as a plain
/// round that is a pile of unrelated rows whose players swap sides every game.
///
/// The rule (identical on the phone, on chessever.com and here; AGENTS.md
/// "Match-play knockouts"):
///  - GATE. A round of a KNOCKOUT event is match-play when one unordered pair
///    of players has 2+ games inside one source round. Every other round keeps
///    its existing code path; callers only opt in for knockout events.
///  - Identity: the unordered FIDE-id pair, else an order-independent name key.
///    Board numbers never identify anything: the ingest renumbers `board_nr`
///    every cycle to follow the source file, and PGN `[Board]` tags are junk.
///  - Game index: the PGN `[Round]` tag (`S.NN` -> NN, `S.SET.G` -> SET, G).
///    Rows without PGN (the board rail's lean rows) fall back to what a match
///    guarantees: finished games first (by last move time), then the game in
///    play, then the unplayed shells (by board number, then id).
///  - Side A is White of the match's earliest game (game 1 = the higher seed).
///    A stays first (left / top) in every row and in the header; colour is
///    shown by a small mark per player instead of by position.
///  - Score: A and B over every finished game of the round, whatever colour.
///  - A game is live only once it has a move and no result. A 0-move shell is
///    never live.
///  - Match order: live first (bracket order), then played matches most recent
///    first, then not-started matches in bracket order (the board of their
///    first game).
///  - Game order inside a match: the game in play, then finished games newest
///    first, then the unplayed shells in game order.
library;

import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/desktop_game_points.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart'
    show pgnHasMoves;
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

/// What the match-play rule needs from one game, whichever model carries it.
@immutable
class MatchPlayGameFacts {
  const MatchPlayGameFacts({
    required this.id,
    required this.roundId,
    required this.whiteName,
    required this.blackName,
    this.whiteFideId,
    this.blackFideId,
    this.boardNumber,
    this.pgn,
    required this.isFinished,
    required this.hasMoves,
    this.lastMoveTime,
    this.whitePoints,
    this.blackPoints,
  });

  final String id;

  /// The SOURCE round (the DB round), not a display stage that folds several.
  final String roundId;
  final String whiteName;
  final String blackName;
  final int? whiteFideId;
  final int? blackFideId;
  final int? boardNumber;

  /// Only read for its `[Round]` tag. Lean rows carry none.
  final String? pgn;
  final bool isFinished;

  /// At least one move has been played.
  final bool hasMoves;
  final DateTime? lastMoveTime;

  /// Points of a finished game; null while it is not finished.
  final double? whitePoints;
  final double? blackPoints;

  /// A game in play: it has a move and no result.
  bool get isLive => hasMoves && !isFinished;
}

/// Facts of a board-rail row ([TournamentGameSummary]).
MatchPlayGameFacts matchPlayFactsOfSummary(
  TournamentGameSummary game, {
  DateTime? now,
}) {
  final finished = game.status.isFinished;
  return MatchPlayGameFacts(
    id: game.id,
    roundId: game.roundId,
    whiteName: game.whitePlayer,
    blackName: game.blackPlayer,
    whiteFideId: game.whiteFideId,
    blackFideId: game.blackFideId,
    boardNumber: game.boardNumber,
    pgn: game.pgn,
    isFinished: finished,
    hasMoves: _summaryHasMoves(game, now: now ?? DateTime.now()),
    lastMoveTime: game.lastMoveTime,
    whitePoints:
        finished
            ? desktopGamePoints(
              game.status,
              isWhite: true,
              customPoints: game.whiteCustomPoints,
            )
            : null,
    blackPoints:
        finished
            ? desktopGamePoints(
              game.status,
              isWhite: false,
              customPoints: game.blackCustomPoints,
            )
            : null,
  );
}

/// Facts of a tournament Games tab card ([GamesTourModel]).
MatchPlayGameFacts matchPlayFactsOfTourModel(GamesTourModel game) {
  final status = game.effectiveGameStatus;
  final finished = status.isFinished;
  return MatchPlayGameFacts(
    id: game.gameId,
    roundId: game.roundId,
    whiteName: game.whitePlayer.name,
    blackName: game.blackPlayer.name,
    whiteFideId: game.whitePlayer.fideId,
    blackFideId: game.blackPlayer.fideId,
    boardNumber: game.boardNr,
    pgn: game.pgn,
    isFinished: finished,
    hasMoves: game.hasStarted || _isPlayedFen(game.fen),
    lastMoveTime: game.lastMoveTime,
    whitePoints:
        finished
            ? desktopGamePoints(
              status,
              isWhite: true,
              customPoints: game.whitePlayer.customPoints,
            )
            : null,
    blackPoints:
        finished
            ? desktopGamePoints(
              status,
              isWhite: false,
              customPoints: game.blackPlayer.customPoints,
            )
            : null,
  );
}

/// Identity-only facts of a [GamesTourModel]: all [isMatchPlayRound] reads,
/// without the result and position work of [matchPlayFactsOfTourModel].
MatchPlayGameFacts matchPlayIdentityOfTourModel(GamesTourModel game) =>
    MatchPlayGameFacts(
      id: game.gameId,
      roundId: game.roundId,
      whiteName: game.whitePlayer.name,
      blackName: game.blackPlayer.name,
      whiteFideId: game.whitePlayer.fideId,
      blackFideId: game.blackPlayer.fideId,
      boardNumber: game.boardNr,
      isFinished: false,
      hasMoves: false,
    );

bool _summaryHasMoves(TournamentGameSummary game, {required DateTime now}) {
  if (game.hasStarted) return true;
  final lastMoveTime = game.lastMoveTime;
  if (lastMoveTime != null && !lastMoveTime.isAfter(now)) return true;
  if (pgnHasMoves(game.pgn)) return true;
  return _isPlayedFen(game.fen);
}

bool _isPlayedFen(String? fen) {
  final board = fen?.trim().split(RegExp(r'\s+')).first ?? '';
  return board.isNotEmpty && board != _initialBoard;
}

const String _initialBoard = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR';

/// A game's position inside its match, from the PGN `[Round]` tag.
///
/// `01.02` is stage 1, game 2 (`set` 0); `03.02.03` is stage 3, set 2, game 3.
/// Null when there is no PGN, no tag, or the tag is not all-numeric `S.NN` /
/// `S.SET.G`.
@visibleForTesting
({int set, int game})? matchPlayGameIndexFromPgn(String? pgn) {
  if (pgn == null || pgn.isEmpty) return null;
  // Tags sit at the top; never scan a long movetext for a missing tag.
  final head = pgn.length > 4096 ? pgn.substring(0, 4096) : pgn;
  final value = _pgnRoundTag.firstMatch(head)?.group(1)?.trim();
  if (value == null || value.isEmpty) return null;
  final parts = value.split('.');
  if (parts.length != 2 && parts.length != 3) return null;
  final numbers = <int>[];
  for (final part in parts) {
    final number = int.tryParse(part.trim());
    if (number == null || number < 0) return null;
    numbers.add(number);
  }
  return parts.length == 2
      ? (set: 0, game: numbers[1])
      : (set: numbers[1], game: numbers[2]);
}

final RegExp _pgnRoundTag = RegExp(
  r'^\s*\[Round\s+"([^"]*)"\s*\]',
  multiLine: true,
);

/// What a match is doing right now.
enum MatchPlayState { live, played, notStarted }

/// One match of a match-play round.
@immutable
class MatchPlayMatch<T> {
  const MatchPlayMatch._({
    required this.key,
    required this.chronologicalGames,
    required this.chronologicalFacts,
    required this.displayGames,
    required this.aPoints,
    required this.bPoints,
    required this.finishedGames,
    required this.state,
    required this.lastActivity,
    required this.bracketBoard,
    required Map<String, bool> anchorIsWhiteById,
  }) : _anchorIsWhiteById = anchorIsWhiteById;

  /// Order-independent identity of the pairing (`fide:1|fide:2`).
  final String key;

  /// Game 1 first.
  final List<T> chronologicalGames;
  final List<MatchPlayGameFacts> chronologicalFacts;

  /// The game in play, finished games newest first, then unplayed shells.
  final List<T> displayGames;

  /// Side A (White of game 1) and side B over every finished game.
  final double aPoints;
  final double bPoints;
  final int finishedGames;
  final MatchPlayState state;

  /// Latest move time over the match's started games; null while unplayed.
  final DateTime? lastActivity;

  /// Board of the match's first game: the bracket order of the source file.
  final int bracketBoard;
  final Map<String, bool> _anchorIsWhiteById;

  /// Game 1. Its White is side A, its Black side B.
  T get firstGame => chronologicalGames.first;
  MatchPlayGameFacts get firstFacts => chronologicalFacts.first;

  bool get isLive => state == MatchPlayState.live;
  bool get hasReportedScore => finishedGames > 0;

  /// Whether side A has White in [gameId]. A game outside this match reads
  /// as White so callers fall back to the ordinary White-first layout.
  bool anchorIsWhite(String gameId) => _anchorIsWhiteById[gameId] ?? true;

  Map<String, bool> get anchorIsWhiteById => _anchorIsWhiteById;
}

/// A match-play round: its matches in display order, plus the boards that
/// have no usable player identity (they stay loose rows after the matches).
@immutable
class MatchPlayRound<T> {
  const MatchPlayRound._({required this.matches, required this.looseGames});

  final List<MatchPlayMatch<T>> matches;
  final List<T> looseGames;

  /// Every game in the order the round renders it.
  List<T> get orderedGames => <T>[
    for (final match in matches) ...match.displayGames,
    ...looseGames,
  ];

  MatchPlayMatch<T>? matchOfGame(String gameId) {
    for (final match in matches) {
      if (match.anchorIsWhiteById.containsKey(gameId)) return match;
    }
    return null;
  }
}

/// Cheap pre-check for [isMatchPlayRound]: one source round holds two rows of
/// the same unordered name pair or FIDE-id pair. No identity normalization
/// and no regular expressions, so it can run on every rail build and every
/// refresh; [isMatchPlayRound] stays the real gate.
bool mayHoldMatchPlayPairs<T>(
  Iterable<T> games,
  ({
    String roundId,
    String white,
    String black,
    int? whiteFideId,
    int? blackFideId,
  })
  Function(T game)
  keysOf,
) {
  final seen = <String>{};
  for (final game in games) {
    final keys = keysOf(game);
    final round = keys.roundId.trim();
    final white = keys.white.trim().toLowerCase();
    final black = keys.black.trim().toLowerCase();
    if (white.isNotEmpty && black.isNotEmpty && white != black) {
      final pair =
          white.compareTo(black) < 0
              ? '$white\u0000$black'
              : '$black\u0000$white';
      if (!seen.add('$round\u0001name\u0001$pair')) return true;
    }
    final whiteId = keys.whiteFideId ?? 0;
    final blackId = keys.blackFideId ?? 0;
    if (whiteId > 0 && blackId > 0 && whiteId != blackId) {
      final pair =
          whiteId < blackId ? '$whiteId-$blackId' : '$blackId-$whiteId';
      if (!seen.add('$round\u0001fide\u0001$pair')) return true;
    }
  }
  return false;
}

/// THE GATE: one unordered pair has 2+ games inside one source round.
///
/// The caller decides that the event is a knockout; this answers only for the
/// games handed in. Pairs whose games sit in different source rounds (World
/// Cup game-1 / game-2 rounds) do not count.
bool isMatchPlayRound<T>(
  Iterable<T> games,
  MatchPlayGameFacts Function(T game) factsOf,
) {
  final facts = [for (final game in games) factsOf(game)];
  if (facts.length < 2) return false;
  final identities = _Identities(facts);
  final seen = <String>{};
  for (final game in facts) {
    final key = identities.pairKey(game);
    if (key == null) continue;
    if (!seen.add('${game.roundId.trim()}\u0000$key')) return true;
  }
  return false;
}

/// Folds a match-play round into its matches, or returns null when [games]
/// is not a match-play round (see [isMatchPlayRound]).
MatchPlayRound<T>? buildMatchPlayRound<T>(
  Iterable<T> games,
  MatchPlayGameFacts Function(T game) factsOf,
) {
  final entries = [
    for (final game in games) _Entry<T>(game: game, facts: factsOf(game)),
  ];
  if (!isMatchPlayRound<_Entry<T>>(entries, (entry) => entry.facts)) {
    return null;
  }
  final identities = _Identities([for (final entry in entries) entry.facts]);
  final buckets = <String, List<_Entry<T>>>{};
  final loose = <T>[];
  for (final entry in entries) {
    final key = identities.pairKey(entry.facts);
    if (key == null) {
      loose.add(entry.game);
      continue;
    }
    buckets.putIfAbsent(key, () => <_Entry<T>>[]).add(entry);
  }

  final matches = <MatchPlayMatch<T>>[
    for (final bucket in buckets.entries)
      _buildMatch(bucket.key, bucket.value, identities),
  ]..sort(_compareMatches);
  return MatchPlayRound<T>._(
    matches: List<MatchPlayMatch<T>>.unmodifiable(matches),
    looseGames: List<T>.unmodifiable(loose),
  );
}

MatchPlayMatch<T> _buildMatch<T>(
  String key,
  List<_Entry<T>> games,
  _Identities identities,
) {
  final chronological = _chronological(games);
  final first = chronological.first.facts;
  final anchorId = identities.idFor(first.whiteName, first.whiteFideId);
  final anchorIsWhiteById = <String, bool>{};
  var aPoints = 0.0;
  var bPoints = 0.0;
  var finished = 0;
  var live = false;
  var started = false;
  DateTime? lastActivity;
  for (final entry in chronological) {
    final facts = entry.facts;
    final whiteId = identities.idFor(facts.whiteName, facts.whiteFideId);
    final blackId = identities.idFor(facts.blackName, facts.blackFideId);
    final anchorIsWhite = whiteId == anchorId || blackId != anchorId;
    anchorIsWhiteById[facts.id] = anchorIsWhite;
    if (facts.isLive) live = true;
    if (facts.isFinished || facts.hasMoves) {
      started = true;
      final at = facts.lastMoveTime;
      if (at != null && (lastActivity == null || at.isAfter(lastActivity))) {
        lastActivity = at;
      }
    }
    if (!facts.isFinished) continue;
    final white = facts.whitePoints;
    final black = facts.blackPoints;
    if (white == null || black == null) continue;
    finished++;
    aPoints += anchorIsWhite ? white : black;
    bPoints += anchorIsWhite ? black : white;
  }

  return MatchPlayMatch<T>._(
    key: key,
    chronologicalGames: List<T>.unmodifiable([
      for (final entry in chronological) entry.game,
    ]),
    chronologicalFacts: List<MatchPlayGameFacts>.unmodifiable([
      for (final entry in chronological) entry.facts,
    ]),
    displayGames: List<T>.unmodifiable(_displayOrder(chronological)),
    aPoints: aPoints,
    bPoints: bPoints,
    finishedGames: finished,
    state:
        live
            ? MatchPlayState.live
            : started
            ? MatchPlayState.played
            : MatchPlayState.notStarted,
    lastActivity: lastActivity,
    bracketBoard: first.boardNumber ?? _noBoard,
    anchorIsWhiteById: Map<String, bool>.unmodifiable(anchorIsWhiteById),
  );
}

/// Game 1 first. When every game carries a `[Round]` game index, the index
/// decides. Otherwise, a match being played one game after another, finished
/// games come first (by index when they all have one, else by last move time),
/// then the game in play, then the unplayed shells (by index when they all
/// have one, else board number). Ties end on board number then id, so the
/// order never depends on the input order.
List<_Entry<T>> _chronological<T>(List<_Entry<T>> games) {
  int byIndex(_Entry<T> a, _Entry<T> b) {
    final aIndex = a.index!;
    final bIndex = b.index!;
    final bySet = aIndex.set.compareTo(bIndex.set);
    return bySet != 0 ? bySet : aIndex.game.compareTo(bIndex.game);
  }

  bool allIndexed(Iterable<_Entry<T>> list) =>
      list.every((entry) => entry.index != null);

  if (allIndexed(games)) {
    return games.toList()..sort((a, b) {
      final index = byIndex(a, b);
      return index != 0 ? index : _compareBoardThenId(a.facts, b.facts);
    });
  }

  final finished = <_Entry<T>>[];
  final live = <_Entry<T>>[];
  final unstarted = <_Entry<T>>[];
  for (final entry in games) {
    if (entry.facts.isFinished) {
      finished.add(entry);
    } else if (entry.facts.hasMoves) {
      live.add(entry);
    } else {
      unstarted.add(entry);
    }
  }

  void sortTier(List<_Entry<T>> tier, {bool byLastMoveTime = false}) {
    final indexed = allIndexed(tier);
    tier.sort((a, b) {
      if (indexed) {
        final index = byIndex(a, b);
        if (index != 0) return index;
      } else if (byLastMoveTime) {
        final aTime = a.facts.lastMoveTime;
        final bTime = b.facts.lastMoveTime;
        if (aTime != null && bTime != null) {
          final byTime = aTime.compareTo(bTime);
          if (byTime != 0) return byTime;
        } else if (aTime != null) {
          return -1;
        } else if (bTime != null) {
          return 1;
        }
      }
      return _compareBoardThenId(a.facts, b.facts);
    });
  }

  sortTier(finished, byLastMoveTime: true);
  sortTier(live);
  sortTier(unstarted);
  return [...finished, ...live, ...unstarted];
}

/// The game in play first, then finished games newest first, then the
/// unplayed shells in game order. [chronological] is game 1 first.
List<T> _displayOrder<T>(List<_Entry<T>> chronological) {
  final live = <T>[];
  final finished = <T>[];
  final unstarted = <T>[];
  for (final entry in chronological) {
    if (entry.facts.isFinished) {
      finished.add(entry.game);
    } else if (entry.facts.hasMoves) {
      live.add(entry.game);
    } else {
      unstarted.add(entry.game);
    }
  }
  return [...live.reversed, ...finished.reversed, ...unstarted];
}

int _compareMatches<T>(MatchPlayMatch<T> a, MatchPlayMatch<T> b) {
  final byState = a.state.index.compareTo(b.state.index);
  if (byState != 0) return byState;
  if (a.state == MatchPlayState.played) {
    final aTime = a.lastActivity;
    final bTime = b.lastActivity;
    if (aTime != null && bTime != null) {
      final byTime = bTime.compareTo(aTime);
      if (byTime != 0) return byTime;
    } else if (aTime != null) {
      return -1;
    } else if (bTime != null) {
      return 1;
    }
  }
  final byBracket = a.bracketBoard.compareTo(b.bracketBoard);
  return byBracket != 0 ? byBracket : a.key.compareTo(b.key);
}

const int _noBoard = 0x7fffffff;

int _compareBoardThenId(MatchPlayGameFacts a, MatchPlayGameFacts b) {
  final byBoard = (a.boardNumber ?? _noBoard).compareTo(
    b.boardNumber ?? _noBoard,
  );
  return byBoard != 0 ? byBoard : a.id.compareTo(b.id);
}

class _Entry<T> {
  _Entry({required this.game, required this.facts})
    : index = matchPlayGameIndexFromPgn(facts.pgn);

  final T game;
  final MatchPlayGameFacts facts;
  final ({int set, int game})? index;
}

/// Player identity: the FIDE id, borrowed by name from another board of the
/// same round when this board has none, else the normalized name.
class _Identities {
  _Identities(Iterable<MatchPlayGameFacts> games) {
    final fideIdsByName = <String, Set<int>>{};
    for (final game in games) {
      for (final (name, fideId) in [
        (game.whiteName, game.whiteFideId),
        (game.blackName, game.blackFideId),
      ]) {
        final normalized = _normalizedPlayerName(name);
        if (normalized.isEmpty || fideId == null || fideId <= 0) continue;
        fideIdsByName.putIfAbsent(normalized, () => <int>{}).add(fideId);
      }
    }
    for (final entry in fideIdsByName.entries) {
      if (entry.value.length == 1) {
        _fideIdByName[entry.key] = entry.value.single;
      }
    }
  }

  final Map<String, int> _fideIdByName = <String, int>{};

  String? idFor(String name, int? fideId) {
    final normalized = _normalizedPlayerName(name);
    if (_isPlaceholderPlayerName(normalized)) return null;
    final resolved =
        (fideId != null && fideId > 0) ? fideId : _fideIdByName[normalized];
    return resolved == null ? 'name:$normalized' : 'fide:$resolved';
  }

  /// Unordered pair key, or null when a side has no identity or both sides
  /// are the same player.
  String? pairKey(MatchPlayGameFacts game) {
    final white = idFor(game.whiteName, game.whiteFideId);
    final black = idFor(game.blackName, game.blackFideId);
    if (white == null || black == null || white == black) return null;
    return white.compareTo(black) < 0 ? '$white|$black' : '$black|$white';
  }
}

bool _isPlaceholderPlayerName(String name) {
  final normalized =
      name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9?]+'), ' ').trim();
  return normalized.isEmpty ||
      normalized == '?' ||
      normalized == '??' ||
      normalized == 'tbd' ||
      normalized == 'tba' ||
      normalized == 'unknown' ||
      normalized == 'unknown player' ||
      normalized == 'to be determined' ||
      normalized.startsWith('winner of ') ||
      normalized.startsWith('loser of ');
}

String _normalizedPlayerName(String name) =>
    name
        .trim()
        .replaceFirst(
          RegExp(
            r'^(?:(?:GM|IM|FM|CM|WGM|WIM|WFM|WCM|NM|WNM)\.?\s+)+',
            caseSensitive: false,
          ),
          '',
        )
        .toLowerCase()
        .replaceAll('’', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

/// What focus-follow remembers about the game the board is showing.
@immutable
class MatchPlayFollowState {
  const MatchPlayFollowState({
    required this.focusedGameId,
    required this.startedLaterGameIds,
    required this.suppressed,
  });

  final String focusedGameId;

  /// Later games of the focused game's match already seen with a move.
  final Set<String> startedLaterGameIds;

  /// The reader opened this game while a later game of its match had already
  /// started: they chose the older game on purpose, so never move them.
  final bool suppressed;
}

@immutable
class MatchPlayFollowDecision {
  const MatchPlayFollowDecision({required this.state, this.followGameId});

  /// What to remember for the next observation; null when the focused game is
  /// not in a match-play match.
  final MatchPlayFollowState? state;

  /// The game to move the board to, once, now.
  final String? followGameId;
}

/// Focus-follow for match play, as a pure decision over two observations.
///
/// When the focused game is finished and a LATER game of the same match gets
/// its first move while the reader is watching, move the board to that game.
/// Exactly once per transition, and never:
///  - on the first observation of a focused game (opening a historical game
///    shows it, it does not jump);
///  - when the reader opened this game after a later one had already started;
///  - while the reader is analysing on the board (the start is consumed, so
///    finishing the analysis does not jump either).
/// A start seen before the focused game's own result has landed waits for it.
///
/// [matchGames] is the focused game's match, game 1 first; null when the
/// focused game is not in a match-play round. [isUserAnalysing] is asked only
/// when a later game has just started (it can be costly to answer).
MatchPlayFollowDecision decideMatchPlayFocusFollow({
  required MatchPlayFollowState? previous,
  required String? focusedGameId,
  required List<MatchPlayGameFacts>? matchGames,
  required bool Function() isUserAnalysing,
}) {
  final focusId = focusedGameId?.trim() ?? '';
  if (focusId.isEmpty || matchGames == null) {
    return const MatchPlayFollowDecision(state: null);
  }
  final focusIndex = matchGames.indexWhere((game) => game.id == focusId);
  if (focusIndex < 0) return const MatchPlayFollowDecision(state: null);
  final focused = matchGames[focusIndex];
  final later = matchGames.sublist(focusIndex + 1);
  final startedLater = <String>{
    for (final game in later)
      if (game.hasMoves || game.isFinished) game.id,
  };

  if (previous == null || previous.focusedGameId != focusId) {
    return MatchPlayFollowDecision(
      state: MatchPlayFollowState(
        focusedGameId: focusId,
        startedLaterGameIds: startedLater,
        suppressed: startedLater.isNotEmpty,
      ),
    );
  }

  final newlyStarted = startedLater.difference(previous.startedLaterGameIds);
  if (newlyStarted.isEmpty) return MatchPlayFollowDecision(state: previous);

  final consumed = MatchPlayFollowState(
    focusedGameId: focusId,
    startedLaterGameIds: {...previous.startedLaterGameIds, ...startedLater},
    suppressed: previous.suppressed,
  );
  if (previous.suppressed) return MatchPlayFollowDecision(state: consumed);
  // The next game's first move can arrive before this game's result.
  if (!focused.isFinished) return MatchPlayFollowDecision(state: previous);
  if (isUserAnalysing()) return MatchPlayFollowDecision(state: consumed);

  MatchPlayGameFacts? target;
  for (final game in later.reversed) {
    if (!newlyStarted.contains(game.id)) continue;
    if (game.isLive) {
      target = game;
      break;
    }
    target ??= game;
  }
  return MatchPlayFollowDecision(state: consumed, followGameId: target?.id);
}
