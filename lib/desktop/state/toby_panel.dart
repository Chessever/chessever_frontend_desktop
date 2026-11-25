/// What the "What Toby Thinks" tab remembers: whether the reader chose it
/// over Stockfish in the engine pane's header, and, for one board, the
/// what-if choices, the hovered and pinned candidates, and the single arrow
/// that puts on the board.
library;

import 'dart:async';

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart' show Move, NormalMove;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/services/toby/toby_prediction.dart';

/// The one tonal hue of Toby's view: its chances and its rows' fills.
const Color kTobyAccent = Color(0xFF83C7C4);

/// Toby's arrow on the board: a deeper value of [kTobyAccent]'s hue, so it
/// reads on light and dark squares alike. The board keeps its own colours
/// whatever the site theme, so this holds on both.
final Color kTobyArrowColor = const Color(0xFF1E7F79).withValues(alpha: 0.9);

/// Where the chosen tab is kept. A new key, not the old open/closed panel's
/// (`desktop.board.toby.open.v1`): a reader who left that panel open asked to
/// see Toby beside Stockfish, not instead of it, so everyone starts on the
/// Stockfish tab.
@visibleForTesting
const String tobyTabStorageKey = 'desktop.engine.tobyTab.v1';

/// Whether the reader left the engine pane on the What Toby Thinks tab
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

/// Whether the engine pane shows the What Toby Thinks tab. Everyone may
/// choose it, guests included: Gamebase decides who may read Toby, and a
/// refusal shows as a notice in the view, never as a gate on the tab.
final tobyTabSelectedProvider = Provider<bool>(
  (ref) => ref.watch(tobyTabPreferenceProvider),
);

/// The arrow Toby puts on the board, for one position.
///
/// [exclusive] arrows (a hovered or keyboard-focused candidate) are the only
/// shape on the board. A pinned arrow replaces the engine arrows only; the
/// reader's own drawings and the game's arrows stay. While the Toby tab is
/// shown the engine arrows are off anyway ([TobyPanelController.holdsBoard]),
/// so a pin adds Toby's arrow to the reader's shapes and the game's.
typedef TobyBoardArrow = ({String positionKey, cg.Arrow arrow, bool exclusive});

/// The reader's what-if choices: read the position as if both players were
/// rated [rating], or at [cadence]. Null means the game's own value.
typedef TobyWhatIf = ({int? rating, TobyCadence? cadence});

typedef _Mark = ({String positionKey, String uci});

/// The arrow for a candidate [uci], or null when it cannot be drawn.
cg.Arrow? tobyArrowFor(String uci) {
  final move = Move.parse(uci);
  if (move is! NormalMove || move.from == move.to) return null;
  return cg.Arrow(
    color: kTobyArrowColor,
    orig: move.from,
    dest: move.to,
    scale: 0.8,
  );
}

/// Per-board state of the Toby view, owned by the board pane so it outlives
/// the view (which mounts only while its tab is shown, and moves when the
/// report opens) and is shared with the board.
///
/// The view writes hover and pin; the board only listens to [boardArrow]
/// and [holdsBoard].
/// Everything here is keyed by UCI, never by row, so a reading that re-sorts
/// under a still pointer keeps the same move highlighted.
class TobyPanelController extends ChangeNotifier {
  TobyPanelController({String? session})
    : session = session ?? newTobySession();

  /// The view's id towards Gamebase, one per board for its lifetime.
  final String session;

  final ValueNotifier<TobyBoardArrow?> _boardArrow =
      ValueNotifier<TobyBoardArrow?>(null);
  final ValueNotifier<bool> _holdsBoard = ValueNotifier<bool>(false);
  bool _wantsHold = false;
  _Mark? _hover;
  _Mark? _pin;
  TobyWhatIf _whatIf = (rating: null, cadence: null);
  bool _disposed = false;

  /// The one arrow to draw, if any. Only the board listens to it.
  ValueListenable<TobyBoardArrow?> get boardArrow => _boardArrow;

  /// Whether the Toby tab is on screen in place of Stockfish's lines. The
  /// engine keeps analysing (its score stays in the header), but its arrows
  /// leave the board: they would point at lines the reader cannot see.
  ValueListenable<bool> get holdsBoard => _holdsBoard;

  /// Set by the Toby view as it mounts and leaves. Notifies after the
  /// current frame, because the view learns it while widgets are building.
  void holdBoardSoon(bool hold) {
    if (_disposed || _wantsHold == hold) return;
    _wantsHold = hold;
    scheduleMicrotask(() {
      if (!_disposed) _holdsBoard.value = _wantsHold;
    });
  }

  TobyWhatIf get whatIf => _whatIf;

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
    notifyListeners();
  }

  /// Shows [uci] alone on the board while the pointer (or keyboard focus)
  /// rests on it; null clears it.
  void hover(String positionKey, String? uci) {
    final next = uci == null ? null : (positionKey: positionKey, uci: uci);
    if (_disposed || next == _hover) return;
    _hover = next;
    _changed();
  }

  void clearHover() {
    if (_disposed || _hover == null) return;
    _hover = null;
    _changed();
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
    _boardArrow.value = _arrowFor();
    notifyListeners();
  }

  TobyBoardArrow? _arrowFor() {
    final hover = _hover;
    if (hover != null) {
      final arrow = tobyArrowFor(hover.uci);
      if (arrow != null) {
        return (positionKey: hover.positionKey, arrow: arrow, exclusive: true);
      }
    }
    final pin = _pin;
    if (pin == null) return null;
    final arrow = tobyArrowFor(pin.uci);
    return arrow == null
        ? null
        : (positionKey: pin.positionKey, arrow: arrow, exclusive: false);
  }

  @override
  void dispose() {
    _disposed = true;
    _boardArrow.dispose();
    _holdsBoard.dispose();
    super.dispose();
  }
}
