import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show ShortcutActivator, SingleActivator;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/repository/sqlite/app_database.dart';

/// Every navigation / mutation action exposed to the desktop chess board's
/// keyboard layer. Adding a new entry here is the only thing required to
/// make a new action user-bindable in the Settings keyboard-shortcuts card
/// (see [keyboardShortcutsProvider]).
enum BoardActionKey {
  prevMove,
  nextMove,
  previousNotationLine,
  nextNotationLine,
  firstMove,
  lastMove,
  prevVariation,
  nextVariation,
  undoLastEdit,
  flipBoard,
  copyPgn,
  pastePgn,
  savePgnFile,
  saveGameToLibrary,
  commentAfterMove,
  playEngineMove,
  clearAnalysis,
  showEventInfo,
  toggleEngine,
  openExplorer,
  openPositionSetup,
  openBoardSettings,
  prevGame,
  nextGame,
  autoReplay,
  goToMoveNumber,
  makeNextMoveVariation,
  enterNullMove,
  deleteVariation,
  classifyByOpening,
  classifyByThemes,
  findNovelty,
  showOpeningReference,
  switchNotationView,
  rightRailPreviousTab,
  rightRailNextTab,
  rightRailPreviousTable,
  rightRailNextTable,
  rightRailActivateSelection,
  closeVariation,
  increaseEngineLines,
  decreaseEngineLines,
  scrollNotationUp,
  scrollNotationDown,
  cutRemainingMoves,
  cutPreviousMoves,
  clearVariationsAndComments,
  commentBeforeMove,
  annotateGoodMove,
  annotateBrilliant,
  annotateMistake,
  annotateBlunder,
  annotateInteresting,
  annotateDubious,
  clearAnnotation,
  promoteVariation,
  deleteGraphicCommentary,
  trainingCommentary,
  correspondenceHeader,
  correspondenceMove,
  replaceGame,
  insertBestVariation,
  showThreat,
  calculateNextBestMove,
  togglePhotosWindow,
  toggleNotationWindow,
  toggleBoardFocus,
  closeWindow,
}

extension BoardActionKeyMeta on BoardActionKey {
  /// Human-readable label shown next to the chord pills in the settings UI
  /// and in tooltips.
  String get label {
    switch (this) {
      case BoardActionKey.prevMove:
        return 'Previous move';
      case BoardActionKey.nextMove:
        return 'Next move';
      case BoardActionKey.previousNotationLine:
        return 'Previous notation line';
      case BoardActionKey.nextNotationLine:
        return 'Next notation line';
      case BoardActionKey.firstMove:
        return 'Jump to start';
      case BoardActionKey.lastMove:
        return 'Jump to end';
      case BoardActionKey.prevVariation:
        return 'Previous line';
      case BoardActionKey.nextVariation:
        return 'Next line';
      case BoardActionKey.undoLastEdit:
        return 'Undo';
      case BoardActionKey.flipBoard:
        return 'Flip board';
      case BoardActionKey.copyPgn:
        return 'Copy PGN';
      case BoardActionKey.pastePgn:
        return 'Paste PGN';
      case BoardActionKey.savePgnFile:
        return 'Save PGN to file…';
      case BoardActionKey.saveGameToLibrary:
        return 'Save game to library…';
      case BoardActionKey.commentAfterMove:
        return 'Comment after move';
      case BoardActionKey.playEngineMove:
        return 'Play engine move';
      case BoardActionKey.clearAnalysis:
        return 'Reset edits';
      case BoardActionKey.showEventInfo:
        return 'Show event info';
      case BoardActionKey.toggleEngine:
        return 'Toggle engine analysis';
      case BoardActionKey.openExplorer:
        return 'Open opening explorer';
      case BoardActionKey.openPositionSetup:
        return 'Position setup';
      case BoardActionKey.openBoardSettings:
        return 'Open board settings';
      case BoardActionKey.prevGame:
        return 'Previous game';
      case BoardActionKey.nextGame:
        return 'Next game';
      case BoardActionKey.autoReplay:
        return 'Auto-replay game';
      case BoardActionKey.goToMoveNumber:
        return 'Go to move number';
      case BoardActionKey.makeNextMoveVariation:
        return 'Takeback for variation';
      case BoardActionKey.enterNullMove:
        return 'Enter null move';
      case BoardActionKey.deleteVariation:
        return 'Delete variation';
      case BoardActionKey.classifyByOpening:
        return 'Classify by opening';
      case BoardActionKey.classifyByThemes:
        return 'Classify by themes';
      case BoardActionKey.findNovelty:
        return 'Find novelty';
      case BoardActionKey.showOpeningReference:
        return 'Show opening reference';
      case BoardActionKey.switchNotationView:
        return 'Switch notation view';
      case BoardActionKey.rightRailPreviousTab:
        return 'Right pane previous tab';
      case BoardActionKey.rightRailNextTab:
        return 'Right pane next tab';
      case BoardActionKey.rightRailPreviousTable:
        return 'Right pane previous table';
      case BoardActionKey.rightRailNextTable:
        return 'Right pane next table';
      case BoardActionKey.rightRailActivateSelection:
        return 'Activate right pane selection';
      case BoardActionKey.closeVariation:
        return 'Close variation';
      case BoardActionKey.increaseEngineLines:
        return 'Increase engine lines';
      case BoardActionKey.decreaseEngineLines:
        return 'Decrease engine lines';
      case BoardActionKey.scrollNotationUp:
        return 'Scroll notation up';
      case BoardActionKey.scrollNotationDown:
        return 'Scroll notation down';
      case BoardActionKey.cutRemainingMoves:
        return 'Cut remaining moves';
      case BoardActionKey.cutPreviousMoves:
        return 'Cut previous moves';
      case BoardActionKey.clearVariationsAndComments:
        return 'Remove variations and comments';
      case BoardActionKey.commentBeforeMove:
        return 'Comment before move';
      case BoardActionKey.annotateGoodMove:
        return 'Annotate good move (!)';
      case BoardActionKey.annotateBrilliant:
        return 'Annotate brilliant (!!)';
      case BoardActionKey.annotateMistake:
        return 'Annotate mistake (?)';
      case BoardActionKey.annotateBlunder:
        return 'Annotate blunder (??)';
      case BoardActionKey.annotateInteresting:
        return 'Annotate interesting (!?)';
      case BoardActionKey.annotateDubious:
        return 'Annotate dubious (?!)';
      case BoardActionKey.clearAnnotation:
        return 'Clear move annotation';
      case BoardActionKey.promoteVariation:
        return 'Promote variation to mainline';
      case BoardActionKey.deleteGraphicCommentary:
        return 'Delete graphic commentary';
      case BoardActionKey.trainingCommentary:
        return 'Training commentary';
      case BoardActionKey.correspondenceHeader:
        return 'Correspondence header';
      case BoardActionKey.correspondenceMove:
        return 'Correspondence move';
      case BoardActionKey.replaceGame:
        return 'Replace game';
      case BoardActionKey.insertBestVariation:
        return 'Insert best variation';
      case BoardActionKey.showThreat:
        return 'Show threat';
      case BoardActionKey.calculateNextBestMove:
        return 'Calculate next best move';
      case BoardActionKey.togglePhotosWindow:
        return 'Toggle photos window';
      case BoardActionKey.toggleNotationWindow:
        return 'Toggle notation window';
      case BoardActionKey.toggleBoardFocus:
        return 'Toggle board focus';
      case BoardActionKey.closeWindow:
        return 'Close board window';
    }
  }

