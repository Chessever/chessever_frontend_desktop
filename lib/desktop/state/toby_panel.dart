/// What the "What Toby Thinks" panel remembers: whether the reader keeps it
/// open, and, for one board, the what-if choices, the hovered and pinned
/// candidates, and the single arrow that puts on the board.
library;

import 'dart:async';

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart' show Move, NormalMove;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/services/toby/toby_access.dart';
import 'package:chessever/desktop/services/toby/toby_prediction.dart';

/// The collapsed row, which is also the expanded panel's header.
const double kTobyPanelCollapsedHeight = 32;

/// One candidate slot of the expanded panel.
const double kTobyPanelSlotHeight = 26;

/// Under the slots: the inputs row (22), the attribution (18) and the
/// bottom padding (8).
const double kTobyPanelFooterHeight = 48;

/// Candidate slots when the engine pane has room for the full panel beside
/// two Stockfish lines, and when it does not. Candidates past the last slot
/// fold into the "+N moves" count.
const int kTobyPanelSlots = 5;
const int kTobyPanelCompactSlots = 3;

/// The expanded panel with all [kTobyPanelSlots] slots.
const double kTobyPanelExpandedHeight =
    kTobyPanelCollapsedHeight +
    kTobyPanelSlots * kTobyPanelSlotHeight +
    kTobyPanelFooterHeight;

/// The panel's height: collapsed, or expanded with [slots] candidate slots.
///
/// It follows the panel's state and the room it is given, never the reading,
/// so it holds still while the reader steps through a game; it changes on
/// expand and collapse, or when the pane is resized across
/// [tobyPanelSlotsFor]'s threshold.
double tobyPanelHeight({required bool expanded, int slots = kTobyPanelSlots}) =>
    expanded
        ? kTobyPanelCollapsedHeight +
            slots * kTobyPanelSlotHeight +
            kTobyPanelFooterHeight
        : kTobyPanelCollapsedHeight;

/// How many candidate slots the expanded panel shows in [available] height,
/// once [reserved] is kept for what sits beside it (two Stockfish lines).
int tobyPanelSlotsFor(double available, {double reserved = 0}) =>
    available - reserved + 0.5 >= kTobyPanelExpandedHeight
        ? kTobyPanelSlots
        : kTobyPanelCompactSlots;

/// The one tonal hue of Toby's bars in the panel.
const Color kTobyAccent = Color(0xFF83C7C4);

/// Toby's arrow on the board: a deeper value of [kTobyAccent]'s hue, so it
/// reads on light and dark squares alike. The board keeps its own colours
/// whatever the site theme, so this holds on both.
final Color kTobyArrowColor = const Color(0xFF1E7F79).withValues(alpha: 0.9);

@visibleForTesting
const String tobyPanelOpenStorageKey = 'desktop.board.toby.open.v1';

/// Whether the reader left the panel open. Device-local, like the split
/// sizes around it. Only a reader who may read Toby can open it, so a free
/// reader never stores `true`.
class TobyPanelOpenPreference extends Notifier<bool> {
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
      final saved = preferences.getBool(tobyPanelOpenStorageKey);
      if (_disposed || _chosen || saved == null) return;
      state = saved;
    } catch (error) {
      debugPrint('Toby panel preference restore failed: $error');
    }
  }

  /// Records an explicit open or close. Writes are serialised so a slower
  /// close cannot overwrite a later open.
  void choose(bool open) {
    _chosen = true;
    if (state != open) state = open;
    final write = _writes.then((_) async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(tobyPanelOpenStorageKey, open);
    });
    _writes = write.catchError((Object error) {
      debugPrint('Toby panel preference write failed: $error');
    });
  }
}

final tobyPanelOpenPreferenceProvider =
    NotifierProvider<TobyPanelOpenPreference, bool>(
      TobyPanelOpenPreference.new,
    );

/// Whether the panel shows Toby's readings: the reader left it open AND may
/// read Toby right now. While the membership is loading, lapsed or free the
/// stored choice is ignored and the panel stays collapsed (and asks nothing).
final tobyPanelExpandedProvider = Provider<bool>(
  (ref) =>
      ref.watch(tobyPanelOpenPreferenceProvider) &&
      ref.watch(tobyPredictionAccessProvider.select((d) => d.isAllowed)),
);

/// The arrow Toby puts on the board, for one position.
///
/// [exclusive] arrows (a hovered or keyboard-focused candidate) are the only
/// shape on the board. A pinned arrow replaces the engine arrows only; the
/// reader's own drawings and the game's arrows stay.
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

/// Per-board state of the Toby panel, owned by the board pane so it outlives
/// the panel widget (which moves when the report opens) and is shared with
/// the board.
///
/// The panel writes hover and pin; the board only listens to [boardArrow].
/// Everything here is keyed by UCI, never by row, so a reading that re-sorts
/// under a still pointer keeps the same move highlighted.
class TobyPanelController extends ChangeNotifier {
  TobyPanelController({String? session})
    : session = session ?? newTobySession();

  /// The panel's id towards Gamebase, one per board for its lifetime.
  final String session;

  final ValueNotifier<TobyBoardArrow?> _boardArrow =
      ValueNotifier<TobyBoardArrow?>(null);
  _Mark? _hover;
  _Mark? _pin;
  TobyWhatIf _whatIf = (rating: null, cadence: null);
  bool _disposed = false;

  /// The one arrow to draw, if any. Only the board listens to it.
  ValueListenable<TobyBoardArrow?> get boardArrow => _boardArrow;

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

  /// Clears hover and pin, after a position change or a collapse.
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
    super.dispose();
  }
}
