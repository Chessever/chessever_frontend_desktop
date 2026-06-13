import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_pgn_append.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/library/library_save_to_folder_dialog.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';

class LocalChessFilesView extends HookConsumerWidget {
  const LocalChessFilesView({
    super.key,
    required this.selectedPath,
    required this.onSelectPath,
    this.stateOverride,
    this.onRefreshOverride,
  });

  final String selectedPath;
  final ValueChanged<String> onSelectPath;
  final LocalChessLibraryState? stateOverride;
  final Future<void> Function()? onRefreshOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watchedState = ref.watch(localChessLibraryProvider);
    final state = stateOverride ?? watchedState;
    final source = state.source;
    final node = source?.nodeForPath(selectedPath);
    final searchController = useTextEditingController();
    final query = useState<String>('');

    Future<void> pickFolder() async {
      final opened =
          await ref.read(localChessLibraryProvider.notifier).pickFolder();
      if (!opened) return;
      final selected = ref.read(localChessLibraryProvider).selectedPath;
      if (selected != null) onSelectPath(selected);
    }

    Future<void> pickFiles() async {
      final opened =
          await ref.read(localChessLibraryProvider.notifier).pickFiles();
      if (!opened) return;
      final selected = ref.read(localChessLibraryProvider).selectedPath;
      if (selected != null) onSelectPath(selected);
    }

    if (state.isScanning) {
      return const _LocalLoading();
    }
    if (state.error != null) {
      return _LocalEmpty(
        icon: Icons.error_outline_rounded,
        title: 'Could not open local files',
        message: state.error!,
        onOpenFolder: pickFolder,
        onOpenFiles: pickFiles,
      );
    }
    if (source == null || node == null) {
      return _LocalEmpty(
        icon: Icons.account_tree_outlined,
        title: 'Open local chess files',
        message:
            'Browse a folder, choose chess files, or drop files here. Games '
            'and positions stay on disk until you explicitly save them to '
            'your ChessEver library.',
        onOpenFolder: pickFolder,
        onOpenFiles: pickFiles,
      );
    }

    final selectedDatabase = selectedLocalChessDatabaseFile(node);
    final isBrowsingFolder =
        node is LocalChessFolderNode && selectedDatabase == null;
    final allGames = selectedDatabase?.games ?? const <LocalChessGame>[];
    final databaseTitle = selectedDatabase?.name ?? source.label;
    final filtered = useMemoized(() {
      final q = query.value.trim().toLowerCase();
      if (q.isEmpty) return allGames;
      return allGames.where((game) => _matches(game, q)).toList();
    }, [allGames, query.value]);

    void selectLocalPath(String path) {
      ref.read(localChessLibraryProvider.notifier).selectPath(path);
      onSelectPath(path);
    }

    Future<void> saveVisible() async {
      if (filtered.isEmpty) return;
      // Scanner builds light ChessGames with empty mainlines. Re-parse the
      // raw PGN on a worker isolate so saved rows carry full move data.
      final hydrated = await compute(_hydrateLocalGamesForSave, filtered);
      if (!context.mounted) return;
      final outcome = await showLibrarySaveToFolderDialog(
        context: context,
        ref: ref,
        games: hydrated,
        sourceLabel: databaseTitle,
      );
      if (outcome == null || !outcome.didSave || !context.mounted) return;
      showDesktopToast(context, outcome.toToastMessage());
    }

