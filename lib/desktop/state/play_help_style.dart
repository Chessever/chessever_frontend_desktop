import 'dart:async';
import 'dart:convert';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/services/play/play_help_rating.dart';
import 'package:chessever/desktop/state/play_help_modules.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/desktop/state/play_settings_cloud.dart';

const _storageKey = 'desktop.play.helpStyle.v1';
const _updatedAtKey = 'desktop.play.helpStyle.v1.updatedAt';

/// How the chosen help reaches the player, like a game's difficulty: on
/// the whole time, only while asked for, or a few hints a game.
enum PlayHelpLevel {
  /// The chosen help shows the whole game.
  always('Always on', 'Always'),

  /// The chosen help shows only while the peek control is held, for the
  /// position on the board.
  peek('Hold to peek', 'Peek'),

  /// A few hints a game; each shows the chosen help until the next move.
  hints('Hints', 'Hints');

  const PlayHelpLevel(this.label, this.shortLabel);

  final String label;

  /// For a segmented control in a narrow panel.
  final String shortLabel;
}

/// Hints a game the player can choose between.
const List<int> kPlayHintAllowances = [1, 3, 5];

@immutable
class PlayHelpStyle {
  const PlayHelpStyle({this.level = PlayHelpLevel.always, this.hints = 3});

  final PlayHelpLevel level;

  /// Hints a game, for [PlayHelpLevel.hints].
  final int hints;

  PlayHelpStyle copyWith({PlayHelpLevel? level, int? hints}) =>
      PlayHelpStyle(level: level ?? this.level, hints: hints ?? this.hints);

  Map<String, Object> toJson() => {'level': level.name, 'hints': hints};

  factory PlayHelpStyle.fromJson(Map<String, Object?> json) {
    final hints = json['hints'];
    return PlayHelpStyle(
      level:
          PlayHelpLevel.values.asNameMap()[json['level']] ??
          PlayHelpLevel.always,
      hints: hints is int && kPlayHintAllowances.contains(hints) ? hints : 3,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlayHelpStyle && other.level == level && other.hints == hints;

  @override
  int get hashCode => Object.hash(level, hints);
}

final playHelpStyleProvider =
    NotifierProvider<PlayHelpStyleNotifier, PlayHelpStyle>(
      PlayHelpStyleNotifier.new,
    );

/// The player's help style, saved on this device beside their modules and
/// on the player's profile row ([PlaySettingsCloudSync]), so it follows them
/// to other devices and apps.
class PlayHelpStyleNotifier extends Notifier<PlayHelpStyle> {
  bool _edited = false;
  bool _disposed = false;
  Future<void> _writes = Future<void>.value();
  final Completer<void> _restored = Completer<void>();
  DateTime? _updatedAt;

  /// When the style was last changed here or taken from the server; null
  /// when it never was.
  DateTime? get updatedAt => _updatedAt;

  /// The chosen style (the state itself).
  PlayHelpStyle get chosen => state;

  /// Completes once the saved style was read.
  Future<void> get restored => _restored.future;

  @override
  PlayHelpStyle build() {
    ref.onDispose(() => _disposed = true);
    unawaited(_restore());
    return const PlayHelpStyle();
  }

  Future<void> _restore() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_storageKey);
      final at = parsePlaySettingsTime(preferences.getString(_updatedAtKey));
      if (_disposed || _edited) return;
      _updatedAt = at;
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        state = PlayHelpStyle.fromJson(decoded);
      }
    } catch (error) {
      debugPrint('Play help style could not be restored: $error');
    } finally {
      if (!_restored.isCompleted) _restored.complete();
      if (!_disposed) ref.read(playSettingsCloudProvider).start();
    }
  }

  void set(PlayHelpStyle value) {
    _edited = true;
    if (value == state) return;
    state = value;
    _updatedAt = DateTime.now().toUtc();
    _save(value, _updatedAt);
    ref.read(playSettingsCloudProvider).localChanged();
  }

  /// Takes the style saved on the server at [at]. Skipped (returns false)
  /// when the style changed here since the sync read [expectedLocalAt]: the
  /// newer local change goes up on the next pass instead.
  bool adoptRemote(
    PlayHelpStyle value,
    DateTime? at, {
    required DateTime? expectedLocalAt,
  }) {
    if (_disposed || _updatedAt != expectedLocalAt) return false;
    _edited = true;
    _updatedAt = at;
    if (value != state) state = value;
    _save(value, at);
    return true;
  }

  void _save(PlayHelpStyle value, DateTime? at) {
    final json = jsonEncode(value.toJson());
    final stamp = at?.toUtc().toIso8601String();
    _writes = _writes
        .then((_) async {
          final preferences = await SharedPreferences.getInstance();
          await preferences.setString(_storageKey, json);
          if (stamp == null) {
            await preferences.remove(_updatedAtKey);
          } else {
            await preferences.setString(_updatedAtKey, stamp);
          }
        })
        .catchError((Object error) {
          debugPrint('Play help style could not be saved: $error');
        });
  }
}