  String get description {
    switch (this) {
      case BoardActionKey.prevMove:
        return 'Step one move backward in the active line.';
      case BoardActionKey.nextMove:
        return 'Step one move forward in the active line.';
      case BoardActionKey.previousNotationLine:
        return 'Move to the notation move directly above the active move, '
            'including moves in variation lines.';
      case BoardActionKey.nextNotationLine:
        return 'Move to the notation move directly below the active move, '
            'including moves in variation lines.';
      case BoardActionKey.firstMove:
        return 'Jump to the starting position.';
      case BoardActionKey.lastMove:
        return 'Jump to the last played move of the active line.';
      case BoardActionKey.prevVariation:
        return 'Switch to the previous sibling line at the current branch. '
            'Falls back to stepping one move backward when there is no '
            'sibling to switch to.';
      case BoardActionKey.nextVariation:
        return 'Switch to the next sibling line at the current branch. '
            'Falls back to stepping one move forward when there is no '
            'sibling to switch to.';
      case BoardActionKey.undoLastEdit:
        return 'Undo the last board edit, such as a played move, comment, '
            'variation promotion, or deleted continuation.';
      case BoardActionKey.flipBoard:
        return 'Swap which side sits at the bottom of the board.';
      case BoardActionKey.copyPgn:
        return 'Copy the current game (with variations) as PGN to the '
            'clipboard.';
      case BoardActionKey.pastePgn:
        return 'Load a PGN from the clipboard into the active board.';
      case BoardActionKey.savePgnFile:
        return 'Write the current game to a `.pgn` file on disk.';
      case BoardActionKey.saveGameToLibrary:
        return 'Save the current game into a folder of your in-app library.';
      case BoardActionKey.commentAfterMove:
        return 'Add or edit the PGN comment attached to the current move.';
      case BoardActionKey.playEngineMove:
        return 'Play the first move from Stockfish\'s top principal variation.';
      case BoardActionKey.clearAnalysis:
        return 'Wipe every edit on this game — drawn arrows and circles, '
            'move-quality marks, and sub-variations you added.';
      case BoardActionKey.showEventInfo:
        return 'Reveal the PGN headers (event, round, players, ratings).';
      case BoardActionKey.toggleEngine:
        return 'Turn Stockfish analysis on or off for this position.';
      case BoardActionKey.openExplorer:
        return 'Switch the right rail to the opening explorer view.';
      case BoardActionKey.openPositionSetup:
        return 'Open the position setup board seeded from the current position.';
      case BoardActionKey.openBoardSettings:
        return 'Open the Board Settings tab.';
      case BoardActionKey.prevGame:
        return 'Switch the active board to the previous game in the side '
            'list (event or database).';
      case BoardActionKey.nextGame:
        return 'Switch the active board to the next game in the side list '
            '(event or database).';
      case BoardActionKey.autoReplay:
        return 'Replay the current game forward automatically until stopped.';
      case BoardActionKey.goToMoveNumber:
        return 'Jump to a numbered move in the current notation.';
      case BoardActionKey.makeNextMoveVariation:
        return 'Step back so the next played move becomes a variation.';
      case BoardActionKey.enterNullMove:
        return 'Insert a null move in the notation when supported.';
      case BoardActionKey.deleteVariation:
        return 'Delete the active variation and return to its parent line.';
      case BoardActionKey.classifyByOpening:
        return 'Classify the game by opening in the reference database.';
      case BoardActionKey.classifyByThemes:
        return 'Classify the game by tactical and strategic themes.';
      case BoardActionKey.findNovelty:
        return 'Compare against the reference database and find a novelty.';
      case BoardActionKey.showOpeningReference:
        return 'Show the opening reference for the current board position.';
      case BoardActionKey.switchNotationView:
        return 'Cycle the right rail between notation/reference views.';
      case BoardActionKey.rightRailPreviousTab:
        return 'Move the in-game right pane to the previous top-level tab.';
      case BoardActionKey.rightRailNextTab:
        return 'Move the in-game right pane to the next top-level tab.';
      case BoardActionKey.rightRailPreviousTable:
        return 'Move focus to the previous table inside the active right-pane tab.';
      case BoardActionKey.rightRailNextTable:
        return 'Move focus to the next table inside the active right-pane tab.';
      case BoardActionKey.rightRailActivateSelection:
        return 'Activate the focused right-pane row, such as playing an explorer move or opening a game.';
      case BoardActionKey.closeVariation:
        return 'Leave the current variation and return to the parent line.';
      case BoardActionKey.increaseEngineLines:
        return 'Ask the engine panel to show one more principal variation.';
      case BoardActionKey.decreaseEngineLines:
        return 'Ask the engine panel to show one fewer principal variation.';
      case BoardActionKey.scrollNotationUp:
        return 'Scroll the notation pane up by one page.';
      case BoardActionKey.scrollNotationDown:
        return 'Scroll the notation pane down by one page.';
      case BoardActionKey.cutRemainingMoves:
        return 'Delete the continuation after the selected move.';
      case BoardActionKey.cutPreviousMoves:
        return 'Delete moves before the selected move when supported.';
      case BoardActionKey.clearVariationsAndComments:
        return 'Remove variations, text comments, graphic comments, and '
            'user annotations from the current game.';
      case BoardActionKey.commentBeforeMove:
        return 'Add text commentary before the selected move when supported.';
      case BoardActionKey.annotateGoodMove:
        return 'Mark the selected move with the ! annotation glyph.';
      case BoardActionKey.annotateBrilliant:
        return 'Mark the selected move with the !! annotation glyph.';
      case BoardActionKey.annotateMistake:
        return 'Mark the selected move with the ? annotation glyph.';
      case BoardActionKey.annotateBlunder:
        return 'Mark the selected move with the ?? annotation glyph.';
      case BoardActionKey.annotateInteresting:
        return 'Mark the selected move with the !? annotation glyph.';
      case BoardActionKey.annotateDubious:
        return 'Mark the selected move with the ?! annotation glyph.';
      case BoardActionKey.clearAnnotation:
        return 'Remove any annotation glyph from the selected move.';
      case BoardActionKey.promoteVariation:
        return 'Replace the mainline with the variation containing the '
            'selected move.';
      case BoardActionKey.deleteGraphicCommentary:
        return 'Remove arrows and highlighted squares from the board.';
      case BoardActionKey.trainingCommentary:
        return 'Enter training commentary when that editor is available.';
      case BoardActionKey.correspondenceHeader:
        return 'Enter correspondence chess header data when available.';
      case BoardActionKey.correspondenceMove:
        return 'Annotate the selected move as a correspondence move.';
      case BoardActionKey.replaceGame:
        return 'Replace the loaded game in its source database when '
            'database write-back is available.';
      case BoardActionKey.insertBestVariation:
        return 'Insert the best variation from the active engine line.';
      case BoardActionKey.showThreat:
        return 'Ask the engine for the side-to-move threat when supported.';
      case BoardActionKey.calculateNextBestMove:
        return 'Calculate the next best move when supported by the engine.';
      case BoardActionKey.togglePhotosWindow:
        return 'Open or close the player photos pane when available.';
      case BoardActionKey.toggleNotationWindow:
        return 'Open or close the notation pane when available.';
      case BoardActionKey.toggleBoardFocus:
        return 'Enter or exit board focus mode.';
      case BoardActionKey.closeWindow:
        return 'Close the active board tab or window.';
    }
  }

