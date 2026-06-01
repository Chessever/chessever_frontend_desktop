import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';

/// Forui-styled "i" button + popover that surfaces the PGN headers for
/// the active game (event, site, date, round, players, ratings, ECO,
/// time control). Mirrors the mobile board's event-info sheet, adapted
/// to a desktop popover.
class EventInfoPopover extends StatefulWidget {
  const EventInfoPopover({
    super.key,
    required this.headers,
    this.openTrigger = 0,
  });

  /// Trimmed-string PGN header map for the active game. Empty entries
  /// are filtered out at render time so the popover doesn't show empty
  /// rows for missing fields.
  final Map<String, String> headers;

  /// Increment this counter from the parent (e.g. when a bound keyboard
  /// shortcut fires) to programmatically toggle the popover. Same key
  /// → no-op; any change → the popover opens or closes. Default 0
  /// means the parent isn't using the trigger.
  final int openTrigger;

  @override
  State<EventInfoPopover> createState() => _EventInfoPopoverState();
}

class _EventInfoPopoverState extends State<EventInfoPopover>
    with SingleTickerProviderStateMixin {
  late final FPopoverController _controller = FPopoverController(vsync: this);

  @override
  void didUpdateWidget(covariant EventInfoPopover old) {
    super.didUpdateWidget(old);
    final hasAny = widget.headers.values.any((v) => v.trim().isNotEmpty);
    final isVisible =
        _controller.status == AnimationStatus.completed ||
        _controller.status == AnimationStatus.forward;
    // Headers became empty (game cleared) — close the popover so the
    // user doesn't end up stuck looking at a stale info card with no
    // way to dismiss via the now-disabled keyboard shortcut.
    if (!hasAny && isVisible) {
      _controller.hide();
      return;
    }
    if (old.openTrigger != widget.openTrigger && hasAny) {
      _controller.toggle();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasAny = widget.headers.values.any((v) => v.trim().isNotEmpty);
    return FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: _controller,
        popoverBuilder: (context, _) => _Body(headers: widget.headers),
        child: DesktopTooltip(
          message: hasAny ? 'Event info (I)' : 'No event info available',
          child: FButton.icon(
            onPress: hasAny ? _controller.toggle : null,
            child: Icon(
              Icons.info_outline_rounded,
              color:
                  hasAny
                      ? kWhiteColor70
                      : kLightGreyColor.withValues(alpha: 0.45),
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.headers});

  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final rows = <_HeaderRow>[];

    void addIfPresent(String label, String key) {
      final value = headers[key]?.trim() ?? '';
      if (value.isEmpty) return;
      rows.add(_HeaderRow(label: label, value: value));
    }

    final whiteName = headers['White']?.trim() ?? '';
    final blackName = headers['Black']?.trim() ?? '';
    final whiteElo = headers['WhiteElo']?.trim() ?? '';
    final blackElo = headers['BlackElo']?.trim() ?? '';
    final whiteTitle = headers['WhiteTitle']?.trim() ?? '';
    final blackTitle = headers['BlackTitle']?.trim() ?? '';

    if (whiteName.isNotEmpty || blackName.isNotEmpty) {
      rows.add(
        _HeaderRow(
          label: 'White',
          value: _composePlayerLine(whiteName, whiteElo, whiteTitle),
        ),
      );
      rows.add(
        _HeaderRow(
          label: 'Black',
          value: _composePlayerLine(blackName, blackElo, blackTitle),
        ),
      );
    }

    addIfPresent('Event', 'Event');
    addIfPresent('Site', 'Site');
    addIfPresent('Date', 'Date');
    addIfPresent('Round', 'Round');
    addIfPresent('Result', 'Result');
    addIfPresent('Opening', 'Opening');
    addIfPresent('ECO', 'ECO');
    addIfPresent('Time control', 'TimeControl');
    addIfPresent('Termination', 'Termination');
    addIfPresent('Annotator', 'Annotator');

    return Container(
      width: 360,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.event_note_rounded, size: 14, color: kPrimaryColor),
              SizedBox(width: 8),
              Text(
                'Event info',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            const Text(
              'This game has no PGN headers.',
              style: TextStyle(color: kLightGreyColor, fontSize: 12),
            )
          else
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: 6),
              rows[i],
            ],
        ],
      ),
    );
  }

  String _composePlayerLine(String name, String elo, String title) {
    final buf = StringBuffer();
    if (title.isNotEmpty) buf.write('$title ');
    buf.write(name.isEmpty ? '?' : name);
    if (elo.isNotEmpty) buf.write(' ($elo)');
    return buf.toString();
  }
}

@visibleForTesting
List<ContextMenuButtonItem> eventInfoContextMenuButtonItems(
  EditableTextState editableTextState,
) {
  return [
    for (final item in editableTextState.contextMenuButtonItems)
      if (item.type == ContextMenuButtonType.copy)
        item.copyWith(
          onPressed: () {
            final selected = eventInfoSelectedText(
              editableTextState.currentTextEditingValue,
            );
            if (selected == null) return;
            Clipboard.setData(ClipboardData(text: selected));
            editableTextState.hideToolbar();
          },
        )
      else
        item,
  ];
}

@visibleForTesting
String? eventInfoSelectedText(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || selection.isCollapsed) return null;
  final start = selection.start.clamp(0, value.text.length).toInt();
  final end = selection.end.clamp(0, value.text.length).toInt();
  if (start >= end) return null;
  return value.text.substring(start, end);
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            contextMenuBuilder: (context, editableTextState) {
              return AdaptiveTextSelectionToolbar.buttonItems(
                anchors: editableTextState.contextMenuAnchors,
                buttonItems: eventInfoContextMenuButtonItems(editableTextState),
              );
            },
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
