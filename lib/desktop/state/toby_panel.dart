/// What the "Toby Predicts" tab remembers: whether the reader chose it
/// over Stockfish in the engine pane's header, and, for one board, the
/// what-if choices, the hovered and pinned candidates, the reading on show,
/// and the arrows those put on the board.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart' show Move, NormalMove, Square;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart'
    show GameMoveClassification;
import 'package:chessever/desktop/services/toby/toby_classes.dart';
import 'package:chessever/desktop/services/toby/toby_prediction.dart';

/// The one tonal hue of Toby's view: its chances and its rows' fills, for a
/// move without a class.
const Color kTobyAccent = Color(0xFF83C7C4);

/// Toby's arrow on the board for a move without a class, at full weight: a
/// deeper value of [kTobyAccent]'s hue, so it reads on light and dark
/// squares alike. The board keeps its own colours whatever the site theme,
/// so this holds on both. Classed moves take their class's colour
/// ([tobyArrowHue]).
final Color kTobyArrowColor = kTobyArrowNeutral.withValues(
  alpha: kTobyArrowAlpha,
);

/// The most likely candidate's arrow: its width and opacity.
const double kTobyArrowScale = 0.8;
const double kTobyArrowAlpha = 0.9;

/// Less likely candidates draw thinner and fainter, by their chance
/// against the most likely one's, never below these.
const double kTobyArrowMinScale = 0.45;
const double kTobyArrowMinAlpha = 0.55;

/// How many of Toby's candidates the board shows while the tab is on show.
const int kTobyBoardArrowCount = 3;

/// Where the chosen tab is kept. A new key, not the old open/closed panel's
/// (`desktop.board.toby.open.v1`): a reader who left that panel open asked to
/// see Toby beside Stockfish, not instead of it, so everyone starts on the
/// Stockfish tab.
@visibleForTesting
const String tobyTabStorageKey = 'desktop.engine.tobyTab.v1';

/// Whether the reader left the engine pane on the Toby Predicts tab
/// (rather than on Stockfish). Device-local, like the split sizes around it
/// (`SharedPreferences`; localStorage in the browser, read once the page has
/// hydrated).
class TobyTabPreference extends Notifier<bool> {
  bool _chosen = false;
  bool _disposed = false;
  Future<void> _writes = Future<void>.value();

  @override
  bool build() {
    ref.onDispose(() => _disposed = true);
    unawaited(_restore());
    return false;
  }

  Future<void> _restore() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = preferences.getBool(tobyTabStorageKey);
      if (_disposed || _chosen || saved == null) return;
      state = saved;
    } catch (error) {
      debugPrint('Toby tab preference restore failed: $error');
    }
  }

  /// Records an explicit choice of tab. Writes are serialised so a slower
  /// write cannot overwrite a later choice.
  void choose(bool toby) {
    _chosen = true;
    if (state != toby) state = toby;
    final write = _writes.then((_) async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(tobyTabStorageKey, toby);
    });
    _writes = write.catchError((Object error) {
      debugPrint('Toby tab preference write failed: $error');
    });
  }
}

final tobyTabPreferenceProvider = NotifierProvider<TobyTabPreference, bool>(
  TobyTabPreference.new,
);

/// Whether the engine pane shows the Toby Predicts tab. Everyone may
/// choose it, guests included: Gamebase decides who may read Toby, and a
/// refusal shows as a notice in the view, never as a gate on the tab.
final tobyTabSelectedProvider = Provider<bool>(
  (ref) => ref.watch(tobyTabPreferenceProvider),
);