  /// Stable string id used as the JSON key in the persisted map. Must not
  /// change between releases — that's the whole point of the manual table
  /// instead of `enum.name`.
  String get storageId {
    switch (this) {
      case BoardActionKey.prevMove:
        return 'prev_move';
      case BoardActionKey.nextMove:
        return 'next_move';
      case BoardActionKey.previousNotationLine:
        return 'previous_notation_line';
      case BoardActionKey.nextNotationLine:
        return 'next_notation_line';
      case BoardActionKey.firstMove:
        return 'first_move';
      case BoardActionKey.lastMove:
        return 'last_move';
      case BoardActionKey.prevVariation:
        return 'prev_variation';
      case BoardActionKey.nextVariation:
        return 'next_variation';
      case BoardActionKey.undoLastEdit:
        return 'undo_last_edit';
      case BoardActionKey.flipBoard:
        return 'flip_board';
      case BoardActionKey.copyPgn:
        return 'copy_pgn';
      case BoardActionKey.pastePgn:
        return 'paste_pgn';
      case BoardActionKey.savePgnFile:
        return 'save_pgn_file';
      case BoardActionKey.saveGameToLibrary:
        return 'save_game_to_library';
      case BoardActionKey.commentAfterMove:
        return 'comment_after_move';
      case BoardActionKey.playEngineMove:
        return 'play_engine_move';
      case BoardActionKey.clearAnalysis:
        return 'clear_analysis';
      case BoardActionKey.showEventInfo:
        return 'show_event_info';
      case BoardActionKey.toggleEngine:
        return 'toggle_engine';
      case BoardActionKey.openExplorer:
        return 'open_explorer';
      case BoardActionKey.openPositionSetup:
        return 'open_position_setup';
      case BoardActionKey.openBoardSettings:
        return 'open_board_settings';
      case BoardActionKey.prevGame:
        return 'prev_game';
      case BoardActionKey.nextGame:
        return 'next_game';
      case BoardActionKey.autoReplay:
        return 'auto_replay';
      case BoardActionKey.goToMoveNumber:
        return 'go_to_move_number';
      case BoardActionKey.makeNextMoveVariation:
        return 'make_next_move_variation';
      case BoardActionKey.enterNullMove:
        return 'enter_null_move';
      case BoardActionKey.deleteVariation:
        return 'delete_variation';
      case BoardActionKey.classifyByOpening:
        return 'classify_by_opening';
      case BoardActionKey.classifyByThemes:
        return 'classify_by_themes';
      case BoardActionKey.findNovelty:
        return 'find_novelty';
      case BoardActionKey.showOpeningReference:
        return 'show_opening_reference';
      case BoardActionKey.switchNotationView:
        return 'switch_notation_view';
      case BoardActionKey.rightRailPreviousTab:
        return 'right_rail_previous_tab';
      case BoardActionKey.rightRailNextTab:
        return 'right_rail_next_tab';
      case BoardActionKey.rightRailPreviousTable:
        return 'right_rail_previous_table';
      case BoardActionKey.rightRailNextTable:
        return 'right_rail_next_table';
      case BoardActionKey.rightRailActivateSelection:
        return 'right_rail_activate_selection';
      case BoardActionKey.closeVariation:
        return 'close_variation';
      case BoardActionKey.increaseEngineLines:
        return 'increase_engine_lines';
      case BoardActionKey.decreaseEngineLines:
        return 'decrease_engine_lines';
      case BoardActionKey.scrollNotationUp:
        return 'scroll_notation_up';
      case BoardActionKey.scrollNotationDown:
        return 'scroll_notation_down';
      case BoardActionKey.cutRemainingMoves:
        return 'cut_remaining_moves';
      case BoardActionKey.cutPreviousMoves:
        return 'cut_previous_moves';
      case BoardActionKey.clearVariationsAndComments:
        return 'clear_variations_and_comments';
      case BoardActionKey.commentBeforeMove:
        return 'comment_before_move';
      case BoardActionKey.annotateGoodMove:
        return 'annotate_good_move';
      case BoardActionKey.annotateBrilliant:
        return 'annotate_brilliant';
      case BoardActionKey.annotateMistake:
        return 'annotate_mistake';
      case BoardActionKey.annotateBlunder:
        return 'annotate_blunder';
      case BoardActionKey.annotateInteresting:
        return 'annotate_interesting';
      case BoardActionKey.annotateDubious:
        return 'annotate_dubious';
      case BoardActionKey.clearAnnotation:
        return 'clear_annotation';
      case BoardActionKey.promoteVariation:
        return 'promote_variation';
      case BoardActionKey.deleteGraphicCommentary:
        return 'delete_graphic_commentary';
      case BoardActionKey.trainingCommentary:
        return 'training_commentary';
      case BoardActionKey.correspondenceHeader:
        return 'correspondence_header';
      case BoardActionKey.correspondenceMove:
        return 'correspondence_move';
      case BoardActionKey.replaceGame:
        return 'replace_game';
      case BoardActionKey.insertBestVariation:
        return 'insert_best_variation';
      case BoardActionKey.showThreat:
        return 'show_threat';
      case BoardActionKey.calculateNextBestMove:
        return 'calculate_next_best_move';
      case BoardActionKey.togglePhotosWindow:
        return 'toggle_photos_window';
      case BoardActionKey.toggleNotationWindow:
        return 'toggle_notation_window';
      case BoardActionKey.toggleBoardFocus:
        return 'toggle_board_focus';
      case BoardActionKey.closeWindow:
        return 'close_window';
    }
  }
}