    Future<void> pasteIntoLocalDatabase() async {
      final target = selectedDatabase;
      if (target == null) {
        showDesktopToast(
          context,
          'Open a single local PGN database before pasting.',
          error: true,
        );
        return;
      }
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clipboard?.text?.trim();
      if (text == null || text.isEmpty) {
        if (context.mounted) {
          showDesktopToast(
            context,
            'Clipboard is empty — copy a PGN first.',
            error: true,
          );
        }
        return;
      }
      try {
        final count = await appendPgnTextToLocalChessFile(
          filePath: target.path,
          text: text,
        );
        if (!context.mounted) return;
        if (count <= 0) {
          showDesktopToast(
            context,
            'Clipboard does not contain a PGN with moves.',
            error: true,
          );
          return;
        }
        if (onRefreshOverride != null) {
          await onRefreshOverride!();
        } else {
          await ref.read(localChessLibraryProvider.notifier).refresh();
        }
        if (!context.mounted) return;
        ref.read(localChessLibraryProvider.notifier).selectPath(target.path);
        onSelectPath(target.path);
        showDesktopToast(
          context,
          'Pasted $count ${count == 1 ? 'game' : 'games'} into ${target.name}.',
        );
      } catch (e) {
        if (!context.mounted) return;
        showDesktopToast(
          context,
          'Could not paste into local PGN: $e',
          error: true,
        );
      }
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyV, control: true):
            pasteIntoLocalDatabase,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            pasteIntoLocalDatabase,
      },
      child: Focus(
        autofocus: true,
        child: FTheme(
          data: FThemes.zinc.dark,
          child: Container(
            color: kBackgroundColor,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _LocalHeader(
                  source: source,
                  node: node,
                  onOpenFolder: pickFolder,
                  onOpenFiles: pickFiles,
                  onRefresh: () {
                    if (onRefreshOverride != null) {
                      unawaited(onRefreshOverride!());
                      return;
                    }
                    unawaited(
                      ref.read(localChessLibraryProvider.notifier).refresh(),
                    );
                  },
                  onSave: filtered.isEmpty ? null : saveVisible,
                  onSelectPath: selectLocalPath,
                ),
                const FDivider(),
                if (!isBrowsingFolder)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: DesktopSearchField(
                            controller: searchController,
                            hintText:
                                'Search this database — players, events, openings, ECO',
                            onChanged: (value) => query.value = value,
                            onClear: () => query.value = '',
                          ),
                        ),
                        const SizedBox(width: 12),
                        _LocalCountPill(
                          label:
                              '${filtered.length} / ${allGames.length} '
                              '${allGames.length == 1 ? 'entry' : 'entries'}',
                        ),
                      ],
                    ),
                  ),
                if (isBrowsingFolder && node.children.isNotEmpty)
                  _LocalChildrenStrip(
                    folder: node,
                    selectedPath: selectedPath,
                    onSelect: selectLocalPath,
                  ),
                Expanded(
                  child:
                      isBrowsingFolder
                          ? _LocalFolderBrowseState(folder: node)
                          : allGames.isEmpty
                          ? _LocalNodeEmpty(node: node)
                          : filtered.isEmpty
                          ? _LocalEmpty(
                            icon: Icons.search_off_rounded,
                            title: 'No local entries match "$query"',
                            message:
                                'Try another player, event, opening, or file.',
                            onOpenFolder: pickFolder,
                            onOpenFiles: pickFiles,
                          )
                          : _LocalGamesTable(
                            databaseTitle: databaseTitle,
                            database: selectedDatabase,
                            games: filtered,
                            databaseGames: allGames,
                            onRefresh: onRefreshOverride,
                            onSelectPath: onSelectPath,
                          ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LocalHeader extends StatelessWidget {
  const _LocalHeader({
    required this.source,
    required this.node,
    required this.onOpenFolder,
    required this.onOpenFiles,
    required this.onRefresh,
    required this.onSave,
    required this.onSelectPath,
  });

  final LocalChessSource source;
  final LocalChessNode node;
  final VoidCallback onOpenFolder;
  final VoidCallback onOpenFiles;
  final VoidCallback onRefresh;
  final VoidCallback? onSave;
  final ValueChanged<String> onSelectPath;

  @override
  Widget build(BuildContext context) {
    final selectedDatabase = selectedLocalChessDatabaseFile(node);
    final isDatabaseView = selectedDatabase != null;
    final (gameCount, fileCount, unsupportedCount) = switch (node) {
      LocalChessFolderNode(
        :final gameCount,
        :final fileCount,
        :final unsupportedCount,
      ) =>
        (gameCount, fileCount, unsupportedCount),
      LocalChessFileNode(:final games, :final isPlayable) => (
        games.length,
        1,
        isPlayable ? 0 : 1,
      ),
      _ => (0, 0, 0),
    };
    final countLabel =
        selectedDatabase == null
            ? '$fileCount files · ${localChessEntryCountLabel(gameCount)}'
            : localChessEntryCountLabel(selectedDatabase.games.length);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kPrimaryColor.withValues(alpha: 0.32)),
            ),
            child: Icon(_iconFor(node), size: 19, color: kPrimaryColor),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        node.name.isEmpty ? source.label : node.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (isDatabaseView) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: kBlack2Color,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: kDividerColor),
                        ),
                        child: const Text(
                          'My database',
                          style: TextStyle(
                            color: kWhiteColor70,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (!isDatabaseView) ...[
                  const SizedBox(height: 6),
                  _Breadcrumb(
                    source: source,
                    node: node,
                    onSelectPath: onSelectPath,
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  '$countLabel${unsupportedCount == 0 ? '' : ' · $unsupportedCount recognized only'}',
                  style: const TextStyle(
                    color: kLightGreyColor,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (!isDatabaseView) ...[
            _HeaderAction(
              tooltip: 'Open another local folder',
              icon: Icons.folder_open_outlined,
              onPress: onOpenFolder,
            ),
            const SizedBox(width: 4),
            _HeaderAction(
              tooltip: 'Open local chess files',
              icon: Icons.file_open_outlined,
              onPress: onOpenFiles,
            ),
            const SizedBox(width: 4),
            _HeaderAction(
              tooltip: 'Rescan this local source',
              icon: Icons.refresh_rounded,
              onPress: onRefresh,
            ),
            const SizedBox(width: 8),
          ],
          DesktopTooltip(
            message:
                onSave == null
                    ? 'No parsed local entries here'
                    : 'Save visible local entries to your cloud library',
            child: FButton(
              style: FButtonStyle.primary(),
              onPress: onSave,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.library_add_outlined, size: 14),
                  SizedBox(width: 7),
                  Text('Save To Cloud'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.tooltip,
    required this.icon,
    required this.onPress,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: tooltip,
      child: FButton.icon(onPress: onPress, child: Icon(icon, size: 16)),
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({
    required this.source,
    required this.node,
    required this.onSelectPath,
  });

  final LocalChessSource source;
  final LocalChessNode node;
  final ValueChanged<String> onSelectPath;

  @override
  Widget build(BuildContext context) {
    final nodes = source.breadcrumbNodesForPath(node.path);
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < nodes.length; i++) ...[
          if (i > 0)
            const Icon(
              Icons.chevron_right_rounded,
              size: 13,
              color: kLightGreyColor,
            ),
          _BreadcrumbSegment(
            label: i == 0 ? source.label : nodes[i].name,
            isCurrent: i == nodes.length - 1,
            onPress: () => onSelectPath(nodes[i].path),
          ),
        ],
      ],
    );
  }
}

class _BreadcrumbSegment extends StatelessWidget {
  const _BreadcrumbSegment({
    required this.label,
    required this.isCurrent,
    required this.onPress,
  });

  final String label;
  final bool isCurrent;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final text = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );

    if (isCurrent) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: DefaultTextStyle.merge(
          style: const TextStyle(
            color: kWhiteColor70,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
          child: text,
        ),
      );
    }

    return FButton(
      style: _breadcrumbButtonStyle(),
      mainAxisSize: MainAxisSize.min,
      onPress: onPress,
      child: text,
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _breadcrumbButtonStyle() {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: kBlack3Color,
          borderRadius: BorderRadius.circular(5),
        ),
        WidgetState.any: BoxDecoration(borderRadius: BorderRadius.circular(5)),
      }),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            textStyle: FWidgetStateMap({
              WidgetState.hovered | WidgetState.pressed: const TextStyle(
                color: kWhiteColor,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
              WidgetState.any: const TextStyle(
                color: kLightGreyColor,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            }),
          ),
    ),
  );
}