/// The arrows Toby puts on the board, for one position, in drawing order
/// (the last sits on top).
///
/// [exclusive] arrows (a hovered or keyboard-focused candidate) are the only
/// shape on the board. Otherwise (Toby's top three, or a pinned candidate in
/// their place) they replace the engine arrows only; the reader's own
/// drawings and the game's arrows stay. While the Toby tab is shown the
/// engine arrows are off anyway ([TobyPanelController.holdsBoard]).
///
/// [mark] is the report's class mark for a hovered or pinned candidate that
/// has one, drawn on its destination square as the board draws a report
/// move's mark. Toby's top three carry their class in colour only.
typedef TobyBoardArrows =
    ({
      String positionKey,
      List<cg.Arrow> arrows,
      bool exclusive,
      TobyBoardMark? mark,
    });

/// A class mark on the board: the report's badge for [classification] on
/// [square].
typedef TobyBoardMark =
    ({Square square, GameMoveClassification classification});

/// The reader's what-if choices: read the position as if both players were
/// rated [rating], or at [cadence]. Null means the game's own value.
typedef TobyWhatIf = ({int? rating, TobyCadence? cadence});

typedef _Mark = ({String positionKey, String uci});

typedef _Shown =
    ({
      String positionKey,
      TobyReading reading,
      Map<String, GameMoveClassification?> classes,
    });

/// The arrow for a candidate [uci] in [hue], or null when it cannot be
/// drawn. [weight] is the candidate's chance against the most likely one's
/// (1 for the most likely, a hovered or a pinned move): it scales the width
/// and opacity down from [kTobyArrowScale] and [kTobyArrowAlpha], never
/// below [kTobyArrowMinScale] and [kTobyArrowMinAlpha].
cg.Arrow? tobyArrowFor(
  String uci, {
  Color hue = kTobyArrowNeutral,
  double weight = 1,
}) {
  final move = Move.parse(uci);
  if (move is! NormalMove || move.from == move.to) return null;
  final double share =
      weight.isFinite ? weight.clamp(0.0, 1.0).toDouble() : 1.0;
  return cg.Arrow(
    color: hue.withValues(
      alpha: math.max(kTobyArrowMinAlpha, kTobyArrowAlpha * share),
    ),
    orig: move.from,
    dest: move.to,
    scale: math.max(kTobyArrowMinScale, kTobyArrowScale * share),
  );
}

/// Toby's top [kTobyBoardArrowCount] candidates in [reading] as arrows,
/// least likely first so the most likely is drawn on top, each in its
/// class's colour ([classes], by UCI; Toby's teal without one) and weighted
/// by its chance against the most likely one's.
List<cg.Arrow> tobyTopArrows(
  TobyReading reading, {
  Map<String, GameMoveClassification?> classes =
      const <String, GameMoveClassification?>{},
}) {
  final top = reading.candidates.take(kTobyBoardArrowCount).toList();
  if (top.isEmpty) return const <cg.Arrow>[];
  final leader = top
      .map((candidate) => candidate.probability)
      .fold<double>(0, math.max);
  final arrows = <cg.Arrow>[];
  for (final candidate in top.reversed) {
    final arrow = tobyArrowFor(
      candidate.uci,
      hue: tobyArrowHue(classes[candidate.uci]),
      weight: leader > 0 ? candidate.probability / leader : 1,
    );
    if (arrow != null) arrows.add(arrow);
  }
  return arrows;
}

/// Per-board state of the Toby view, owned by the board pane so it outlives
/// the view (which mounts only while its tab is shown, and moves when the
/// report opens) and is shared with the board.
///
/// The view writes hover, pin and the reading on show; the board only
/// listens to [boardArrows] and [holdsBoard], so a hover repaints the board
/// and rebuilds nothing around it.
/// Everything here is keyed by UCI, never by row, so a reading that re-sorts
/// under a still pointer keeps the same move highlighted.
class TobyPanelController extends ChangeNotifier {
  TobyPanelController({String? session})
    : session = session ?? newTobySession();

  /// The view's id towards Gamebase, one per board for its lifetime.
  final String session;