/// One keystroke binding (e.g. "⌘ + Shift + S"). Encodes a
/// [LogicalKeyboardKey] by id plus the four desktop modifier flags. Trusted
/// to round-trip through JSON for sqflite storage.
@immutable
class KeyChord {
  const KeyChord({
    required this.keyId,
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
    this.crossPlatform = false,
  });

  final int keyId;
  final bool ctrl;
  final bool alt;
  final bool shift;
  final bool meta;

  /// When true, a `meta` flag is treated as "the platform's primary
  /// modifier" — Cmd on macOS, Ctrl on Windows. This is the convention
  /// used by shipped defaults so a single declaration delivers Cmd+S on
  /// macOS and Ctrl+S on Windows. User-recorded chords default to
  /// `false`: the recorder captures literal modifier flags and stores
  /// them as-is so a Windows user who deliberately presses Win+S keeps
  /// Win+S — not the silent Ctrl+S coercion the previous version did.
  final bool crossPlatform;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'k': keyId,
    if (ctrl) 'c': true,
    if (alt) 'a': true,
    if (shift) 's': true,
    if (meta) 'm': true,
    if (crossPlatform) 'x': true,
  };

  factory KeyChord.fromJson(Map<String, dynamic> json) {
    final keyId = (json['k'] as num?)?.toInt();
    if (keyId == null) {
      throw const FormatException('KeyChord JSON missing "k"');
    }
    return KeyChord(
      keyId: keyId,
      ctrl: json['c'] == true,
      alt: json['a'] == true,
      shift: json['s'] == true,
      meta: json['m'] == true,
      crossPlatform: json['x'] == true,
    );
  }

  /// True when [chord] matches both the key and *all* modifier flags. The
  /// modifier comparison is exact — Cmd+S must not match S alone, and S
  /// must not match Cmd+S — to avoid silent collisions in the binding map.
  /// Note: [crossPlatform] is *not* part of the equality so a default and
  /// a user-recorded chord that produce the same activator on the current
  /// platform still register as a duplicate in the conflict check.
  bool matches(KeyChord other) =>
      other.keyId == keyId &&
      other.ctrl == ctrl &&
      other.alt == alt &&
      other.shift == shift &&
      other.meta == meta;

  /// Dart `Equality` for use as map keys / set members.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is KeyChord && matches(other);
  }

  @override
  int get hashCode => Object.hash(keyId, ctrl, alt, shift, meta);

  /// Builds a Flutter [SingleActivator] so the chord can drop straight
  /// into a `Shortcuts` widget map.
  ///
  /// For [crossPlatform]-flagged defaults: meta becomes Cmd on macOS,
  /// Ctrl on Windows — the conventional cross-platform shortcut idiom.
  /// For user-recorded chords (crossPlatform == false): modifier flags
  /// are honoured literally, so Win+S stays Win+S on Windows.
  ShortcutActivator toActivator() {
    final isMac = Platform.isMacOS;
    final bool useCtrl;
    final bool useMeta;
    if (crossPlatform) {
      useCtrl = ctrl || (meta && !isMac);
      useMeta = meta && isMac;
    } else {
      useCtrl = ctrl;
      useMeta = meta;
    }
    return SingleActivator(
      LogicalKeyboardKey(keyId),
      control: useCtrl,
      alt: alt,
      shift: shift,
      meta: useMeta,
    );
  }

  /// Display string shown in the settings UI and in tooltips.
  ///
  /// Mac users see the canonical glyphs (⌘ ⌃ ⌥ ⇧) so the chord matches
  /// what the system menu bar would render. Windows users see Ctrl/Alt/
  /// Shift/Win. For [crossPlatform] chords, the rendered modifier
  /// reflects what will *actually* fire on the current OS — so a default
  /// declared with `meta:true, crossPlatform:true` reads "Ctrl + S" on
  /// Windows and "⌘ S" on macOS rather than confusing the user with the
  /// other platform's glyph.
  String get label {
    final parts = <String>[];
    final isMac = Platform.isMacOS;
    bool effectiveCtrl = ctrl;
    bool effectiveMeta = meta;
    if (crossPlatform) {
      effectiveCtrl = ctrl || (meta && !isMac);
      effectiveMeta = meta && isMac;
    }
    if (effectiveCtrl) parts.add(isMac ? '⌃' : 'Ctrl');
    if (alt) parts.add(isMac ? '⌥' : 'Alt');
    if (shift) parts.add(isMac ? '⇧' : 'Shift');
    if (effectiveMeta) parts.add(isMac ? '⌘' : 'Win');
    parts.add(_keyLabel(LogicalKeyboardKey(keyId)));
    return parts.join(isMac ? '' : ' + ');
  }
}