class _LocalCountPill extends StatelessWidget {
  const _LocalCountPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: kDividerColor),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: kWhiteColor70,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _LocalChildrenStrip extends StatelessWidget {
  const _LocalChildrenStrip({
    required this.folder,
    required this.selectedPath,
    required this.onSelect,
  });

  final LocalChessFolderNode folder;
  final String selectedPath;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 112,
      child: ListView.separated(
        physics: const DesktopScrollPhysics(),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 12),
        itemCount: folder.children.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final child = folder.children[i];
          return _LocalChildCard(
            node: child,
            selected: child.path == selectedPath,
            onTap: () => onSelect(child.path),
          );
        },
      ),
    );
  }
}

class _LocalChildCard extends StatelessWidget {
  const _LocalChildCard({
    required this.node,
    required this.selected,
    required this.onTap,
  });

  final LocalChessNode node;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final meta = switch (node) {
      LocalChessFolderNode(:final fileCount, :final gameCount) =>
        '$fileCount files · ${localChessEntryCountLabel(gameCount)}',
      LocalChessFileNode(status: LocalChessFileStatus.parsed, :final games) =>
        localChessEntryCountLabel(games.length),
      LocalChessFileNode(:final message) => message ?? 'recognized only',
      _ => '',
    };
    return SizedBox(
      width: 220,
      child: FButton(
        style: _localChildCardButtonStyle(selected: selected),
        mainAxisSize: MainAxisSize.max,
        onPress: onTap,
        child: Row(
          children: [
            Icon(_iconFor(node), size: 18, color: kPrimaryColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    meta,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 11,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _localChildCardButtonStyle({
  required bool selected,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: kBlack3Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.55)
                    : kWhiteColor.withValues(alpha: 0.12),
          ),
        ),
        WidgetState.focused: BoxDecoration(
          color: kBlack3Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.70)),
        ),
        WidgetState.any: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.45)
                    : kDividerColor,
          ),
        ),
      }),
      contentStyle:
          (content) => content.copyWith(padding: const EdgeInsets.all(12)),
    ),
  );
}

enum _LocalGameRowAction { copyPgn, saveToCloud, delete }

class _LocalGamesTable extends HookConsumerWidget {
  const _LocalGamesTable({
    required this.databaseTitle,
    required this.database,
    required this.games,
    required this.databaseGames,
    required this.onRefresh,
    required this.onSelectPath,
  });