/// Whether the Play game in each tab is shown at its live position. While
/// the player steps back through the moves, the Peek and Hints styles show
/// no help: a peek or a hint is paid for the live position only. The game
/// view keeps this in step with its review.
final playHelpAtLiveTipProvider = StateProvider.family<bool, String>(
  (ref, tabId) => true,
);

// ---------------------------------------------------------------------------
// Help used in one game
// ---------------------------------------------------------------------------

/// What a peek or a hint reveals: one module of the chosen help, or all of
/// it (`null`).
typedef PlayHelpTarget = PlayHelpModule?;

/// [targets] as modules: an all-help target is every module.
Set<PlayHelpModule> playHelpModulesFor(Set<PlayHelpTarget> targets) =>
    targets.contains(null)
        ? PlayHelpModule.values.toSet()
        : {for (final target in targets) target!};

/// The help one game in one Play tab has used, and what of the chosen help
/// is on screen right now. Starts empty with every new game in the tab.
@immutable
class PlayHelpUsage {
  const PlayHelpUsage({
    this.level = PlayHelpLevel.always,
    this.allowance = 3,
    this.peeks = 0,
    this.hints = 0,
    this.humanMoves = 0,
    this.helpedMoves = 0,
    this.threatMoves = 0,
    this.held = const {},
    this.revealedPly,
    this.hinted = const {},
    this.lastPeekPly,
  });

  /// The style the game started with. Changing the style mid-game applies
  /// from the next game, so a game cannot switch to Always on for one move
  /// and back.
  final PlayHelpLevel level;

  /// Hints this game started with, for [PlayHelpLevel.hints].
  final int allowance;

  /// Positions the player peeked at (several peeks at one position, at any
  /// module, count once).
  final int peeks;

  /// Hints spent. One hint reveals one target (a module or all help) until
  /// the next move.
  final int hints;

  /// The player's moves this game.
  final int humanMoves;

  /// The player's moves made while help was on screen.
  final int helpedMoves;

  /// The player's moves made while the opponent's threat was shown (and no
  /// other help was).
  final int threatMoves;

  /// The peek targets held down now (keys, the trigger, the help shelf).
  final Set<PlayHelpTarget> held;

  /// The ply hints were spent on; [hinted] shows while the game is there.
  final int? revealedPly;

  /// What the hints spent at [revealedPly] reveal.
  final Set<PlayHelpTarget> hinted;

  /// The last ply a peek was counted at.
  final int? lastPeekPly;

  int get hintsLeft => (allowance - hints).clamp(0, allowance);

  /// A peek is held.
  bool get peeking => held.isNotEmpty;

  bool get usedAny =>
      peeks > 0 || hints > 0 || helpedMoves > 0 || threatMoves > 0;

  /// The modules shown for the game at [ply] (all of them in Always on).
  Set<PlayHelpModule> revealedModulesAt(int ply) => switch (level) {
    PlayHelpLevel.always => PlayHelpModule.values.toSet(),
    PlayHelpLevel.peek => playHelpModulesFor(held),
    PlayHelpLevel.hints =>
      revealedPly == ply ? playHelpModulesFor(hinted) : const {},
  };

  /// Whether some of the chosen help shows for the game at [ply].
  bool revealedAt(int ply) => revealedModulesAt(ply).isNotEmpty;

  PlayHelpUsage copyWith({
    int? peeks,
    int? hints,
    int? humanMoves,
    int? helpedMoves,
    int? threatMoves,
    Set<PlayHelpTarget>? held,
    int? Function()? revealedPly,
    Set<PlayHelpTarget>? hinted,
    int? Function()? lastPeekPly,
  }) => PlayHelpUsage(
    level: level,
    allowance: allowance,
    peeks: peeks ?? this.peeks,
    hints: hints ?? this.hints,
    humanMoves: humanMoves ?? this.humanMoves,
    helpedMoves: helpedMoves ?? this.helpedMoves,
    threatMoves: threatMoves ?? this.threatMoves,
    held: held ?? this.held,
    revealedPly: revealedPly == null ? this.revealedPly : revealedPly(),
    hinted: hinted ?? this.hinted,
    lastPeekPly: lastPeekPly == null ? this.lastPeekPly : lastPeekPly(),
  );

  /// Written into the game record (`metadata.help`), so the rating the save
  /// applies reads the same help the game used.
  Map<String, Object> toJson() => {
    'level': level.name,
    'allowance': allowance,
    'peeks': peeks,
    'hints': hints,
    'humanMoves': humanMoves,
    'helpedMoves': helpedMoves,
    'threatMoves': threatMoves,
    'gainFactor': playHelpGainFactor(this),
  };