String _keyLabel(LogicalKeyboardKey key) {
  // Special-case symbols and arrows so the rendered chord reads like a
  // OS-native shortcut even when the key's debugName is something like
  // "Arrow Left". Falls through to a best-effort title-cased debugName.
  switch (key.keyId) {
    case 0x100070050: // arrowLeft
      return '←';
    case 0x10007004F: // arrowRight
      return '→';
    case 0x100070052: // arrowUp
      return '↑';
    case 0x100070051: // arrowDown
      return '↓';
    case 0x10007004A: // home
      return 'Home';
    case 0x10007004D: // end
      return 'End';
    case 0x10007002C: // space
      return 'Space';
    case 0x100070028: // enter
      return '↵';
    case 0x100070029: // escape
      return 'Esc';
    case 0x10007002A: // backspace
      return 'Backspace';
    case 0x10007002B: // tab
      return '⇥';
  }
  final name = key.keyLabel.isNotEmpty ? key.keyLabel : (key.debugName ?? '');
  if (name.isEmpty) return 'Key 0x${key.keyId.toRadixString(16)}';
  // Single letters → uppercase so "a" reads "A".
  if (name.length == 1) return name.toUpperCase();
  return name;
}

/// Defaults shipped with the app. Each entry is a list so an action can
/// have *several* equivalent bindings out of the box (Home and ↑ both jump
/// to the start, for example), and so the settings UI can offer "primary"
/// and "alternate" slots without inventing a hardcoded number.
KeyChord _key(LogicalKeyboardKey key) => KeyChord(keyId: key.keyId);

KeyChord _ctrl(LogicalKeyboardKey key) =>
    KeyChord(keyId: key.keyId, ctrl: true);

KeyChord _alt(LogicalKeyboardKey key) => KeyChord(keyId: key.keyId, alt: true);

KeyChord _shift(LogicalKeyboardKey key) =>
    KeyChord(keyId: key.keyId, shift: true);

KeyChord _ctrlAlt(LogicalKeyboardKey key) =>
    KeyChord(keyId: key.keyId, ctrl: true, alt: true);

KeyChord _ctrlShift(LogicalKeyboardKey key) =>
    KeyChord(keyId: key.keyId, ctrl: true, shift: true);

KeyChord _ctrlAltShift(LogicalKeyboardKey key) =>
    KeyChord(keyId: key.keyId, ctrl: true, alt: true, shift: true);

KeyChord _primary(LogicalKeyboardKey key, {bool shift = false}) =>
    KeyChord(keyId: key.keyId, meta: true, shift: shift, crossPlatform: true);

