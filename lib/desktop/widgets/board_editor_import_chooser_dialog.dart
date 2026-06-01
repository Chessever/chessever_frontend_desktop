import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/services/board_editor_pgn_import.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/theme/app_theme.dart';

Future<BoardEditorPgnImportEntry?> showBoardEditorImportChooserDialog({
  required BuildContext context,
  required BoardEditorPgnImportResult result,
}) {
  return showFDialog<BoardEditorPgnImportEntry>(
    context: context,
    builder:
        (context, _, animation) => _BoardEditorImportChooserDialog(
          result: result,
          animation: animation,
        ),
  );
}

class _BoardEditorImportChooserDialog extends StatefulWidget {
  const _BoardEditorImportChooserDialog({
    required this.result,
    required this.animation,
  });

  final BoardEditorPgnImportResult result;
  final Animation<double> animation;

  @override
  State<_BoardEditorImportChooserDialog> createState() =>
      _BoardEditorImportChooserDialogState();
}

class _BoardEditorImportChooserDialogState
    extends State<_BoardEditorImportChooserDialog> {
  late final TextEditingController _searchController;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.result.entries
        .where((entry) => boardEditorImportEntryMatches(entry, _query))
        .toList(growable: false);

    return FDialog.raw(
      animation: widget.animation,
      constraints: const BoxConstraints(maxWidth: 700, maxHeight: 620),
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DialogHeader(result: widget.result),
              const SizedBox(height: 14),
              DesktopSearchField(
                controller: _searchController,
                autofocus: true,
                hintText: 'Search entries, players, events, files',
                onChanged: (value) => setState(() => _query = value),
                onClear: () => setState(() => _query = ''),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 360,
                child:
                    entries.isEmpty
                        ? const _EmptyResults()
                        : ListView.separated(
                          itemCount: entries.length,
                          separatorBuilder:
                              (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            return _ImportEntryButton(entry: entry);
                          },
                        ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FButton(
                  style: _secondaryButtonStyle(),
                  prefix: const Icon(Icons.close_rounded, size: 16),
                  onPress: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({required this.result});

  final BoardEditorPgnImportResult result;

  @override
  Widget build(BuildContext context) {
    final count = result.entries.length;
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: kPrimaryColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kPrimaryColor.withValues(alpha: 0.36)),
          ),
          child: const Icon(
            Icons.account_tree_outlined,
            size: 18,
            color: kPrimaryColor,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose entry',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${result.sourceLabel} · $count '
                '${count == 1 ? 'entry' : 'entries'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kLightGreyColor, fontSize: 12),
              ),
            ],
          ),
        ),
        const _NotImportedBadge(),
      ],
    );
  }
}

class _ImportEntryButton extends StatelessWidget {
  const _ImportEntryButton({required this.entry});

  final BoardEditorPgnImportEntry entry;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: _entryButtonStyle(),
      mainAxisSize: MainAxisSize.max,
      onPress: () => Navigator.of(context).pop(entry),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kBlack3Color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kDividerColor),
            ),
            child: Icon(
              entry.game.mainline.isEmpty
                  ? Icons.my_location_rounded
                  : Icons.sports_esports_rounded,
              size: 16,
              color: kPrimaryColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  boardEditorImportEntryTitle(entry),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  boardEditorImportEntrySubtitle(entry),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kLightGreyColor,
                    fontSize: 11.5,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _KindPill(label: boardEditorImportEntryKindLabel(entry)),
        ],
      ),
    );
  }
}

class _KindPill extends StatelessWidget {
  const _KindPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: kPrimaryColor.withValues(alpha: 0.34)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: kPrimaryColor,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _NotImportedBadge extends StatelessWidget {
  const _NotImportedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: kDividerColor),
      ),
      child: const Text(
        'Not imported',
        style: TextStyle(
          color: kLightGreyColor,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'No matching entries',
        style: TextStyle(color: kLightGreyColor, fontSize: 13),
      ),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _secondaryButtonStyle() {
  return FButtonStyle.outline(
    (style) => style.copyWith(
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            textStyle: FWidgetStateMap({
              WidgetState.any: const TextStyle(
                color: kWhiteColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            }),
          ),
    ),
  );
}

FBaseButtonStyle Function(FButtonStyle style) _entryButtonStyle() {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: kBlack3Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.36)),
        ),
        WidgetState.focused: BoxDecoration(
          color: kBlack3Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.58)),
        ),
        WidgetState.any: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kDividerColor),
        ),
      }),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          ),
    ),
  );
}

@visibleForTesting
bool boardEditorImportEntryMatches(
  BoardEditorPgnImportEntry entry,
  String query,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final metadata = entry.game.metadata;
  final fields = <String>[
    boardEditorImportEntryTitle(entry),
    boardEditorImportEntrySubtitle(entry),
    boardEditorImportEntryKindLabel(entry),
    entry.sourceLabel,
    entry.sourcePath ?? '',
    entry.sourceRelativePath ?? '',
    metadata['White']?.toString() ?? '',
    metadata['Black']?.toString() ?? '',
    metadata['Event']?.toString() ?? '',
    metadata['Site']?.toString() ?? '',
    metadata['Opening']?.toString() ?? '',
    metadata['ECO']?.toString() ?? '',
    metadata['FEN']?.toString() ?? '',
  ];
  return fields.any((field) => field.toLowerCase().contains(q));
}

@visibleForTesting
String boardEditorImportEntryKindLabel(BoardEditorPgnImportEntry entry) {
  return entry.game.mainline.isEmpty ? 'POSITION' : 'PGN';
}

@visibleForTesting
String boardEditorImportEntryTitle(BoardEditorPgnImportEntry entry) {
  final metadata = entry.game.metadata;
  final isPosition = entry.game.mainline.isEmpty;
  final event = _cleanMetadata(metadata['Event']);
  if (isPosition && event != null) return event;

  final white = _cleanMetadata(metadata['White']) ?? 'White';
  final black = _cleanMetadata(metadata['Black']) ?? 'Black';
  return '$white vs $black';
}

@visibleForTesting
String boardEditorImportEntrySubtitle(BoardEditorPgnImportEntry entry) {
  final metadata = entry.game.metadata;
  final parts = <String>[
    if (entry.sourceRelativePath?.trim().isNotEmpty == true)
      entry.sourceRelativePath!.trim()
    else
      entry.sourceLabel,
    if (_cleanMetadata(metadata['Event']) case final event?) event,
    if (_cleanMetadata(metadata['Date']) case final date?) date,
    if (_cleanMetadata(metadata['ECO']) case final eco?) eco,
    if (_cleanMetadata(metadata['Result']) case final result?) result,
  ];
  return parts.toSet().join(' · ');
}

String? _cleanMetadata(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty || text == '?') return null;
  return text;
}
