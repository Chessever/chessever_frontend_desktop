import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/services/pgn_file_intake_service.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/default_games_table.dart';
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
  });

  final String selectedPath;
  final ValueChanged<String> onSelectPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(localChessLibraryProvider);
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

    return FTheme(
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
              onRefresh:
                  () => ref.read(localChessLibraryProvider.notifier).refresh(),
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
                            'Search local entries — names, event, ECO, file',
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
                        message: 'Try another player, event, opening, or file.',
                        onOpenFolder: pickFolder,
                        onOpenFiles: pickFiles,
                      )
                      : _LocalGamesTable(
                        databaseTitle: databaseTitle,
                        games: filtered,
                        databaseGames: allGames,
                      ),
            ),
          ],
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

class _LocalGamesTable extends HookConsumerWidget {
  const _LocalGamesTable({
    required this.databaseTitle,
    required this.games,
    required this.databaseGames,
  });

  final String databaseTitle;
  final List<LocalChessGame> games;
  final List<LocalChessGame> databaseGames;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useScrollController();
    final localByDefaultId = {
      for (final game in games) _defaultGameIdForLocalGame(game): game,
    };
    final defaultRows = games
        .map((game) {
          final row = chessGameToImportedGamesTourModel(game.game);
          return row.copyWith(
            gameId: _defaultGameIdForLocalGame(game),
            source: GameSource.localAnalysis,
            tourId: _cleanLocalTableMeta(
              game.game.metadata['Event']?.toString() ?? databaseTitle,
            ),
            tourSlug: _cleanLocalTableMeta(
              game.game.metadata['Event']?.toString() ?? databaseTitle,
            ),
            roundId: _cleanLocalTableMeta(
              game.game.metadata['Round']?.toString() ?? '',
            ),
          );
        })
        .toList(growable: false);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: DefaultGamesTable(
        games: defaultRows,
        controller: controller,
        routeTitle: databaseTitle,
        routeGames: defaultRows,
        rowKeyPrefix: 'local-game-table',
        onOpenGame: (row, {required bool inNewTab}) {
          final local = localByDefaultId[row.gameId];
          if (local == null) return;
          _openLocalGame(
            ref,
            local,
            sourceLabel: databaseTitle,
            databaseGames: databaseGames,
            focus: !inNewTab,
          );
        },
      ),
    );
  }
}

String _defaultGameIdForLocalGame(LocalChessGame game) => 'local:${game.id}';

String _cleanLocalTableMeta(String value) {
  final t = value.trim();
  return t == '?' ? '' : t;
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
    databaseGames: _summariesFromLocalGames(databaseGames),
    gameListSelectedId: localGame.id,
    librarySaveOrigin: BoardTabLibrarySaveOrigin.localPgnFile(
      sourcePath: localGame.sourcePath,
      sourceIndex: localGame.indexInFile,
      sourceFileGameCount: localGame.fileGameCount,
      title: localGame.title,
    ),
  );
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