Map<BoardActionKey, List<KeyChord>> defaultBoardShortcuts() {
  return <BoardActionKey, List<KeyChord>>{
    BoardActionKey.prevMove: [_key(LogicalKeyboardKey.arrowLeft)],
    BoardActionKey.nextMove: [_key(LogicalKeyboardKey.arrowRight)],
    BoardActionKey.previousNotationLine: [_key(LogicalKeyboardKey.arrowUp)],
    BoardActionKey.nextNotationLine: [_key(LogicalKeyboardKey.arrowDown)],
    BoardActionKey.firstMove: [
      _key(LogicalKeyboardKey.home),
      _ctrl(LogicalKeyboardKey.arrowLeft),
      _primary(LogicalKeyboardKey.arrowLeft),
    ],
    BoardActionKey.lastMove: [
      _key(LogicalKeyboardKey.end),
      _ctrl(LogicalKeyboardKey.arrowRight),
      _primary(LogicalKeyboardKey.arrowRight),
    ],
    BoardActionKey.prevVariation: [_key(LogicalKeyboardKey.arrowUp)],
    BoardActionKey.nextVariation: [_key(LogicalKeyboardKey.arrowDown)],
    BoardActionKey.undoLastEdit: [
      _primary(LogicalKeyboardKey.keyZ),
      _ctrl(LogicalKeyboardKey.keyZ),
    ],
    BoardActionKey.flipBoard: [_key(LogicalKeyboardKey.keyF)],
    BoardActionKey.copyPgn: [_primary(LogicalKeyboardKey.keyC)],
    BoardActionKey.pastePgn: [_primary(LogicalKeyboardKey.keyV)],
    BoardActionKey.savePgnFile: [
      _primary(LogicalKeyboardKey.keyS, shift: true),
      _ctrlShift(LogicalKeyboardKey.keyS),
    ],
    BoardActionKey.saveGameToLibrary: [
      _primary(LogicalKeyboardKey.keyS),
      _ctrl(LogicalKeyboardKey.keyS),
    ],
    BoardActionKey.commentAfterMove: [
      _primary(LogicalKeyboardKey.keyA),
      _ctrl(LogicalKeyboardKey.keyA),
      _primary(LogicalKeyboardKey.semicolon),
      _key(LogicalKeyboardKey.semicolon),
    ],
    BoardActionKey.playEngineMove: [_key(LogicalKeyboardKey.space)],
    BoardActionKey.clearAnalysis: const [],
    BoardActionKey.showEventInfo: [_key(LogicalKeyboardKey.keyI)],
    BoardActionKey.toggleEngine: [
      _key(LogicalKeyboardKey.keyE),
      _alt(LogicalKeyboardKey.f2),
    ],
    BoardActionKey.openExplorer: [
      _key(LogicalKeyboardKey.enter),
      _key(LogicalKeyboardKey.numpadEnter),
      _primary(LogicalKeyboardKey.keyO, shift: true),
    ],
    BoardActionKey.openPositionSetup: [_key(LogicalKeyboardKey.keyS)],
    BoardActionKey.openBoardSettings: const [],
    BoardActionKey.prevGame: [
      _primary(LogicalKeyboardKey.arrowUp),
      _ctrl(LogicalKeyboardKey.f10),
    ],
    BoardActionKey.nextGame: [
      _primary(LogicalKeyboardKey.arrowDown),
      _key(LogicalKeyboardKey.f10),
      _key(LogicalKeyboardKey.f11),
    ],
    BoardActionKey.autoReplay: [_key(LogicalKeyboardKey.asterisk)],
    BoardActionKey.goToMoveNumber: [_ctrl(LogicalKeyboardKey.keyG)],
    BoardActionKey.makeNextMoveVariation: [_key(LogicalKeyboardKey.keyT)],
    BoardActionKey.enterNullMove: [_ctrlAlt(LogicalKeyboardKey.digit0)],
    BoardActionKey.deleteVariation: [_ctrl(LogicalKeyboardKey.keyY)],
    BoardActionKey.classifyByOpening: [_ctrlAlt(LogicalKeyboardKey.keyC)],
    BoardActionKey.classifyByThemes: [_ctrlAltShift(LogicalKeyboardKey.keyC)],
    BoardActionKey.findNovelty: [_shift(LogicalKeyboardKey.f6)],
    BoardActionKey.showOpeningReference: [_shift(LogicalKeyboardKey.f7)],
    BoardActionKey.switchNotationView: [_key(LogicalKeyboardKey.tab)],
    BoardActionKey.rightRailPreviousTab: [
      _primary(LogicalKeyboardKey.comma, shift: true),
      _alt(LogicalKeyboardKey.arrowLeft),
      _alt(LogicalKeyboardKey.arrowUp),
    ],
    BoardActionKey.rightRailNextTab: [
      _primary(LogicalKeyboardKey.period, shift: true),
      _alt(LogicalKeyboardKey.arrowRight),
      _alt(LogicalKeyboardKey.arrowDown),
    ],
    BoardActionKey.rightRailPreviousTable: const [],
    BoardActionKey.rightRailNextTable: const [],
    // Right-rail widgets handle Enter locally when focused. Keeping this
    // unbound at the global board shortcut layer lets Enter toggle Explorer
    // from board focus instead of being overwritten by this no-op action.
    BoardActionKey.rightRailActivateSelection: const [],
    BoardActionKey.closeVariation: [_key(LogicalKeyboardKey.keyM)],
    BoardActionKey.increaseEngineLines: [
      _key(LogicalKeyboardKey.add),
      _key(LogicalKeyboardKey.numpadAdd),
    ],
    BoardActionKey.decreaseEngineLines: [
      _key(LogicalKeyboardKey.minus),
      _key(LogicalKeyboardKey.numpadSubtract),
    ],
    BoardActionKey.scrollNotationUp: [_key(LogicalKeyboardKey.pageUp)],
    BoardActionKey.scrollNotationDown: [_key(LogicalKeyboardKey.pageDown)],
    BoardActionKey.cutRemainingMoves: [_key(LogicalKeyboardKey.bracketRight)],
    BoardActionKey.cutPreviousMoves: [_key(LogicalKeyboardKey.bracketLeft)],
    BoardActionKey.clearVariationsAndComments: [
      _ctrlShift(LogicalKeyboardKey.keyY),
    ],
    BoardActionKey.commentBeforeMove: [_ctrlShift(LogicalKeyboardKey.keyA)],
    BoardActionKey.annotateGoodMove: [_shift(LogicalKeyboardKey.digit1)],
    BoardActionKey.annotateBrilliant: [_shift(LogicalKeyboardKey.digit2)],
    BoardActionKey.annotateMistake: [_shift(LogicalKeyboardKey.digit3)],
    BoardActionKey.annotateBlunder: [_shift(LogicalKeyboardKey.digit4)],
    BoardActionKey.annotateInteresting: [_shift(LogicalKeyboardKey.digit5)],
    BoardActionKey.annotateDubious: [_shift(LogicalKeyboardKey.digit6)],
    BoardActionKey.clearAnnotation: [_shift(LogicalKeyboardKey.digit0)],
    BoardActionKey.promoteVariation: [_key(LogicalKeyboardKey.keyV)],
    BoardActionKey.deleteGraphicCommentary: [_ctrlAlt(LogicalKeyboardKey.keyY)],
    BoardActionKey.trainingCommentary: [_ctrlAlt(LogicalKeyboardKey.keyM)],
    BoardActionKey.correspondenceHeader: [_ctrlAlt(LogicalKeyboardKey.keyW)],
    BoardActionKey.correspondenceMove: [_ctrl(LogicalKeyboardKey.keyW)],
    BoardActionKey.replaceGame: [_ctrl(LogicalKeyboardKey.keyR)],
    BoardActionKey.insertBestVariation: [_ctrl(LogicalKeyboardKey.space)],
    BoardActionKey.showThreat: [_key(LogicalKeyboardKey.keyX)],
    BoardActionKey.calculateNextBestMove: [_key(LogicalKeyboardKey.keyY)],
    BoardActionKey.togglePhotosWindow: [_ctrlAlt(LogicalKeyboardKey.keyB)],
    BoardActionKey.toggleNotationWindow: [_ctrlAlt(LogicalKeyboardKey.keyN)],
    BoardActionKey.toggleBoardFocus: [_key(LogicalKeyboardKey.keyB)],
    BoardActionKey.closeWindow: [_key(LogicalKeyboardKey.escape)],
  };
}

