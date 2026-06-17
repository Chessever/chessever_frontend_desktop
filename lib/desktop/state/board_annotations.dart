import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// User-drawn annotation shapes on the board (arrows + circles), keyed by
/// tab id so each Board tab keeps its own scratch ink. Cleared by
/// left-clicking the board (matching Lichess / Chess.com convention).
///
/// Shapes are stored in chessground's [cg.Shape] format so they can be
/// passed straight through `DesktopChessBoard.shapes` without translation.

/// Lichess-style annotation palette. Picked by mouse modifier:
///  - bare right-click       → [green]
///  - shift+right-click      → [red]
///  - alt/option+right-click → [blue]
///  - ctrl/meta+right-click  → [yellow]
enum AnnotationColor { green, red, blue, yellow }

extension AnnotationColorPalette on AnnotationColor {
  Color get color {
    switch (this) {
      case AnnotationColor.green:
        return const Color(0xCC15781B);
      case AnnotationColor.red:
        return const Color(0xCCB72217);
      case AnnotationColor.blue:
        return const Color(0xCC0044CC);
      case AnnotationColor.yellow:
        return const Color(0xCCE6A100);
    }
  }
}

@immutable
class BoardAnnotations {
  const BoardAnnotations({
    this.shapes = const <cg.Shape>{},
    this.positionShapes = const <String, Set<cg.Shape>>{},
  });

  /// Legacy/current-position scratch shapes. Kept for undo/reset surfaces.
  final Set<cg.Shape> shapes;

  /// User-drawn graphic commentary keyed by normalized FEN position key.
  /// This makes arrows/circles appear only when that exact position is active.
  final Map<String, Set<cg.Shape>> positionShapes;

  Set<cg.Shape> shapesForPosition(String positionKey) =>
      positionShapes[positionKey] ?? const <cg.Shape>{};

  Set<String> get annotatedPositionKeys =>
      positionShapes.entries
          .where((entry) => entry.value.isNotEmpty)
          .map((entry) => entry.key)
          .toSet();

  BoardAnnotations copyWith({
    Set<cg.Shape>? shapes,
    Map<String, Set<cg.Shape>>? positionShapes,
  }) {
    return BoardAnnotations(
      shapes: shapes ?? this.shapes,
      positionShapes: positionShapes ?? this.positionShapes,
    );
  }
}

class BoardAnnotationsNotifier extends StateNotifier<BoardAnnotations> {
  BoardAnnotationsNotifier() : super(const BoardAnnotations());

  /// Toggles a single-square mark (Circle) of [color] on [square]. If a
  /// matching circle exists, it's removed (so a second right-click in the
  /// same square cleans up after itself).
  void toggleCircle(
    Square square,
    AnnotationColor color, {
    String? positionKey,
  }) {
    final c = color.color;
    final currentShapes = _currentShapes(positionKey);
    cg.Shape? match;
    for (final s in currentShapes) {
      if (s is cg.Circle && s.orig == square && s.color == c) {
        match = s;
        break;
      }
    }
    if (match != null) {
      _setCurrentShapes({...currentShapes}..remove(match), positionKey);
      return;
    }
    _setCurrentShapes({
      ...currentShapes,
      cg.Circle(color: c, orig: square),
    }, positionKey);
  }

  /// Adds (or, when same shape already exists, removes) an arrow.
  void toggleArrow(
    Square orig,
    Square dest,
    AnnotationColor color, {
    String? positionKey,
  }) {
    if (orig == dest) {
      toggleCircle(orig, color, positionKey: positionKey);
      return;
    }
    final c = color.color;
    final currentShapes = _currentShapes(positionKey);
    cg.Shape? match;
    for (final s in currentShapes) {
      if (s is cg.Arrow && s.orig == orig && s.dest == dest && s.color == c) {
        match = s;
        break;
      }
    }
    if (match != null) {
      _setCurrentShapes({...currentShapes}..remove(match), positionKey);
      return;
    }
    _setCurrentShapes({
      ...currentShapes,
      cg.Arrow(color: c, orig: orig, dest: dest),
    }, positionKey);
  }

  /// Wipe all user-drawn shapes. Bound to a left-click on the board.
  void clear({String? positionKey}) {
    if (positionKey == null || positionKey.isEmpty) {
      if (state.shapes.isEmpty && state.positionShapes.isEmpty) return;
      state = const BoardAnnotations();
      return;
    }
    final currentShapes = _currentShapes(positionKey);
    if (currentShapes.isEmpty) return;
    _setCurrentShapes(const <cg.Shape>{}, positionKey);
  }

  /// Replace the entire shape set with [shapes]. Used by the undo stack
  /// to restore the pre-mutation snapshot without going through toggle
  /// semantics. The caller is expected to pass an immutable copy.
  void restore(Set<cg.Shape> shapes, {String? positionKey}) {
    _setCurrentShapes(Set<cg.Shape>.unmodifiable(shapes), positionKey);
  }

  Set<cg.Shape> _currentShapes(String? positionKey) {
    if (positionKey == null || positionKey.isEmpty) return state.shapes;
    return state.shapesForPosition(positionKey);
  }

  void _setCurrentShapes(Set<cg.Shape> shapes, String? positionKey) {
    final immutable = Set<cg.Shape>.unmodifiable(shapes);
    if (positionKey == null || positionKey.isEmpty) {
      state = state.copyWith(shapes: immutable);
      return;
    }
    final nextPositionShapes = Map<String, Set<cg.Shape>>.of(
      state.positionShapes,
    );
    if (immutable.isEmpty) {
      nextPositionShapes.remove(positionKey);
    } else {
      nextPositionShapes[positionKey] = immutable;
    }
    state = state.copyWith(
      shapes: immutable,
      positionShapes: Map<String, Set<cg.Shape>>.unmodifiable(
        nextPositionShapes,
      ),
    );
  }
}

final boardAnnotationsProvider = StateNotifierProvider.family<
  BoardAnnotationsNotifier,
  BoardAnnotations,
  String
>((ref, tabId) {
  return BoardAnnotationsNotifier();
});

/// Picks an [AnnotationColor] from a Flutter pointer event's modifier set
/// (or any source that knows shift/alt/ctrl bools). Mirrors Lichess.
AnnotationColor pickAnnotationColor({
  required bool shift,
  required bool alt,
  required bool ctrl,
}) {
  if (shift) return AnnotationColor.red;
  if (alt) return AnnotationColor.blue;
  if (ctrl) return AnnotationColor.yellow;
  return AnnotationColor.green;
}
