import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Source contracts deliberately pin the owning surfaces, not shared tabs or
// menu implementations. Runtime pointer/layout QA follows independent review.
String source(String path) =>
    File(path).readAsStringSync().replaceAll('\r', '');

String section(String text, String start, String end) =>
    text.substring(text.indexOf(start), text.indexOf(end, text.indexOf(start)));

void main() {
  test('Board owns one menu trigger in its notation metadata/ECO header', () {
    final board = source('lib/desktop/panes/board_pane.dart');
    final area = section(
      board,
      'class _BoardArea ',
      'class _BoardEvalBarSurface',
    );
    expect(area, isNot(contains('_BoardMoreActionsButton')));
    expect(board.split('headerTrailing: _BoardMoreActionsButton(').length, 2);
    expect(board, contains('onPressed: openBoardContextMenu'));
    expect(board, contains('headerTrailing: headerTrailing'));
    final notation = source('lib/desktop/widgets/notation_ladder_view.dart');
    final header = section(
      notation,
      'class _Header ',
      'class _PgnMetadataHeader',
    );
    expect(header, contains('Expanded(child: _PgnMetadataHeader'));
    expect(
      header.indexOf('trailing!]'),
      greaterThan(header.indexOf('Expanded(child: _PgnMetadataHeader')),
    );
    expect(notation, contains('trailing: widget.headerTrailing'));
    expect(board, contains("message: 'More board actions'"));
    expect(board, contains('onPress: _openMenu'));
  });

  test('Board player bars reserve no width for relocated controls', () {
    final board = source('lib/desktop/panes/board_pane.dart');
    final area = section(
      board,
      'class _BoardArea ',
      'class _BoardEvalBarSurface',
    );
    // Pin both callers, including PiP/focus branches: an empty SizedBox still
    // consumes its width AND the shared header's conditional 8px trailing gap.
    expect(area.split('DesktopBoardPlayerHeader(').length, 3);
    for (final side in ['top', 'bottom']) {
      final playerHeader = section(
        area,
        'name: ${side}Name,',
        'activeGameId: activeGameId,',
      );
      expect(playerHeader, contains('trailingControl: null,'));
      expect(playerHeader, isNot(contains('SizedBox')));
      expect(playerHeader, isNot(contains('_focusButtonSize')));
      expect(playerHeader, isNot(contains('_resizeHandleSize')));
    }
    // Keep the shared capability: other callers may still supply real chrome.
    expect(board, contains('final Widget? trailingControl;'));
    expect(
      board,
      contains(
        'if (trailingControl != null) ...[\n'
        '            const SizedBox(width: 8),\n'
        '            trailingControl!,',
      ),
    );
  });

  test('resize grip stays in board corner, outside player bars and export', () {
    final board = source('lib/desktop/panes/board_pane.dart');
    final area = section(
      board,
      'class _BoardArea ',
      'class _BoardEvalBarSurface',
    );
    expect(area.split('BoardResizeHandle(').length, 2);
    expect(area, contains('bottom: bottomRowHeight + _BoardArea.headerGap'));
    expect(area, contains('dimension: 16'));
    expect(area, contains('pictureInPicture || boardSize < 16'));
    expect(area, contains('hasHeaders && !focusMode && resizeHandle != null'));
    expect(
      area,
      isNot(contains('bottom: (bottomRowHeight - _resizeHandleSize)')),
    );
    // The grip remains the overlay sibling after the export boundary, not a
    // child of the chessboard/annotation gesture tree.
    expect(
      area.indexOf('child: resizeHandle'),
      greaterThan(area.indexOf('key: shareCaptureKey')),
    );
    expect(area, contains('cornerRight - 16'));
    expect(area, contains('cornerBottom - 16'));
    expect(area, contains('.contains(event.localPosition)'));
    expect(area, contains('onResize: onBoardSizeChanged'));
    expect(area, contains('onResizeEnd: onBoardSizeChangeEnd'));
    expect(area, contains('onReset: onBoardSizeReset'));
    expect(area, contains('maxSize: math.min(vLimit, _maxDesktopBoardSize)'));
  });

  test(
    'only Board event rail tabs lose underline, retaining selected semantics',
    () {
      final rail = source('lib/desktop/widgets/event_games_table.dart');
      final tab = section(
        rail,
        'class _BoardEventRailTabState ',
        'class _EventRoundHeaderItem ',
      );
      expect(tab, contains("_BoardEventRailView.games => 'Games'"));
      expect(tab, contains("_BoardEventRailView.standings => 'Standings'"));
      // Both text-tab siblings use the same quiet selected foreground, not
      // invented icons or Games-only styling. Hover/focus stays discoverable.
      expect(tab, contains('widget.selected || _hovered || _focused'));
      expect(
        tab,
        contains('widget.selected ? FontWeight.w700 : FontWeight.w600'),
      );
      expect(tab, isNot(contains('Icon(')));
      expect(tab, contains('selected: widget.selected'));
      expect(tab, contains('label: _label'));
      expect(tab, contains('LogicalKeyboardKey.enter'));
      expect(tab, contains('LogicalKeyboardKey.space'));
      expect(tab, contains('return KeyEventResult.ignored'));
      expect(tab, contains('color: active ? kWhiteColor : kWhiteColor70'));
      expect(tab, isNot(contains('bottom: 0')));
      expect(tab, isNot(contains('height: 2')));
      expect(tab, isNot(contains('TextDecoration.underline')));
    },
  );

  test('event rail keeps team names in matchup header, not player rows', () {
    final rail = source('lib/desktop/widgets/event_games_table.dart');
    final playerLine = section(
      rail,
      'class _EventGamePlayerLine ',
      'Color _eventGameResultColor',
    );
    expect(playerLine, contains('_PlayerCell('));
    expect(playerLine, isNot(contains('whiteTeam')));
    expect(playerLine, isNot(contains('blackTeam')));
    final matchupHeader = section(
      rail,
      'class _EventMatchupHeader ',
      'enum _GameRowAction',
    );
    expect(matchupHeader, contains('title'));
  });

  test('round header always reserves date and start time beside its name', () {
    final rail = source('lib/desktop/widgets/event_games_table.dart');
    final header = section(
      rail,
      'class _EventRoundHeaderState ',
      'class _EventMatchupHeader',
    );
    expect(header, contains("DateFormat('d MMM yyyy HH:mm')"));
    expect(header, isNot(contains('group.status != RoundStatus.upcoming')));
    expect(header, contains('Expanded('));
    expect(header, contains('group.title'));
    expect(header, contains('overflow: TextOverflow.ellipsis'));
    expect(
      header.indexOf('group.title'),
      lessThan(header.indexOf('if (subtitle.isNotEmpty)')),
    );
  });

  test('board menu clears matching Game Report state before user output', () {
    final board = source('lib/desktop/panes/board_pane.dart');
    final reset = section(
      board,
      'Future<void> resetEditsAction()',
      'void openBoardSettingsTab()',
    );
    expect(reset, contains('completedReportForCurrentGame() != null'));
    expect(reset, contains('gameReport.value = null'));
    expect(reset, contains('reportRunning.value = false'));
    expect(reset, contains('reportResetRevision.value++'));
    expect(reset, contains('reportRevealState.value = GameReportRevealState('));
    expect(board, contains('reportResetRevision: reportResetRevision.value'));

    final engine = source('lib/desktop/widgets/engine_panel.dart');
    expect(engine, contains('final int reportResetRevision'));
    expect(
      engine,
      contains('oldWidget.reportResetRevision != widget.reportResetRevision'),
    );
    expect(engine, contains('_reportController.invalidate()'));
    // Automatic reports were removed: a reset or a new game re-keys the panel
    // and clears the stale notice, and nothing re-requests a report on its
    // own. A cleared report only comes back from the cache on an explicit
    // request.
    final update = section(
      engine,
      'void didUpdateWidget(covariant EnginePanel oldWidget)',
      'String? _fingerprint(',
    );
    expect(update, contains('_gameFingerprint = nextFingerprint'));
    expect(update, contains('_requestNotice = null'));
    expect(update, isNot(contains('_analyze(')));
    expect(update, isNot(contains('_reportCoordinator.request(')));
  });

  test('board menu exposes Clear analysis only through optional callback', () {
    final menu = source('lib/desktop/widgets/board_context_menu.dart');
    expect(menu, contains('VoidCallback? onClearAnalysis'));
    expect(menu, contains('if (onClearAnalysis != null)'));
    expect(menu, contains("label: 'Clear analysis'"));
    expect(menu, contains('BoardActionKey.clearAnalysis'));
    expect(menu, contains('onClearAnalysis?.call()'));
  });
}