/// Snapshot of the user's keybindings — defaults overlaid with any custom
/// chords the user has recorded. The settings UI mutates this map through
/// `KeyboardShortcutsNotifier`.
@immutable
class BoardShortcutMap {
  const BoardShortcutMap(this.bindings);

  final Map<BoardActionKey, List<KeyChord>> bindings;

  List<KeyChord> chordsFor(BoardActionKey action) =>
      _chordsFor(bindings[action]);

  BoardShortcutMap copyWith({Map<BoardActionKey, List<KeyChord>>? bindings}) {
    return BoardShortcutMap(bindings ?? this.bindings);
  }

  /// True when [chord] is bound to *some* action — used by the recorder
  /// to flag conflicts before the user commits a binding.
  BoardActionKey? actionForChord(KeyChord chord) {
    if (_isReservedSearchFindChord(chord)) return null;
    for (final entry in bindings.entries) {
      for (final c in _chordsFor(entry.value)) {
        if (c.matches(chord)) return entry.key;
      }
    }
    return null;
  }
}

List<KeyChord> _chordsFor(List<KeyChord>? chords) {
  final resolved = chords ?? const <KeyChord>[];
  return List.unmodifiable(
    resolved.where((chord) => !_isReservedSearchFindChord(chord)),
  );
}

bool _isReservedSearchFindChord(KeyChord chord) {
  if (chord.keyId != LogicalKeyboardKey.keyF.keyId) return false;
  if (chord.alt || chord.shift) return false;
  return chord.ctrl || chord.meta || chord.crossPlatform;
}

/// AsyncNotifier-backed provider for the keybinding map. Hits sqflite on
/// first read and persists every mutation immediately. Defaults fill any
/// missing keys so a freshly-installed app behaves like the previous
/// hardcoded set.
final keyboardShortcutsProvider =
    AsyncNotifierProvider<KeyboardShortcutsNotifier, BoardShortcutMap>(
      KeyboardShortcutsNotifier.new,
    );

class KeyboardShortcutsNotifier extends AsyncNotifier<BoardShortcutMap> {
  static const _cacheKey = 'desktop_board_keyboard_shortcuts_v1';

  @override
  Future<BoardShortcutMap> build() async {
    return _loadFromCache();
  }

  Future<BoardShortcutMap> _loadFromCache() async {
    final defaults = defaultBoardShortcuts();
    try {
      final db = AppDatabase.instance;
      final raw = await db.getJson<Map<String, dynamic>>(_cacheKey);
      if (raw == null) return BoardShortcutMap(defaults);

      final overrides = <BoardActionKey, List<KeyChord>>{};
      for (final action in BoardActionKey.values) {
        final encoded = raw[action.storageId];
        if (encoded is! List) continue;
        final chords = <KeyChord>[];
        for (final entry in encoded) {
          if (entry is! Map) continue;
          try {
            chords.add(KeyChord.fromJson(entry.cast<String, dynamic>()));
          } catch (_) {
            // Skip malformed entries rather than fail the whole load —
            // a corrupt row shouldn't lock out the entire shortcut UI.
          }
        }
        overrides[action] = chords;
      }
      _upgradeDefaultLikeOverrides(overrides, defaults);

      // Merge: persisted entry wins (including persisted-empty-list, so
      // unbinding survives a relaunch); missing keys fall back to defaults.
      final merged = <BoardActionKey, List<KeyChord>>{};
      for (final action in BoardActionKey.values) {
        final chords =
            overrides.containsKey(action)
                ? overrides[action]!
                : defaults[action] ?? const <KeyChord>[];
        merged[action] = _chordsFor(chords);
      }
      return BoardShortcutMap(merged);
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ keyboardShortcuts load failed: $e');
      return BoardShortcutMap(defaults);
    }
  }

  Future<void> _persist(BoardShortcutMap map) async {
    try {
      final db = AppDatabase.instance;
      final encoded = <String, dynamic>{};
      for (final entry in map.bindings.entries) {
        encoded[entry.key.storageId] = entry.value
            .map((c) => c.toJson())
            .toList(growable: false);
      }
      await db.setJson(_cacheKey, encoded);
    } catch (e, st) {
      // Log unconditionally — silently dropping a settings write means
      // the user's customisations vanish on next launch. We still keep
      // the in-memory state so the current session works.
      debugPrint('⚠️ keyboardShortcuts persist failed: $e');
      debugPrint('$st');
    }
  }

  /// Replace the chord list for [action] with [chords]. Pass an empty
  /// list to clear the binding (the action stays in the map; just no
  /// keystroke fires it). Does not check for conflicts — call sites are
  /// expected to surface conflict warnings before invoking.
  Future<void> setChords(BoardActionKey action, List<KeyChord> chords) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final next = Map<BoardActionKey, List<KeyChord>>.of(current.bindings);
    next[action] = _chordsFor(chords);
    final updated = BoardShortcutMap(next);
    state = AsyncValue.data(updated);
    await _persist(updated);
  }

  Future<void> addChord(BoardActionKey action, KeyChord chord) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final existing = current.chordsFor(action);
    if (existing.any((c) => c.matches(chord))) return;
    await setChords(action, <KeyChord>[...existing, chord]);
  }

  Future<void> removeChord(BoardActionKey action, KeyChord chord) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final existing = current.chordsFor(action);
    final next = existing.where((c) => !c.matches(chord)).toList();
    await setChords(action, next);
  }

  /// Drop every override and revert to the shipped defaults.
  Future<void> resetAll() async {
    final defaults = defaultBoardShortcuts();
    final next = <BoardActionKey, List<KeyChord>>{
      for (final action in BoardActionKey.values)
        action: List.unmodifiable(defaults[action] ?? const <KeyChord>[]),
    };
    final map = BoardShortcutMap(next);
    state = AsyncValue.data(map);
    await _persist(map);
  }

  /// Restore [action] to its default chord list.
  Future<void> resetAction(BoardActionKey action) async {
    final defaults = defaultBoardShortcuts();
    await setChords(
      action,
      List.unmodifiable(defaults[action] ?? const <KeyChord>[]),
    );
  }
}