  final ValueNotifier<TobyBoardArrows?> _boardArrows =
      ValueNotifier<TobyBoardArrows?>(null);
  final ValueNotifier<bool> _holdsBoard = ValueNotifier<bool>(false);
  final ValueNotifier<TobyWhatIf> _whatIfValue = ValueNotifier<TobyWhatIf>((
    rating: null,
    cadence: null,
  ));
  Object? _viewOwner;
  bool _wantsHold = false;
  _Mark? _hover;
  bool _previewHoveredMove = true;
  _Mark? _pin;

  /// The reading the view shows, and the one it last asked to show (applied
  /// after the frame that asked).
  _Shown? _shown;
  _Shown? _wantsShown;
  TobyWhatIf _whatIf = (rating: null, cadence: null);
  bool _disposed = false;

  /// The arrows to draw, if any. Only the board listens to them.
  ValueListenable<TobyBoardArrows?> get boardArrows => _boardArrows;

  /// Whether the Toby tab is on screen in place of Stockfish's lines. The
  /// engine keeps analysing (its score stays in the header), but its arrows
  /// leave the board: they would point at lines the reader cannot see.
  ValueListenable<bool> get holdsBoard => _holdsBoard;

  void attachView(Object owner) => _viewOwner = owner;

  void detachView(Object owner) {
    scheduleMicrotask(() {
      if (_disposed || !identical(_viewOwner, owner)) return;
      _viewOwner = null;
      holdBoardSoon(false);
      showReadingSoon(null, null);
      clearMarks();
    });
  }

  /// Set by the Toby view as it mounts and leaves. Notifies after the
  /// current frame, because the view learns it while widgets are building.
  void holdBoardSoon(bool hold) {
    if (_disposed || _wantsHold == hold) return;
    _wantsHold = hold;
    scheduleMicrotask(() {
      if (!_disposed) _holdsBoard.value = _wantsHold;
    });
  }

  /// Set by the Toby view with the reading on screen for [positionKey]
  /// (null for none) and its candidates' report [classes]: while nothing is
  /// hovered or pinned, the board shows its top three candidates. Applied
  /// after the current frame, because the view learns it while widgets are
  /// building, and only the board hears it: the view itself does not
  /// rebuild. Pass the same [classes] map while it holds, so an unchanged
  /// reading is not drawn again.
  void showReadingSoon(
    String? positionKey,
    TobyReading? reading, [
    Map<String, GameMoveClassification?> classes =
        const <String, GameMoveClassification?>{},
  ]) {
    final next =
        positionKey == null || reading == null
            ? null
            : (positionKey: positionKey, reading: reading, classes: classes);
    if (_disposed || next == _wantsShown) return;
    _wantsShown = next;
    scheduleMicrotask(() {
      if (_disposed || _wantsShown == _shown) return;
      _shown = _wantsShown;
      _boardArrows.value = _arrowsFor();
    });
  }

  TobyWhatIf get whatIf => _whatIf;

  /// [whatIf] alone, for the Toby bar beside the board: it reads with the
  /// same what-if as the view, but must not rebuild on every hover or pin.
  ValueListenable<TobyWhatIf> get whatIfListenable => _whatIfValue;

  bool get hasWhatIf => _whatIf.rating != null || _whatIf.cadence != null;

  /// The candidate pinned on [positionKey], if any.
  String? pinnedUci(String positionKey) =>
      _pin?.positionKey == positionKey ? _pin!.uci : null;

  /// The candidate shown alone on [positionKey], if any.
  String? hoveredUci(String positionKey) =>
      _hover?.positionKey == positionKey ? _hover!.uci : null;

  void setWhatIf(TobyWhatIf next) {
    if (_disposed || next == _whatIf) return;
    _whatIf = next;
    _whatIfValue.value = next;
    notifyListeners();
  }