  @override
  bool operator ==(Object other) =>
      other is PlayHelpUsage &&
      other.level == level &&
      other.allowance == allowance &&
      other.peeks == peeks &&
      other.hints == hints &&
      other.humanMoves == humanMoves &&
      other.helpedMoves == helpedMoves &&
      other.threatMoves == threatMoves &&
      setEquals(other.held, held) &&
      other.revealedPly == revealedPly &&
      setEquals(other.hinted, hinted) &&
      other.lastPeekPly == lastPeekPly;

  @override
  int get hashCode => Object.hash(
    level,
    allowance,
    peeks,
    hints,
    humanMoves,
    helpedMoves,
    threatMoves,
    Object.hashAllUnordered(held),
    revealedPly,
    Object.hashAllUnordered(hinted),
    lastPeekPly,
  );
}

/// How much of a rating gain a game keeps for the help it used. A win (or a
/// draw that gains) with no help keeps all of it; losses are never softened.
///
/// - Help on screen for every move: a quarter. For some of the moves, in
///   proportion.
/// - The threat shown for a move counts about a third of that (0.35).
/// - Each position peeked at: 8% less. Each hint: 10% less.
///
/// Never below [kPlayHelpMinGainFactor].
double playHelpGainFactor(PlayHelpUsage usage) {
  var factor = 1.0;
  if (usage.humanMoves > 0) {
    final weighted = usage.helpedMoves + usage.threatMoves * 0.35;
    factor -= 0.75 * (weighted / usage.humanMoves).clamp(0.0, 1.0);
  }
  factor -= 0.08 * usage.peeks + 0.10 * usage.hints;
  final rounded = (factor * 100).round() / 100;
  return rounded.clamp(kPlayHelpMinGainFactor, 1.0);
}

final playHelpUsageProvider =
    StateNotifierProvider.family<PlayHelpUsageNotifier, PlayHelpUsage, String>(
      (ref, tabId) => PlayHelpUsageNotifier(ref, tabId),
    );

class PlayHelpUsageNotifier extends StateNotifier<PlayHelpUsage> {
  PlayHelpUsageNotifier(this._ref, this._tabId) : super(_fresh(_ref)) {
    // A new game in the tab starts a new count, in the style chosen then.
    _ref.listen<PlaySessionArgs?>(
      playSessionArgsByTabIdProvider.select((m) => m[_tabId]),
      (previous, next) {
        if (!identical(previous, next)) state = _fresh(_ref);
      },
    );
    _ref.listen<int>(
      playSessionProviderFor(_tabId).select((s) => s.history.length),
      _onPly,
    );
    // The saved style loads after start-up: until the first move the game
    // takes the style as it is now, so a game started before it loaded (or
    // a style picked before moving) is played in the chosen style.
    _ref.listen<PlayHelpStyle>(playHelpStyleProvider, (_, style) {
      if (state.humanMoves > 0 || state.peeks > 0 || state.hints > 0) return;
      state = PlayHelpUsage(level: style.level, allowance: style.hints);
    });
  }

  final Ref _ref;
  final String _tabId;

  static PlayHelpUsage _fresh(Ref ref) {
    final style = ref.read(playHelpStyleProvider);
    return PlayHelpUsage(level: style.level, allowance: style.hints);
  }

  PlaySessionState get _session => _ref.read(playSessionProviderFor(_tabId));

  PlayHelpModules get _chosen => _ref.read(playHelpModulesProvider);

  bool get _helpChosen => _chosen.anyOn;

  /// Whether [target] has something to show: a module the player switched
  /// on, or (all help) any of them. Anything else does nothing and costs
  /// nothing.
  bool _available(PlayHelpTarget target) {
    final chosen = _chosen;
    return target == null ? chosen.anyOn : target.chosenIn(chosen);
  }

  /// Whether [revealed] already shows all [target] has to show.
  bool _covers(Set<PlayHelpTarget> revealed, PlayHelpTarget target) {
    if (revealed.contains(null)) return true;
    if (target != null) return revealed.contains(target);
    final shown = playHelpModulesFor(revealed);
    return _chosen.chosenModules.every(shown.contains);
  }

