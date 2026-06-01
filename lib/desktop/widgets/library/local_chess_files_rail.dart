import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/library/library_database_drag_payload.dart';
import 'package:chessever/theme/app_theme.dart';

enum _RegisteredLocalEntryAction { open, remove }

class LocalChessFilesRailSection extends ConsumerStatefulWidget {
  const LocalChessFilesRailSection({
    super.key,
    required this.selectedPath,
    required this.onSelect,
  });

  final String? selectedPath;
  final ValueChanged<String> onSelect;

  @override
  ConsumerState<LocalChessFilesRailSection> createState() =>
      _LocalChessFilesRailSectionState();
}

class _LocalChessFilesRailSectionState
    extends ConsumerState<LocalChessFilesRailSection> {
  final Set<String> _expandedPaths = <String>{};
  String? _sourceId;

  void _syncExpandedState(LocalChessSource? source) {
    if (source == null) {
      _sourceId = null;
      _expandedPaths.clear();
      return;
    }

    if (_sourceId != source.id) {
      _sourceId = source.id;
      _expandedPaths
        ..clear()
        ..add(source.root.path);
    }

    final selectedTrail = source.breadcrumbNodesForPath(widget.selectedPath);
    for (final node in selectedTrail) {
      if (node is LocalChessFolderNode) _expandedPaths.add(node.path);
    }
  }

  void _toggleFolder(LocalChessFolderNode folder) {
    setState(() {
      if (!_expandedPaths.remove(folder.path)) {
        _expandedPaths.add(folder.path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(localChessLibraryProvider);
    final source = state.source;
    final registeredEntries = ref.watch(localLibraryRegistryProvider).entries;
    _syncExpandedState(source);

    Future<void> openRegisteredEntry(LocalLibraryEntry entry) async {
      final opened = await ref
          .read(localChessLibraryProvider.notifier)
          .openPaths(<String>[entry.path], sourceLabel: entry.displayName);
      if (!opened) return;
      final selected = ref.read(localChessLibraryProvider).selectedPath;
      if (selected != null) widget.onSelect(selected);
    }

    Future<void> removeRegisteredEntry(LocalLibraryEntry entry) async {
      await ref
          .read(localLibraryRegistryProvider.notifier)
          .unregister(entry.path);
      final activeSource = ref.read(localChessLibraryProvider).source;
      if (activeSource != null && activeSource.paths.contains(entry.path)) {
        ref.read(localChessLibraryProvider.notifier).clear();
      }
    }

    Future<void> openFolder() async {
      final opened =
          await ref.read(localChessLibraryProvider.notifier).pickFolder();
      if (!opened) return;
      final selected = ref.read(localChessLibraryProvider).selectedPath;
      if (selected != null) widget.onSelect(selected);
    }

    Future<void> openFiles() async {
      final opened =
          await ref.read(localChessLibraryProvider.notifier).pickFiles();
      if (!opened) return;
      final selected = ref.read(localChessLibraryProvider).selectedPath;
      if (selected != null) widget.onSelect(selected);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 14),
        _LocalGroupHeader(
          count:
              source == null ? registeredEntries.length : source.root.fileCount,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: DesktopTooltip(
                  message: 'Open a folder without importing it',
                  child: FButton(
                    style: FButtonStyle.outline(),
                    onPress: state.isScanning ? null : openFolder,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.folder_open_outlined, size: 13),
                        SizedBox(width: 6),
                        Text('Folder'),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              DesktopTooltip(
                message: 'Open local chess files without importing them',
                child: FButton.icon(
                  onPress: state.isScanning ? null : openFiles,
                  child: const Icon(Icons.file_open_outlined, size: 15),
                ),
              ),
            ],
          ),
        ),
        if (state.isScanning)
          const _LocalStatusRow(
            icon: Icons.sync_rounded,
            label: 'Scanning local files…',
          )
        else if (state.error != null)
          _LocalStatusRow(
            icon: Icons.error_outline_rounded,
            label: state.error!,
            isError: true,
          )
        else if (showRegisteredLocalEntriesForRail(
          source: source,
          entries: registeredEntries,
        ))
          _RegisteredLocalEntryRows(
            entries: registeredEntries,
            selectedPath: widget.selectedPath,
            onSelect: openRegisteredEntry,
            onRemove: removeRegisteredEntry,
          )
        else if (source == null)
          const _LocalStatusRow(
            icon: Icons.account_tree_outlined,
            label: 'Open a folder or drop one here.',
          )
        else
          _LocalNodeRows(
            node: source.root,
            selectedPath: widget.selectedPath,
            expandedPaths: _expandedPaths,
            onSelect: (path) {
              ref.read(localChessLibraryProvider.notifier).selectPath(path);
              widget.onSelect(path);
            },
            onToggle: _toggleFolder,
          ),
      ],
    );
  }
}

bool showRegisteredLocalEntriesForRail({
  required LocalChessSource? source,
  required List<LocalLibraryEntry> entries,
}) {
  return source == null && entries.isNotEmpty;
}

class _LocalGroupHeader extends StatelessWidget {
  const _LocalGroupHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 6),
      child: Row(
        children: [
          const Text(
            'LOCAL FILES',
            style: TextStyle(
              color: kLightGreyColor,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: TextStyle(
              color: kLightGreyColor.withValues(alpha: 0.65),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _LocalStatusRow extends StatelessWidget {
  const _LocalStatusRow({
    required this.icon,
    required this.label,
    this.isError = false,
  });

  final IconData icon;
  final String label;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: isError ? kRedColor : kLightGreyColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isError ? kRedColor : kWhiteColor70,
                fontSize: 11.5,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RegisteredLocalEntryRows extends StatelessWidget {
  const _RegisteredLocalEntryRows({
    required this.entries,
    required this.selectedPath,
    required this.onSelect,
    required this.onRemove,
  });

  final List<LocalLibraryEntry> entries;
  final String? selectedPath;
  final ValueChanged<LocalLibraryEntry> onSelect;
  final ValueChanged<LocalLibraryEntry> onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final entry in entries)
          _RegisteredLocalEntryRow(
            entry: entry,
            selected: entry.path == selectedPath,
            onTap: () => onSelect(entry),
            onRemove: () => onRemove(entry),
          ),
      ],
    );
  }
}

class _RegisteredLocalEntryRow extends StatelessWidget {
  const _RegisteredLocalEntryRow({
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onRemove,
  });

  final LocalLibraryEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    Future<void> showMenu(Offset position) async {
      final picked = await showDesktopContextMenu<_RegisteredLocalEntryAction>(
        context: context,
        position: position,
        width: 230,
        entries: const [
          DesktopContextMenuItem(
            value: _RegisteredLocalEntryAction.open,
            icon: Icons.table_rows_outlined,
            label: 'Open database',
          ),
          DesktopContextMenuDivider(),
          DesktopContextMenuItem(
            value: _RegisteredLocalEntryAction.remove,
            icon: Icons.delete_outline_rounded,
            label: 'Remove from My Databases',
            destructive: true,
          ),
        ],
      );
      switch (picked) {
        case _RegisteredLocalEntryAction.open:
          onTap();
        case _RegisteredLocalEntryAction.remove:
          onRemove();
        case null:
          break;
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 1, 8, 1),
      child: GestureDetector(
        onSecondaryTapDown:
            (details) => unawaited(showMenu(details.globalPosition)),
        child: Draggable<LibraryDatabaseDragPayload>(
          data: LibraryDatabaseDragPayload.local(
            localPath: entry.path,
            title: entry.displayName,
          ),
          feedback: _LocalDragFeedback(title: entry.displayName),
          childWhenDragging: Opacity(
            opacity: 0.55,
            child: _RegisteredLocalEntryButton(
              entry: entry,
              selected: selected,
              onTap: onTap,
            ),
          ),
          child: _RegisteredLocalEntryButton(
            entry: entry,
            selected: selected,
            onTap: onTap,
          ),
        ),
      ),
    );
  }
}

class _RegisteredLocalEntryButton extends StatelessWidget {
  const _RegisteredLocalEntryButton({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final LocalLibraryEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? kPrimaryColor : kWhiteColor70;
    return FButton(
      style: _localRailNodeButtonStyle(selected: selected),
      mainAxisSize: MainAxisSize.max,
      onPress: onTap,
      child: Row(
        children: [
          Icon(Icons.folder_rounded, size: 14, color: fg),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entry.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  entry.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kLightGreyColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LocalNodeRows extends StatelessWidget {
  const _LocalNodeRows({
    required this.node,
    required this.selectedPath,
    required this.expandedPaths,
    required this.onSelect,
    required this.onToggle,
    this.depth = 0,
  });

  final LocalChessNode node;
  final String? selectedPath;
  final Set<String> expandedPaths;
  final ValueChanged<String> onSelect;
  final ValueChanged<LocalChessFolderNode> onToggle;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final folder =
        node is LocalChessFolderNode ? node as LocalChessFolderNode : null;
    final hasChildren = folder != null && folder.children.isNotEmpty;
    final expanded = folder != null && expandedPaths.contains(folder.path);
    final rows = <Widget>[
      _LocalNodeRow(
        node: node,
        selected: node.path == selectedPath,
        depth: depth,
        hasChildren: hasChildren,
        expanded: expanded,
        onTap: () => onSelect(node.path),
        onToggle: folder == null ? null : () => onToggle(folder),
      ),
    ];
    if (folder != null && expanded) {
      for (final child in folder.children) {
        rows.add(
          _LocalNodeRows(
            node: child,
            selectedPath: selectedPath,
            expandedPaths: expandedPaths,
            onSelect: onSelect,
            onToggle: onToggle,
            depth: depth + 1,
          ),
        );
      }
    }
    return Column(children: rows);
  }
}

class _LocalNodeRow extends StatefulWidget {
  const _LocalNodeRow({
    required this.node,
    required this.selected,
    required this.depth,
    required this.hasChildren,
    required this.expanded,
    required this.onTap,
    required this.onToggle,
  });

  final LocalChessNode node;
  final bool selected;
  final int depth;
  final bool hasChildren;
  final bool expanded;
  final VoidCallback onTap;
  final VoidCallback? onToggle;

  @override
  State<_LocalNodeRow> createState() => _LocalNodeRowState();
}

class _LocalNodeRowState extends State<_LocalNodeRow> {
  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final selected = widget.selected;
    final fg = selected ? kPrimaryColor : kWhiteColor70;
    final icon = switch (node) {
      LocalChessFolderNode() => Icons.folder_rounded,
      LocalChessFileNode(status: LocalChessFileStatus.parsed) =>
        Icons.description_outlined,
      LocalChessFileNode(status: LocalChessFileStatus.noGames) =>
        Icons.article_outlined,
      LocalChessFileNode(status: LocalChessFileStatus.unsupported) =>
        Icons.lock_outline_rounded,
      LocalChessFileNode(status: LocalChessFileStatus.failed) =>
        Icons.error_outline_rounded,
      _ => Icons.insert_drive_file_outlined,
    };
    final meta = switch (node) {
      LocalChessFolderNode(:final gameCount, :final fileCount) =>
        '$fileCount files · ${localChessEntryCountLabel(gameCount)}',
      LocalChessFileNode(status: LocalChessFileStatus.parsed, :final games) =>
        localChessEntryCountLabel(games.length),
      LocalChessFileNode(status: LocalChessFileStatus.unsupported) =>
        'recognized',
      LocalChessFileNode(status: LocalChessFileStatus.failed) => 'failed',
      LocalChessFileNode() => 'no entries',
      _ => '',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 1, 8, 1),
      child: Row(
        children: [
          SizedBox(width: widget.depth * 14.0),
          SizedBox(
            width: 18,
            height: 26,
            child:
                widget.hasChildren
                    ? FButton.icon(
                      style: _disclosureButtonStyle(fg),
                      onPress: widget.onToggle,
                      child: Icon(
                        widget.expanded
                            ? Icons.keyboard_arrow_down_rounded
                            : Icons.keyboard_arrow_right_rounded,
                      ),
                    )
                    : null,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Draggable<LibraryDatabaseDragPayload>(
              data: LibraryDatabaseDragPayload.local(
                localPath: node.path,
                title: node.name,
              ),
              feedback: _LocalDragFeedback(title: node.name),
              childWhenDragging: Opacity(
                opacity: 0.55,
                child: _LocalNodeButton(
                  node: node,
                  selected: selected,
                  icon: icon,
                  meta: meta,
                  onTap: widget.onTap,
                ),
              ),
              child: _LocalNodeButton(
                node: node,
                selected: selected,
                icon: icon,
                meta: meta,
                onTap: widget.onTap,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LocalNodeButton extends StatelessWidget {
  const _LocalNodeButton({
    required this.node,
    required this.selected,
    required this.icon,
    required this.meta,
    required this.onTap,
  });

  final LocalChessNode node;
  final bool selected;
  final IconData icon;
  final String meta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? kPrimaryColor : kWhiteColor70;
    return FButton(
      style: _localRailNodeButtonStyle(selected: selected),
      mainAxisSize: MainAxisSize.max,
      onPress: onTap,
      child: Row(
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              node.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            meta,
            style: const TextStyle(color: kLightGreyColor, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _LocalDragFeedback extends StatelessWidget {
  const _LocalDragFeedback({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: kBlack3Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.55)),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 14),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_rounded, size: 15, color: kPrimaryColor),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _localRailNodeButtonStyle({
  required bool selected,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color:
              selected ? kPrimaryColor.withValues(alpha: 0.12) : kBlack3Color,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.45)
                    : Colors.transparent,
          ),
        ),
        WidgetState.focused: BoxDecoration(
          color: kBlack3Color,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.70)),
        ),
        WidgetState.any: BoxDecoration(
          color:
              selected
                  ? kPrimaryColor.withValues(alpha: 0.10)
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.35)
                    : Colors.transparent,
          ),
        ),
      }),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          ),
    ),
  );
}

FBaseButtonStyle Function(FButtonStyle style) _disclosureButtonStyle(
  Color foreground,
) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: foreground.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(4),
        ),
        WidgetState.any: BoxDecoration(borderRadius: BorderRadius.circular(4)),
      }),
      iconContentStyle:
          (content) => content.copyWith(
            padding: EdgeInsets.zero,
            iconStyle: FWidgetStateMap({
              WidgetState.hovered | WidgetState.pressed: IconThemeData(
                color: foreground,
                size: 16,
              ),
              WidgetState.any: IconThemeData(color: foreground, size: 16),
            }),
          ),
    ),
  );
}