  /// Shows [uci] alone on the board while the pointer (or keyboard focus)
  /// rests on it; null clears it.
  void hover(String positionKey, String? uci, {bool previewOnBoard = true}) {
    final next = uci == null ? null : (positionKey: positionKey, uci: uci);
    if (_disposed || (next == _hover && previewOnBoard == _previewHoveredMove)) return;
    final changeBoard = (_hover != null && _previewHoveredMove) ||
        (next != null && previewOnBoard);
    _hover = next;
    _previewHoveredMove = previewOnBoard;
    if (changeBoard) {
      _changed();
    } else {
      notifyListeners();
    }
  }

  void clearHover() {
    if (_disposed || _hover == null) return;
    hover('', null, previewOnBoard: _previewHoveredMove);
  }

  /// Pins [uci], or unpins it when it is already the pin.
  void togglePin(String positionKey, String uci) {
    if (_disposed) return;
    final current = pinnedUci(positionKey);
    _pin = current == uci ? null : (positionKey: positionKey, uci: uci);
    _changed();
  }

  /// Clears the pin. Returns whether there was one.
  bool clearPin() {
    if (_disposed || _pin == null) return false;
    _pin = null;
    _changed();
    return true;
  }

  /// Clears hover and pin, after a position change or on leaving the tab.
  void clearMarks() {
    if (_disposed || (_hover == null && _pin == null)) return;
    _hover = null;
    _pin = null;
    _changed();
  }

  /// [clearMarks] after the current frame's build, for callers that learn
  /// about a change while widgets are building.
  void clearMarksSoon() => scheduleMicrotask(clearMarks);

  void _changed() {
    _boardArrows.value = _arrowsFor();
    notifyListeners();
  }

  /// A hovered or pinned candidate's class, when the reading on show is for
  /// the same position.
  GameMoveClassification? _classOf(_Mark mark) {
    final shown = _shown;
    if (shown == null || shown.positionKey != mark.positionKey) return null;
    return shown.classes[mark.uci];
  }

  /// A hovered or pinned candidate's arrow at full weight in its class's
  /// colour, and the class's mark on its destination square.
  TobyBoardArrows? _marked(_Mark mark, {required bool exclusive}) {
    final classification = _classOf(mark);
    final arrow = tobyArrowFor(mark.uci, hue: tobyArrowHue(classification));
    if (arrow == null) return null;
    return (
      positionKey: mark.positionKey,
      arrows: [arrow],
      exclusive: exclusive,
      mark:
          classification == null
              ? null
              : (square: arrow.dest, classification: classification),
    );
  }

  /// A hover is the only shape on the board; a pin stands in for the top
  /// three; otherwise the reading's top three.
  TobyBoardArrows? _arrowsFor() {
    final hover = _hover;
    if (hover != null && _previewHoveredMove) {
      final marked = _marked(hover, exclusive: true);
      if (marked != null) return marked;
    }
    final pin = _pin;
    if (pin != null) return _marked(pin, exclusive: false);
    final shown = _shown;
    if (shown == null) return null;
    final arrows = tobyTopArrows(shown.reading, classes: shown.classes);
    return arrows.isEmpty
        ? null
        : (
          positionKey: shown.positionKey,
          arrows: arrows,
          exclusive: false,
          mark: null,
        );
  }

  @override
  void dispose() {
    _disposed = true;
    _boardArrows.dispose();
    _holdsBoard.dispose();
    _whatIfValue.dispose();
    super.dispose();
  }
}

/// The one query a board asks Toby with: [request] under the [controller]'s
/// what-if, from the board's session. The Toby Predicts view and the Toby bar
/// beside the board both build it here, so they watch the same
/// [tobyReadingProvider] instance and a position is asked about once per
/// board, never once per surface.
TobyQuery tobyQueryFor(TobyRequest request, TobyPanelController controller) {
  final whatIf = controller.whatIf;
  return TobyQuery(
    request: request.copyWith(
      ratingOverride: whatIf.rating,
      cadenceOverride: whatIf.cadence,
    ),
    session: controller.session,
  );
}
