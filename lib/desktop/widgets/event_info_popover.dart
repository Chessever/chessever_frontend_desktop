import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/location_service_provider.dart';

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
        popoverBuilder: (context, _) => EventInfoBody(headers: widget.headers),
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

/// Renders the full PGN header set for a game: curated, labeled rows for the
/// well-known tags first, then a generic row per remaining tag so imported
/// metadata is never silently invisible. Shared by the board's event-info
/// popover and the Library "Game info" dialog.
class EventInfoBody extends ConsumerWidget {
  const EventInfoBody({super.key, required this.headers});

  final Map<String, String> headers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    final event = eventInfoDisplayEvent(headers);
    if (event != null) {
      rows.add(_HeaderRow(label: 'Event', value: event));
    }
    // Online events carry a platform host (lichess.org, chess.com, ...) in
    // `Site` rather than a physical place. Mirrors the mobile board's
    // event-info sheet: never surface that raw third-party URL — show a
    // clean "Online" + platform name row instead.
    final site = headers['Site']?.trim() ?? '';
    if (site.isNotEmpty && site != '?') {
      final locationService = ref.read(locationServiceProvider);
      final isLink = site.startsWith('http://') || site.startsWith('https://');
      if (locationService.isOnlinePlatform(site)) {
        rows.add(
          _HeaderRow(
            label: 'Online',
            value: locationService.prettifyPlatformName(site),
            trailing: isLink ? _CopyIconButton(value: site) : null,
          ),
        );
      } else {
        rows.add(
          _HeaderRow(
            label: 'Site',
            value: site,
            trailing: isLink ? _CopyIconButton(value: site) : null,
          ),
        );
      }
    }
    addIfPresent('Date', 'Date');
    addIfPresent('Round', 'Round');
    addIfPresent('Result', 'Result');
    addIfPresent('Opening', 'Opening');
    addIfPresent('ECO', 'ECO');
    addIfPresent('Time control', 'TimeControl');
    addIfPresent('Termination', 'Termination');
    addIfPresent('Annotator', 'Annotator');

    for (final extra in eventInfoExtraHeaderEntries(headers)) {
      rows.add(
        _HeaderRow(label: eventInfoTagLabel(extra.key), value: extra.value),
      );
    }

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
String? eventInfoDisplayEvent(Map<String, String> headers) {
  final broadcastName = eventInfoDisplayBroadcastName(headers);
  if (broadcastName != null) return broadcastName;

  final value = headers['Event']?.trim();
  if (value != null && value.isNotEmpty && value != '?') return value;
  return null;
}

@visibleForTesting
String? eventInfoDisplayBroadcastName(Map<String, String> headers) {
  for (final key in const <String>[
    'BroadcastName',
    'Broadcast Name',
    'GroupBroadcastName',
    'Group Broadcast Name',
  ]) {
    final value = headers[key]?.trim();
    if (value != null && value.isNotEmpty && value != '?') return value;
  }
  return null;
}

/// Tags already rendered by the curated rows above, so the generic
/// "everything else" section doesn't repeat them.
const _curatedHeaderKeys = <String>{
  'White',
  'Black',
  'WhiteElo',
  'BlackElo',
  'WhiteTitle',
  'BlackTitle',
  'Event',
  'Site',
  'Date',
  'Round',
  'Result',
  'Opening',
  'ECO',
  'TimeControl',
  'Termination',
  'Annotator',
  'BroadcastName',
  'Broadcast Name',
  'GroupBroadcastName',
  'Group Broadcast Name',
};

/// Board-state keys the app stores alongside real PGN tags; never PGN
/// metadata the user wrote, so never shown.
final _internalHeaderKeys = <String>{
  ChessGame.metadataIsLiveKey,
  ChessGame.metadataAllowMainlineExtensionKey,
  ChessGame.metadataGameEndingPlyIndexKey,
};

/// Every header not covered by the curated rows and not app-internal,
/// alphabetized. Placeholder values (`""`, `"?"`) are dropped.
@visibleForTesting
List<MapEntry<String, String>> eventInfoExtraHeaderEntries(
  Map<String, String> headers,
) {
  final entries = <MapEntry<String, String>>[];
  for (final entry in headers.entries) {
    final key = entry.key.trim();
    if (key.isEmpty ||
        _curatedHeaderKeys.contains(key) ||
        _internalHeaderKeys.contains(key) ||
        key.startsWith('ChessEver')) {
      continue;
    }
    final value = entry.value.trim();
    if (value.isEmpty || value == '?') continue;
    entries.add(MapEntry(key, value));
  }
  entries.sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
  return entries;
}

final _tagWordBoundary = RegExp(
  r'(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])',
);

/// "WhiteFideId" → "White FIDE ID", "UTCTime" → "UTC Time" — readable labels
/// for tags without a curated row.
@visibleForTesting
String eventInfoTagLabel(String tag) {
  return tag
      .replaceAll('_', ' ')
      .split(_tagWordBoundary)
      .map(
        (word) => switch (word.toLowerCase()) {
          'fide' => 'FIDE',
          'id' => 'ID',
          'eco' => 'ECO',
          'utc' => 'UTC',
          'url' => 'URL',
          'fen' => 'FEN',
          'pgn' => 'PGN',
          _ => word,
        },
      )
      .join(' ');
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
  const _HeaderRow({required this.label, required this.value, this.trailing});

  final String label;
  final String value;
  final Widget? trailing;

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
        if (trailing != null) ...[const SizedBox(width: 6), trailing!],
      ],
    );
  }
}

/// Tiny copy-to-clipboard affordance appended after a link value.
class _CopyIconButton extends StatelessWidget {
  const _CopyIconButton({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: 'Copy link',
      child: SizedBox.square(
        dimension: 18,
        child: FButton.icon(
          style: FButtonStyle.ghost(
            (style) => style.copyWith(
              contentStyle:
                  (content) => content.copyWith(padding: EdgeInsets.zero),
            ),
          ),
          onPress: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (!context.mounted) return;
            showDesktopToast(context, 'Link copied to clipboard');
          },
          child: const Icon(Icons.copy_rounded, size: 12, color: kWhiteColor70),
        ),
      ),
    );
  }
}