  final String databaseTitle;
  final LocalChessFileNode? database;
  final List<LocalChessGame> games;
  final List<LocalChessGame> databaseGames;
  final Future<void> Function()? onRefresh;
  final ValueChanged<String> onSelectPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useScrollController();
    final focusNode = useFocusNode(debugLabel: 'local-pgn-games-table');
    final selectedId = useState<String?>(null);
    final selectedIds = useState<Set<String>>(<String>{});
    final selectionAnchor = useState<int?>(null);
    final selectionExtent = useState<int?>(null);
    final visibleIds = games.map((game) => game.id).toList(growable: false);
    final clampedSelectedIds = _clampLocalSelection(
      selectedIds.value,
      visibleIds,
    );
    final effectiveSelectedIds =
        clampedSelectedIds.isNotEmpty
            ? clampedSelectedIds
            : selectedId.value == null
            ? const <String>{}
            : <String>{selectedId.value!};
    final selectedGames = games
        .where((game) => effectiveSelectedIds.contains(game.id))
        .toList(growable: false);

    useEffect(() {
      if (games.isEmpty) {
        selectedId.value = null;
        selectedIds.value = <String>{};
        selectionAnchor.value = null;
        selectionExtent.value = null;
      } else if (selectedId.value != null &&
          !visibleIds.contains(selectedId.value)) {
        selectedId.value = null;
        selectedIds.value = clampedSelectedIds;
        selectionAnchor.value = null;
        selectionExtent.value = null;
      } else if (clampedSelectedIds.length != selectedIds.value.length) {
        selectedIds.value = clampedSelectedIds;
      }
      return null;
    }, [games]);

    void selectIndex(int index, {bool toggle = false, bool range = false}) {
      if (games.isEmpty) return;
      final next = index.clamp(0, games.length - 1).toInt();
      final id = games[next].id;
      if (range) {
        final anchor = selectionAnchor.value ?? next;
        final start = anchor < next ? anchor : next;
        final end = anchor < next ? next : anchor;
        selectedIds.value = {for (var i = start; i <= end; i++) games[i].id};
        selectedId.value = id;
        selectionExtent.value = next;
      } else if (toggle) {
        final updated = Set<String>.of(clampedSelectedIds);
        if (!updated.add(id)) updated.remove(id);
        selectedIds.value = updated;
        selectedId.value = id;
        selectionAnchor.value = next;
        selectionExtent.value = next;
      } else {
        selectedId.value = id;
        selectedIds.value = <String>{};
        selectionAnchor.value = next;
        selectionExtent.value = next;
      }
      focusNode.requestFocus();
    }

    Future<void> copySelectedGames({List<LocalChessGame>? scope}) async {
      final gamesToCopy = scope ?? selectedGames;
      final parts = gamesToCopy
          .map((game) => game.rawPgn.trim())
          .where(
            (pgn) => pgn.isNotEmpty && appendableLocalPgnParts(pgn).isNotEmpty,
          )
          .toList(growable: false);
      if (parts.isEmpty) {
        showDesktopToast(
          context,
          'No selected PGN with moves available to copy.',
          error: true,
        );
        return;
      }
      await Clipboard.setData(ClipboardData(text: '${parts.join('\n\n')}\n'));
      if (!context.mounted) return;
      final skipped = gamesToCopy.length - parts.length;
      showDesktopToast(
        context,
        skipped == 0
            ? 'Copied ${parts.length} ${parts.length == 1 ? 'game' : 'games'} as PGN.'
            : 'Copied ${parts.length} ${parts.length == 1 ? 'game' : 'games'}; $skipped had no PGN moves available.',
      );
    }

    Future<void> saveSelectedGames({List<LocalChessGame>? scope}) async {
      final gamesToSave = scope ?? selectedGames;
      if (gamesToSave.isEmpty) return;
      final hydrated = await compute(_hydrateLocalGamesForSave, gamesToSave);
      if (!context.mounted) return;
      final outcome = await showLibrarySaveToFolderDialog(
        context: context,
        ref: ref,
        games: hydrated,
        sourceLabel: databaseTitle,
      );
      if (outcome == null || !outcome.didSave || !context.mounted) return;
      showDesktopToast(context, outcome.toToastMessage());
    }

    Future<void> deleteSelectedGames({List<LocalChessGame>? scope}) async {
      final target = database;
      final gamesToDelete = scope ?? selectedGames;
      if (target == null || gamesToDelete.isEmpty) return;
      final confirmed = await showLocalPgnDeleteGamesConfirmation(
        context,
        count: gamesToDelete.length,
        databaseName: target.name,
      );
      if (!confirmed) return;
      try {
        final removed = await removeLocalPgnGamesFromFile(
          filePath: target.path,
          indexesInFile: gamesToDelete.map((game) => game.indexInFile).toSet(),
        );
        if (!context.mounted) return;
        if (onRefresh != null) {
          await onRefresh!();
        } else {
          await ref.read(localChessLibraryProvider.notifier).refresh();
        }
        if (!context.mounted) return;
        ref.read(localChessLibraryProvider.notifier).selectPath(target.path);
        onSelectPath(target.path);
        selectedIds.value = <String>{};
        selectedId.value = null;
        showDesktopToast(
          context,
          'Deleted $removed ${removed == 1 ? 'game' : 'games'} from ${target.name}.',
        );
      } catch (e) {
        if (!context.mounted) return;
        showDesktopToast(
          context,
          'Could not delete from local PGN: $e',
          error: true,
        );
      }
    }