  void _onPly(int? previous, int next) {
    // One move at a time; a new game's replayed opening is not played here.
    if (previous == null || next != previous + 1) return;
    // A peek held through a move shows a new position: that is a new peek.
    if (state.peeking && state.lastPeekPly != next) {
      state = state.copyWith(peeks: state.peeks + 1, lastPeekPly: () => next);
    }
    final session = _session;
    final index = next - 1;
    final firstMover =
        session.startingFen.split(' ').elementAtOrNull(1) == 'b'
            ? Side.black
            : Side.white;
    final mover = index.isEven ? firstMover : firstMover.opposite;
    if (mover != session.humanSide) return;
    // The position the move was played from was ply `index`.
    final helped = _helpChosen && state.revealedAt(index);
    final threat = !helped && _ref.read(playThreatShownProvider(_tabId));
    state = state.copyWith(
      humanMoves: state.humanMoves + 1,
      helpedMoves:
          state.level == PlayHelpLevel.always && helped
              ? state.helpedMoves + 1
              : null,
      threatMoves: threat ? state.threatMoves + 1 : null,
    );
  }

  int get _ply => _session.history.length;

  /// Whether the board shows the live position (not a reviewed one).
  bool get _atLiveTip => _ref.read(playHelpAtLiveTipProvider(_tabId));

  /// A peek control for [target] went down: it shows until [endPeekOf]
  /// (or [endPeek]). The first peek at a position counts, at any module;
  /// peeking again there, at anything, is free. Returns whether it peeked.
  bool beginPeek([PlayHelpTarget target]) {
    if (state.level != PlayHelpLevel.peek || _session.isGameOver) return false;
    if (!_available(target) || !_atLiveTip) return false;
    final ply = _ply;
    final counted = state.lastPeekPly == ply;
    state = state.copyWith(
      held: {...state.held, target},
      peeks: counted ? null : state.peeks + 1,
      lastPeekPly: () => ply,
    );
    return true;
  }

  /// The peek control for [target] came up.
  void endPeekOf(PlayHelpTarget target) {
    if (!mounted || !state.held.contains(target)) return;
    state = state.copyWith(held: {...state.held}..remove(target));
  }

  /// Ends every peek (the board lost focus, a control went away).
  void endPeek() {
    if (!mounted || !state.peeking) return;
    state = state.copyWith(held: const {});
  }

  /// Spends a hint on [target] (a module, or all help) for the position on
  /// the board: it shows until the next move. Only on the player's turn
  /// (one spent while the bot thinks would be gone with its move). A second
  /// target at the same position costs another hint; asking again for
  /// something already shown is free. Returns whether a hint was spent.
  bool useHint([PlayHelpTarget target]) {
    final session = _session;
    if (state.level != PlayHelpLevel.hints ||
        session.isGameOver ||
        !session.isHumanToMove ||
        !_available(target) ||
        !_atLiveTip) {
      return false;
    }
    final ply = _ply;
    final current =
        state.revealedPly == ply ? state.hinted : const <PlayHelpTarget>{};
    if (current.isNotEmpty && _covers(current, target)) return false;
    if (state.hintsLeft <= 0) return false;
    state = state.copyWith(
      hints: state.hints + 1,
      revealedPly: () => ply,
      hinted: {...current, target},
    );
    return true;
  }
}

/// The help modules revealed in [tabId] now: all of them in the Always on
/// style, the ones peeked at, or the ones a hint was spent on for the
/// live position (none while an earlier move is reviewed). After the game
/// every help shows: the game is over.
final playHelpRevealedModulesProvider =
    Provider.family<Set<PlayHelpModule>, String>((ref, tabId) {
      const all = PlayHelpModule.values;
      final hasGame = ref.watch(
        playSessionArgsByTabIdProvider.select((m) => m.containsKey(tabId)),
      );
      if (!hasGame) return all.toSet();
      final usage = ref.watch(playHelpUsageProvider(tabId));
      if (usage.level == PlayHelpLevel.always) return all.toSet();
      final session = ref.watch(
        playSessionProviderFor(
          tabId,
        ).select((s) => (over: s.isGameOver, ply: s.history.length)),
      );
      if (session.over) return all.toSet();
      // A position stepped back to shows no help: what was paid for is the
      // live position.
      if (!ref.watch(playHelpAtLiveTipProvider(tabId))) return const {};
      return usage.revealedModulesAt(session.ply);
    });

/// Whether any of the chosen help is on screen in [tabId] now.
final playHelpRevealedProvider = Provider.family<bool, String>(
  (ref, tabId) => ref.watch(playHelpRevealedModulesProvider(tabId)).isNotEmpty,
);

/// The help modules on screen in [tabId]: the chosen ones that are
/// revealed, none while they are all held back. Layout (the rail, the
/// bars' room) still follows the chosen modules, so peeking never moves
/// the board.
final playHelpShownProvider = Provider.family<PlayHelpModules, String>((
  ref,
  tabId,
) {
  final chosen = ref.watch(playHelpModulesProvider);
  if (!chosen.anyOn) return chosen;
  final revealed = ref.watch(playHelpRevealedModulesProvider(tabId));
  if (revealed.isEmpty) return const PlayHelpModules();
  return chosen.onlyRevealed(revealed);
});