void _upgradeDefaultLikeOverrides(
  Map<BoardActionKey, List<KeyChord>> overrides,
  Map<BoardActionKey, List<KeyChord>> defaults,
) {
  final copy = overrides[BoardActionKey.copyPgn];
  if (_sameChords(copy, _oldCopyPgnDefault)) {
    overrides[BoardActionKey.copyPgn] = defaults[BoardActionKey.copyPgn]!;
  }

  final flip = overrides[BoardActionKey.flipBoard];
  if (_sameChords(flip, _oldFlipBoardDefault)) {
    overrides[BoardActionKey.flipBoard] = defaults[BoardActionKey.flipBoard]!;
  }

  // Pre-2026-05 builds bound Arrow Up / Arrow Down to firstMove / lastMove.
  // The new default reserves the vertical arrows for variation switching
  // and moves jump-to-start / jump-to-end onto Ctrl+Arrow Left / Right.
  // Migrate users who never customised these so the arrows pick up the
  // new behaviour automatically.
  final first = overrides[BoardActionKey.firstMove];
  if (_sameChords(first, _oldFirstMoveDefault)) {
    overrides[BoardActionKey.firstMove] = defaults[BoardActionKey.firstMove]!;
  }
  final last = overrides[BoardActionKey.lastMove];
  if (_sameChords(last, _oldLastMoveDefault)) {
    overrides[BoardActionKey.lastMove] = defaults[BoardActionKey.lastMove]!;
  }

  // Pre-2026-05 builds bound Cmd/Ctrl+S to "Save PGN to file…". The new
  // default reserves that chord for "Save game to library…" and moves
  // file-save to Cmd/Ctrl+Shift+S. Migrate users still on the old default
  // so they get the new behaviour without losing the file-save chord.
  final save = overrides[BoardActionKey.savePgnFile];
  if (_sameChords(save, _oldSavePgnFileDefault) &&
      !overrides.containsKey(BoardActionKey.saveGameToLibrary)) {
    overrides[BoardActionKey.savePgnFile] =
        defaults[BoardActionKey.savePgnFile]!;
    overrides[BoardActionKey.saveGameToLibrary] =
        defaults[BoardActionKey.saveGameToLibrary]!;
  }

  final firstMove = overrides[BoardActionKey.firstMove];
  if (_sameChords(firstMove, _oldFirstMoveDefault)) {
    overrides[BoardActionKey.firstMove] = defaults[BoardActionKey.firstMove]!;
  }

  final lastMove = overrides[BoardActionKey.lastMove];
  if (_sameChords(lastMove, _oldLastMoveDefault)) {
    overrides[BoardActionKey.lastMove] = defaults[BoardActionKey.lastMove]!;
  }

  final rightRailPrevious = overrides[BoardActionKey.rightRailPreviousTab];
  if (_sameChords(rightRailPrevious, _oldRightRailPreviousTabDefault)) {
    overrides[BoardActionKey.rightRailPreviousTab] =
        defaults[BoardActionKey.rightRailPreviousTab]!;
  }
  final rightRailNext = overrides[BoardActionKey.rightRailNextTab];
  if (_sameChords(rightRailNext, _oldRightRailNextTabDefault)) {
    overrides[BoardActionKey.rightRailNextTab] =
        defaults[BoardActionKey.rightRailNextTab]!;
  }
}

bool _sameChords(List<KeyChord>? a, List<KeyChord> b) {
  if (a == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final left = a[i];
    final right = b[i];
    if (!left.matches(right) || left.crossPlatform != right.crossPlatform) {
      return false;
    }
  }
  return true;
}

final _oldFirstMoveDefault = <KeyChord>[
  KeyChord(keyId: LogicalKeyboardKey.home.keyId),
  KeyChord(keyId: LogicalKeyboardKey.arrowUp.keyId),
];

final _oldLastMoveDefault = <KeyChord>[
  KeyChord(keyId: LogicalKeyboardKey.end.keyId),
  KeyChord(keyId: LogicalKeyboardKey.arrowDown.keyId),
];

final _oldRightRailPreviousTabDefault = <KeyChord>[
  KeyChord(
    keyId: LogicalKeyboardKey.arrowLeft.keyId,
    meta: true,
    crossPlatform: true,
  ),
];

final _oldRightRailNextTabDefault = <KeyChord>[
  KeyChord(
    keyId: LogicalKeyboardKey.arrowRight.keyId,
    meta: true,
    crossPlatform: true,
  ),
];

final _oldCopyPgnDefault = <KeyChord>[
  KeyChord(
    keyId: LogicalKeyboardKey.keyC.keyId,
    meta: true,
    shift: true,
    crossPlatform: true,
  ),
];

final _oldFlipBoardDefault = <KeyChord>[
  KeyChord(keyId: LogicalKeyboardKey.keyF.keyId),
];

final _oldSavePgnFileDefault = <KeyChord>[
  KeyChord(
    keyId: LogicalKeyboardKey.keyS.keyId,
    meta: true,
    crossPlatform: true,
  ),
  KeyChord(keyId: LogicalKeyboardKey.keyS.keyId, ctrl: true),
];