    Future<void> openRowMenu(LocalChessGame game, Offset position) async {
      final rowIndex = games.indexWhere((row) => row.id == game.id);
      if (rowIndex < 0) return;
      final rowScope =
          effectiveSelectedIds.contains(game.id)
              ? selectedGames
              : <LocalChessGame>[game];
      if (!effectiveSelectedIds.contains(game.id)) {
        selectIndex(rowIndex);
      }
      final action = await showDesktopContextMenu<_LocalGameRowAction>(
        context: context,
        position: position,
        width: 220,
        entries: [
          const DesktopContextMenuItem(
            value: _LocalGameRowAction.copyPgn,
            icon: Icons.content_copy_rounded,
            label: 'Copy PGN',
          ),
          const DesktopContextMenuItem(
            value: _LocalGameRowAction.saveToCloud,
            icon: Icons.library_add_outlined,
            label: 'Save To Cloud',
          ),
          const DesktopContextMenuDivider(),
          DesktopContextMenuItem(
            value: _LocalGameRowAction.delete,
            icon: Icons.delete_outline_rounded,
            label: 'Delete game',
            destructive: true,
            enabled: database != null,
          ),
        ],
      );
      if (action == null || !context.mounted) return;
      switch (action) {
        case _LocalGameRowAction.copyPgn:
          unawaited(copySelectedGames(scope: rowScope));
        case _LocalGameRowAction.saveToCloud:
          unawaited(saveSelectedGames(scope: rowScope));
        case _LocalGameRowAction.delete:
          unawaited(deleteSelectedGames(scope: rowScope));
      }
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyC, control: true):
            () => unawaited(copySelectedGames()),
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
            () => unawaited(copySelectedGames()),
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): () {
          selectedIds.value = visibleIds.toSet();
          if (games.isNotEmpty) selectedId.value = games.last.id;
        },
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () {
          selectedIds.value = visibleIds.toSet();
          if (games.isNotEmpty) selectedId.value = games.last.id;
        },
        const SingleActivator(LogicalKeyboardKey.delete):
            () => unawaited(deleteSelectedGames()),
        const SingleActivator(LogicalKeyboardKey.backspace):
            () => unawaited(deleteSelectedGames()),
      },
      child: Focus(
        focusNode: focusNode,
        canRequestFocus: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            children: [
              const _LocalGamesHeaderRow(),
              Expanded(
                child: Scrollbar(
                  controller: controller,
                  thumbVisibility: false,
                  child: ListView.builder(
                    controller: controller,
                    physics: const DesktopScrollPhysics(),
                    itemExtent: _kLocalGameRowHeight,
                    itemCount: games.length,
                    itemBuilder: (context, index) {
                      final game = games[index];
                      return _LocalGamesDataRow(
                        key: ValueKey('local-game-table-${game.id}'),
                        index: index,
                        game: game,
                        selected: effectiveSelectedIds.contains(game.id),
                        onTapDown: (details) {
                          final keys =
                              HardwareKeyboard.instance.logicalKeysPressed;
                          selectIndex(
                            index,
                            toggle:
                                keys.contains(LogicalKeyboardKey.controlLeft) ||
                                keys.contains(
                                  LogicalKeyboardKey.controlRight,
                                ) ||
                                keys.contains(LogicalKeyboardKey.metaLeft) ||
                                keys.contains(LogicalKeyboardKey.metaRight),
                            range:
                                keys.contains(LogicalKeyboardKey.shiftLeft) ||
                                keys.contains(LogicalKeyboardKey.shiftRight),
                          );
                        },
                        onDoubleTap: () {
                          selectIndex(index);
                          _openLocalGame(
                            ref,
                            game,
                            sourceLabel: databaseTitle,
                            databaseGames: databaseGames,
                          );
                        },
                        onSecondaryTapUp:
                            (details) => unawaited(
                              openRowMenu(game, details.globalPosition),
                            ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const double _kLocalGameRowHeight = 34;

Set<String> _clampLocalSelection(Set<String> selectedIds, List<String> rowIds) {
  if (selectedIds.isEmpty) return const <String>{};
  final visible = rowIds.toSet();
  return selectedIds.where(visible.contains).toSet();
}

class _LocalGamesHeaderRow extends StatelessWidget {
  const _LocalGamesHeaderRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 27,
      decoration: const BoxDecoration(
        color: kBackgroundColor,
        border: Border(bottom: BorderSide(color: kDividerColor, width: 1)),
      ),
      child: const Row(
        children: [
          SizedBox(width: 54, child: _LocalHeaderCell('#', alignEnd: true)),
          Expanded(flex: 22, child: _LocalHeaderCell('WHITE')),
          SizedBox(width: 64, child: _LocalHeaderCell('ELO W', alignEnd: true)),
          Expanded(flex: 22, child: _LocalHeaderCell('BLACK')),
          SizedBox(width: 64, child: _LocalHeaderCell('ELO B', alignEnd: true)),
          SizedBox(width: 70, child: _LocalHeaderCell('RESULT')),
          SizedBox(width: 62, child: _LocalHeaderCell('ECO')),
          Expanded(flex: 18, child: _LocalHeaderCell('OPENING')),
          Expanded(flex: 16, child: _LocalHeaderCell('EVENT')),
          SizedBox(width: 92, child: _LocalHeaderCell('DATE')),
        ],
      ),
    );
  }
}

class _LocalHeaderCell extends StatelessWidget {
  const _LocalHeaderCell(this.label, {this.alignEnd = false});

  final String label;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Align(
        alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
        child: Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: kWhiteColor70,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

class _LocalGamesDataRow extends StatelessWidget {
  const _LocalGamesDataRow({
    super.key,
    required this.index,
    required this.game,
    required this.selected,
    required this.onTapDown,
    required this.onDoubleTap,
    required this.onSecondaryTapUp,
  });

  final int index;
  final LocalChessGame game;
  final bool selected;
  final GestureTapDownCallback onTapDown;
  final VoidCallback onDoubleTap;
  final GestureTapUpCallback onSecondaryTapUp;

  @override
  Widget build(BuildContext context) {
    final md = game.game.metadata;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: onTapDown,
      onSecondaryTapUp: onSecondaryTapUp,
      onDoubleTap: onDoubleTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color:
              selected
                  ? kPrimaryColor.withValues(alpha: 0.16)
                  : kBackgroundColor,
          border: const Border(
            bottom: BorderSide(color: kDividerColor, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            SizedBox(width: 54, child: _LocalNumberCell(value: index + 1)),
            Expanded(flex: 22, child: _LocalTextCell(_playerName(md, 'White'))),
            SizedBox(
              width: 64,
              child: _LocalNumberCell(value: _rating(md, 'WhiteElo')),
            ),
            Expanded(flex: 22, child: _LocalTextCell(_playerName(md, 'Black'))),
            SizedBox(
              width: 64,
              child: _LocalNumberCell(value: _rating(md, 'BlackElo')),
            ),
            SizedBox(width: 70, child: _LocalTextCell(_result(md))),
            SizedBox(width: 62, child: _LocalTextCell(_meta(md, 'ECO'))),
            Expanded(flex: 18, child: _LocalTextCell(_opening(md))),
            Expanded(flex: 16, child: _LocalTextCell(_event(md))),
            SizedBox(width: 92, child: _LocalTextCell(_date(md))),
          ],
        ),
      ),
    );
  }
}

class _LocalTextCell extends StatelessWidget {
  const _LocalTextCell(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    final display = value.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        display.isEmpty || display == '?' ? '-' : display,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: kWhiteColor,
          fontSize: 12,
          height: 1.1,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _LocalNumberCell extends StatelessWidget {
  const _LocalNumberCell({required this.value});

  final int? value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(
          value == null || value! <= 0 ? '-' : value.toString(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 12,
            height: 1.1,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

String _meta(Map<String, dynamic> md, String key) =>
    (md[key]?.toString().trim() ?? '');

String _playerName(Map<String, dynamic> md, String key) {
  final name = _meta(md, key);
  if (name.isEmpty || name == '?') return key;
  return name;
}

int? _rating(Map<String, dynamic> md, String key) {
  final value = int.tryParse(_meta(md, key));
  return value == null || value <= 0 ? null : value;
}

String _result(Map<String, dynamic> md) {
  final result = _meta(md, 'Result').replaceAll('½', '1/2');
  return result.isEmpty ? '*' : result;
}

String _opening(Map<String, dynamic> md) {
  final opening = _meta(md, 'Opening');
  if (opening.isNotEmpty && opening != '?') return opening;
  return _meta(md, 'Variation');
}

String _event(Map<String, dynamic> md) {
  final event = _meta(md, 'Event');
  return event.isEmpty || event == '?' ? _meta(md, 'Site') : event;
}

String _date(Map<String, dynamic> md) {
  final date = _meta(md, 'Date');
  if (date.isEmpty || date == '?') return '';
  return date;
}

class _LocalNodeEmpty extends StatelessWidget {
  const _LocalNodeEmpty({required this.node});

  final LocalChessNode node;

  @override
  Widget build(BuildContext context) {
    final message = switch (node) {
      LocalChessFolderNode(:final scanError) when scanError != null =>
        'Some files could not be read: $scanError',
      LocalChessFolderNode(:final fileCount) when fileCount == 0 =>
        'This folder has no recognized chess files. Drop or choose a folder '
            'that contains $localChessEmptyFolderFormatsMessage',
      LocalChessFolderNode() =>
        'This folder has recognized chess files, but no playable entries.',
      LocalChessFileNode(:final message) =>
        message ?? 'No playable entries were found in this file.',
      _ => 'No local chess entries were found here.',
    };
    return _LocalEmpty(
      icon: _iconFor(node),
      title: 'No playable entries',
      message: message,
    );
  }
}

class _LocalFolderBrowseState extends StatelessWidget {
  const _LocalFolderBrowseState({required this.folder});

  final LocalChessFolderNode folder;

  @override
  Widget build(BuildContext context) {
    final playableDatabases = folder.playableDatabaseCount;
    if (folder.fileCount == 0 || playableDatabases == 0) {
      return _LocalNodeEmpty(node: folder);
    }

    return _LocalEmpty(
      icon: Icons.account_tree_outlined,
      title: 'Choose a database',
      message:
          'This folder contains $playableDatabases playable '
          '${playableDatabases == 1 ? 'database' : 'databases'}. '
          'Select one from the folder tree or cards above.',
    );
  }
}

class _LocalEmpty extends StatelessWidget {
  const _LocalEmpty({
    required this.icon,
    required this.title,
    required this.message,
    this.onOpenFolder,
    this.onOpenFiles,
  });

  final IconData icon;
  final String title;
  final String message;
  final VoidCallback? onOpenFolder;
  final VoidCallback? onOpenFiles;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kBlack2Color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: kPrimaryColor.withValues(alpha: 0.25),
                  ),
                ),
                child: Icon(icon, size: 28, color: kPrimaryColor),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              if (onOpenFolder != null || onOpenFiles != null) ...[
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (onOpenFolder != null)
                      FButton(
                        style: FButtonStyle.primary(),
                        onPress: onOpenFolder,
                        child: const Text('Open folder'),
                      ),
                    if (onOpenFolder != null && onOpenFiles != null)
                      const SizedBox(width: 8),
                    if (onOpenFiles != null)
                      FButton(
                        style: FButtonStyle.outline(),
                        onPress: onOpenFiles,
                        child: const Text('Open files'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalLoading extends StatelessWidget {
  const _LocalLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(kPrimaryColor),
            ),
          ),
          SizedBox(height: 12),
          Text(
            'Scanning local chess files…',
            style: TextStyle(color: kWhiteColor70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

bool _matches(LocalChessGame game, String query) {
  if (game.fileName.toLowerCase().contains(query)) return true;
  if (game.sourceRelativePath.toLowerCase().contains(query)) return true;
  for (final value in game.game.metadata.values) {
    if (value is String && value.toLowerCase().contains(query)) return true;
  }
  return false;
}

Future<bool> showLocalPgnDeleteGamesConfirmation(
  BuildContext context, {
  required int count,
  required String databaseName,
}) async {
  final confirmed = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Delete local PGN games',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder:
        (ctx, _, _) => FTheme(
          data: FThemes.zinc.dark,
          child: Center(
            child: Container(
              width: 440,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              decoration: BoxDecoration(
                color: kBlack2Color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kDividerColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.delete_forever_outlined,
                        color: Color(0xFFEB5757),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Delete $count ${count == 1 ? 'game' : 'games'}?',
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'This rewrites "$databaseName" on this computer and removes the selected PGN ${count == 1 ? 'entry' : 'entries'}. This cannot be undone.',
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      DesktopDialogButton(
                        label: 'Cancel',
                        onPress: () => Navigator.of(ctx).pop(false),
                      ),
                      const SizedBox(width: 8),
                      DesktopDialogButton(
                        label: 'Delete',
                        tone: DesktopDialogButtonTone.danger,
                        onPress: () => Navigator.of(ctx).pop(true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
  );
  return confirmed == true;
}

void _openLocalGame(
  WidgetRef ref,
  LocalChessGame localGame, {
  required String sourceLabel,
  required List<LocalChessGame> databaseGames,
  bool focus = true,
}) {
  openBoardGameTab(
    ref,
    _boardArgsForLocalGame(
      localGame,
      sourceLabel: sourceLabel,
      databaseGames: databaseGames,
    ),
    reuseExisting: false,
    focus: focus,
  );
}

BoardTabGameArgs _boardArgsForLocalGame(
  LocalChessGame localGame, {
  required String sourceLabel,
  required List<LocalChessGame> databaseGames,
}) {
  final game = localGame.game;
  final md = game.metadata;
  String s(String key) => (md[key]?.toString() ?? '').trim();
  int rating(String key) => int.tryParse(s(key)) ?? 0;
  int? fideId(String key) {
    final value = rating(key);
    return value > 0 ? value : null;
  }

  return BoardTabGameArgs(
    pgn: localGame.rawPgn,
    label: localGame.title,
    whiteName: s('White'),
    blackName: s('Black'),
    whiteFederation:
        s('WhiteFederation').isNotEmpty ? s('WhiteFederation') : s('WhiteFed'),
    blackFederation:
        s('BlackFederation').isNotEmpty ? s('BlackFederation') : s('BlackFed'),
    whiteTitle: s('WhiteTitle'),
    blackTitle: s('BlackTitle'),
    whiteRating: rating('WhiteElo'),
    blackRating: rating('BlackElo'),
    whiteFideId: fideId('WhiteFideId'),
    blackFideId: fideId('BlackFideId'),
    fenSeed: game.startingFen,
    databaseTitle: sourceLabel,
    databaseGames: _summariesFromLocalGames(
      _localBoardContextGames(localGame, databaseGames),
    ),
    gameListSelectedId: localGame.id,
    librarySaveOrigin: BoardTabLibrarySaveOrigin.localPgnFile(
      sourcePath: localGame.sourcePath,
      sourceIndex: localGame.indexInFile,
      sourceFileGameCount: localGame.fileGameCount,
      title: localGame.title,
    ),
  );
}

const int _kLocalBoardContextRadius = 100;

List<LocalChessGame> _localBoardContextGames(
  LocalChessGame selected,
  List<LocalChessGame> databaseGames,
) {
  if (databaseGames.isEmpty) return <LocalChessGame>[selected];

  final selectedIndex = databaseGames.indexWhere(
    (game) => game.id == selected.id,
  );
  if (selectedIndex < 0) return <LocalChessGame>[selected];

  final start =
      selectedIndex - _kLocalBoardContextRadius < 0
          ? 0
          : selectedIndex - _kLocalBoardContextRadius;
  final end =
      selectedIndex + _kLocalBoardContextRadius + 1 > databaseGames.length
          ? databaseGames.length
          : selectedIndex + _kLocalBoardContextRadius + 1;
  return databaseGames.sublist(start, end);
}

List<TournamentGameSummary> _summariesFromLocalGames(
  List<LocalChessGame> games,
) {
  return [for (final game in games) _summaryFromLocalGame(game)];
}

TournamentGameSummary _summaryFromLocalGame(LocalChessGame localGame) {
  final game = localGame.game;
  final md = game.metadata;
  String s(String key) => (md[key]?.toString() ?? '').trim();
  int rating(String key) => int.tryParse(s(key)) ?? 0;
  int? fideId(String key) {
    final value = rating(key);
    return value > 0 ? value : null;
  }

  final pgn = localGame.rawPgn.trim();
  final lastFen =
      game.mainline.isNotEmpty ? game.mainline.last.fen : game.startingFen;
  return TournamentGameSummary(
    id: localGame.id,
    name: localGame.title,
    whitePlayer: s('White'),
    blackPlayer: s('Black'),
    whiteFederation:
        s('WhiteFederation').isNotEmpty ? s('WhiteFederation') : s('WhiteFed'),
    blackFederation:
        s('BlackFederation').isNotEmpty ? s('BlackFederation') : s('BlackFed'),
    whiteTitle: s('WhiteTitle'),
    blackTitle: s('BlackTitle'),
    whiteRating: rating('WhiteElo'),
    blackRating: rating('BlackElo'),
    whiteFideId: fideId('WhiteFideId'),
    blackFideId: fideId('BlackFideId'),
    hasPgn: pgn.isNotEmpty,
    pgn: pgn.isEmpty ? null : pgn,
    fen: lastFen,
    roundLabel: s('Round'),
    status: _statusFromResult(s('Result')),
    openingName: s('Opening').isNotEmpty ? s('Opening') : s('ECO'),
    hasStarted: localGame.hasMoves,
  );
}

GameStatus _statusFromResult(String result) {
  switch (result.replaceAll('½', '1/2').trim()) {
    case '1-0':
      return GameStatus.whiteWins;
    case '0-1':
      return GameStatus.blackWins;
    case '1/2-1/2':
      return GameStatus.draw;
    case '*':
      return GameStatus.ongoing;
    default:
      return GameStatus.unknown;
  }
}

IconData _iconFor(LocalChessNode node) {
  return switch (node) {
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
}

List<ChessGame> _hydrateLocalGamesForSave(List<LocalChessGame> games) {
  final out = <ChessGame>[];
  for (final game in games) {
    try {
      out.add(ChessGame.fromPgn(game.id, game.rawPgn));
    } catch (_) {
      out.add(game.game);
    }
  }
  return out;
}
