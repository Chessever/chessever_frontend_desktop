import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:chessground/chessground.dart' as cg;
import 'package:collection/collection.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/providers/board_settings_provider_new.dart';

import 'package:chessever/desktop/services/desktop_game_library_saver.dart';
import 'package:chessever/desktop/services/desktop_board_window_service.dart';
import 'package:chessever/desktop/services/desktop_share_actions.dart';
import 'package:chessever/desktop/services/board_tab_pgn_resolver.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/services/library_pgn_export.dart';
import 'package:chessever/desktop/services/library_quick_import.dart';
import 'package:chessever/desktop/services/local_chess_diagnostics.dart';
import 'package:chessever/desktop/services/local_chess_drop_zone.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:chessever/desktop/services/local_player_enrichment_service.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_source_deletion.dart';
import 'package:chessever/desktop/services/library_pgn_import_picker.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_database_workspace_paste.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/cloud_library_refresh.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/library_import_buffer.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/desktop/state/my_databases_focus.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/utils/library_multi_select.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_game_filter_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_header_action_button.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/list_keyboard_scroll.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/game_tab_drag_payload.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/desktop/widgets/library/folder_drop_target.dart';
import 'package:chessever/desktop/widgets/library/library_actions_toolbar.dart';
import 'package:chessever/desktop/widgets/library/library_chrome_bar.dart';
import 'package:chessever/desktop/widgets/library/library_folder_context_menu.dart';
import 'package:chessever/desktop/widgets/library/library_folder_dialogs.dart';
import 'package:chessever/desktop/widgets/library/library_game_context_menu.dart';
import 'package:chessever/desktop/widgets/library/library_game_dialogs.dart';
import 'package:chessever/desktop/widgets/library/library_database_drag_payload.dart';
import 'package:chessever/desktop/widgets/library/library_table_row_style.dart';
export 'package:chessever/desktop/widgets/library/library_table_row_style.dart'
    show librarySelectedRowDecoration;
import 'package:chessever/desktop/widgets/library/local_chess_files_view.dart';
import 'package:chessever/desktop/widgets/library/local_game_player_cell.dart';
import 'package:chessever/desktop/widgets/library/local_tree_action_button.dart';
import 'package:chessever/desktop/widgets/library/library_pgn_preview_panel.dart';
import 'package:chessever/desktop/widgets/library/twic_filter_dialog.dart';
import 'package:chessever/desktop/widgets/motion_card.dart';
import 'package:chessever/desktop/widgets/new_tab_modifier.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/desktop/widgets/resizable_split_view.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/desktop/widgets/table_display_value.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/desktop/utils/notation_vertical_navigation.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/library/providers/gamebase_database_games_provider.dart';
import 'package:chessever/screens/library/providers/gamebase_filter_provider.dart';
import 'package:chessever/screens/library/providers/library_folders_provider.dart';
import 'package:chessever/screens/library/providers/twic_event_aggregates_provider.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';
import 'package:chessever/screens/library/widgets/library_gamebase_filter_dialog.dart'
    show GamebaseFilter;
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/audio_player_service.dart';
import 'package:chessever/utils/number_format_utils.dart';
import 'package:chessever/utils/time_utils.dart';

/// Desktop library: complete cloud navigation in the rail plus a mixed local
/// and selected-cloud working catalog on Library Home.
///
/// The redesign collapses what was previously two stacked search fields and
/// a tall folder header with inline buttons into a single search inside the
/// content pane, a richer folder card header, and a sortable table view as
/// the default. The folder rail is now sectioned (My folders / Subscribed)
/// like a desktop mail client so the read-only "books" don't visually
/// compete with the user's own folders.
///
/// All cross-platform contracts (`LibraryRepository`, `libraryFoldersStreamProvider`,
/// PGN parsing) are reused unchanged so anything saved here remains visible
/// to the mobile build and vice-versa.
class LibraryPane extends HookConsumerWidget {
  const LibraryPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final foldersAsync = ref.watch(libraryFoldersStreamProvider);
    final subscribedAsync = ref.watch(subscribedBooksProvider);
    final ownedFolders = foldersAsync.valueOrNull ?? const <LibraryFolder>[];
    final subscribedFolders =
        subscribedAsync.valueOrNull ?? const <LibraryFolder>[];

    final ownedSorted = useMemoized(() => _hierarchical(ownedFolders), [
      ownedFolders,
    ]);
    final subscribedSorted = useMemoized(
      () => _hierarchical(subscribedFolders),
      [subscribedFolders],
    );
    // The synthetic TWIC database is part of the complete cloud navigator and
    // is not part of any user-owned/subscribed list.
    final allFolders = useMemoized(
      () => [kTwicFolder, ...ownedSorted, ...subscribedSorted],
      [ownedSorted, subscribedSorted],
    );

    final import = ref.watch(libraryImportBufferProvider);
    final localState = ref.watch(localChessLibraryProvider);
    final mainSplitController = useMemoized(ResizableSplitViewController.new);
    final currentLibraryFolderId = useState<String?>(null);
    final selectedFolderId = useState<String?>(null);
    final selectedLocalPath = useState<String?>(null);
    final localFullViewPath = useState<String?>(null);
    // Default Library landing is still the user's database home, with TWIC
    // selected for the bottom reference-style preview until they pick another
    // cloud database tile.
    useEffect(() {
      selectedFolderId.value ??= kTwicBookId;
      return null;
    }, const []);

    useEffect(() {
      syncLibraryLocalSelection(
        localState: localState,
        currentSelectedLocalPath: selectedLocalPath.value,
        selectLocalPath: (path) => selectedLocalPath.value = path,
        clearFolderSelection: () => selectedFolderId.value = null,
        hasImportPreview: ref.read(libraryImportBufferProvider) != null,
        clearImportPreview:
            () => ref.read(libraryImportBufferProvider.notifier).clear(),
      );
      return null;
    }, [localState.source, localState.selectedPath]);

    void activateLocalPath(String path) {
      selectedLocalPath.value = path;
      selectedFolderId.value = null;
      localFullViewPath.value = null;
      if (ref.read(libraryImportBufferProvider) != null) {
        ref.read(libraryImportBufferProvider.notifier).clear();
      }
    }

    void openLocalFullView(String path) {
      selectedLocalPath.value = path;
      selectedFolderId.value = null;
      localFullViewPath.value = null;
      ref.read(localChessLibraryProvider.notifier).selectPath(path);
      if (ref.read(libraryImportBufferProvider) != null) {
        ref.read(libraryImportBufferProvider.notifier).clear();
      }
      final source = ref.read(localChessLibraryProvider).source;
      final workspacePath = localDatabaseWorkspacePath(source, path);
      openDatabaseWorkspaceTab(
        ref,
        DatabaseWorkspaceArgs.local(
          localPath: workspacePath,
          title: localDatabaseWorkspaceTitle(source, workspacePath),
        ),
      );
      unawaited(
        ref
            .read(myDatabasesFocusProvider.notifier)
            .recordSuccessfulOpen(libraryLocalDatabasePinKey(path))
            .catchError((Object error) {
              if (kDebugMode) {
                debugPrint('Library Home local recency persist failed: $error');
              }
            }),
      );
    }

    void openCloudDatabase(LibraryFolder folder) {
      if (folder.id == kTwicBookId) {
        openDatabaseWorkspaceTab(ref, const DatabaseWorkspaceArgs.twic());
      } else {
        openDatabaseWorkspaceTab(
          ref,
          DatabaseWorkspaceArgs.folder(
            folderId: folder.id,
            title: folder.name,
            isSubscribed: folder.isSubscribed,
          ),
        );
      }
      unawaited(
        ref
            .read(myDatabasesFocusProvider.notifier)
            .recordSuccessfulOpen(libraryCloudDatabasePinKey(folder.id))
            .catchError((Object error) {
              if (kDebugMode) {
                debugPrint('Library Home cloud recency persist failed: $error');
              }
            }),
      );
    }

    void selectCloudFolder(LibraryFolder folder) {
      selectedFolderId.value = folder.id;
      selectedLocalPath.value = null;
      localFullViewPath.value = null;
      if (ref.read(libraryImportBufferProvider) != null) {
        ref.read(libraryImportBufferProvider.notifier).clear();
      }
    }

    void enterCloudFolder(LibraryFolder folder) {
      if (folder.id == kTwicBookId || _isLibraryDatabase(folder, allFolders)) {
        openCloudDatabase(folder);
        return;
      }
      currentLibraryFolderId.value = folder.id;
      selectCloudFolder(folder);
    }

    void navigateToLibraryFolder(String? folderId) {
      currentLibraryFolderId.value = folderId;
      selectedFolderId.value = folderId ?? kTwicBookId;
      selectedLocalPath.value = null;
      localFullViewPath.value = null;
      if (ref.read(libraryImportBufferProvider) != null) {
        ref.read(libraryImportBufferProvider.notifier).clear();
      }
    }

    Future<void> importLocalPgnFiles() async {
      final paths = await pickLibraryPgnDatabasePaths();
      if (paths == null) return;
      if (!context.mounted) return;

      showDesktopToast(
        context,
        paths.length == 1
            ? 'Importing PGN...'
            : 'Importing ${paths.length} PGN files...',
      );

      final path = await openLibraryPgnDatabasePaths(ref, paths);
      if (!context.mounted) return;
      if (path != null) {
        openLocalFullView(path);
        return;
      }

      final error = ref.read(localChessLibraryProvider).error?.trim();
      if (error == null || error.isEmpty) {
        showDesktopToast(
          context,
          'Could not import PGN. Please try another file.',
          error: true,
        );
      }
    }

    Future<void> addDatabaseDragShortcut(
      LibraryDatabaseDragPayload payload,
    ) async {
      if (payload.localPath != null) {
        final registered = await ref
            .read(localLibraryRegistryProvider.notifier)
            .register(payload.localPath!);
        final opened = await ref
            .read(localChessLibraryProvider.notifier)
            .openPaths(<String>[registered], sourceLabel: payload.title);
        if (opened) activateLocalPath(registered);
        return;
      }

      final folderId = payload.folderId;
      if (folderId == null) return;
      final folder = allFolders.firstWhereOrNull((f) => f.id == folderId);
      if (folder != null) {
        selectedFolderId.value = folder.id;
        selectedLocalPath.value = null;
        localFullViewPath.value = null;
      }
    }

    final arbiter = useMemoized(LibraryDropArbiter.new);

    Future<void> handleOuterDrop(List<String> paths) async {
      // desktop_drop sends onDragDone to nested and outer targets for the same
      // OS drop. Give the nested FolderDropTarget/body target a short window
      // to claim the drop before the outer fallback opens a local browse flow.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (arbiter.consumeClaim()) return;

      // No inner target claimed the drop. The safe default for large PGNs is
      // local-database open; folder import remains available on folder targets.
      final opened = await ref
          .read(localChessLibraryProvider.notifier)
          .openPaths(
            paths,
            sourceLabel: localChessDatabaseDisplayNameForPaths(paths),
          );
      if (!opened) return;
      final path = ref.read(localChessLibraryProvider).selectedPath;
      if (path != null) activateLocalPath(path);
    }

    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        color: kBackgroundColor,
        child: LibraryDropArbiterScope(
          arbiter: arbiter,
          child: LocalChessDropZone(
            onChessPathsDropped: handleOuterDrop,
            child: ResizableSplitView(
              axis: Axis.horizontal,
              storageKey: 'library_pane.main',
              controller: mainSplitController,
              children: [
                SplitChild(
                  minSize: 200,
                  maxSize: 420,
                  initialWeight: 0.20,
                  label: 'Cloud Library',
                  collapsedIcon: Icons.view_sidebar_outlined,
                  child: _FolderRail(
                    ownedFolders: ownedSorted,
                    subscribedFolders: subscribedSorted,
                    isLoading: foldersAsync.isLoading && !foldersAsync.hasValue,
                    error: foldersAsync.asError?.error,
                    selectedId: selectedFolderId.value,
                    selectedLocalPath: selectedLocalPath.value,
                    onSelect: (id) {
                      selectedFolderId.value = id;
                      selectedLocalPath.value = null;
                      localFullViewPath.value = null;
                      // Discard any import preview when the user navigates to
                      // a database — the right side now keeps the Library
                      // database home and updates its bottom preview instead
                      // of immediately opening a full workspace tab.
                      if (ref.read(libraryImportBufferProvider) != null) {
                        ref.read(libraryImportBufferProvider.notifier).clear();
                      }
                    },
                    onOpen: enterCloudFolder,
                    onAction:
                        (folder, action) => _onFolderAction(
                          context: context,
                          ref: ref,
                          folder: folder,
                          action: action,
                          allFolders: allFolders,
                        ),
                    onCollapse: () => mainSplitController.collapse(0),
                  ),
                ),
                SplitChild(
                  minSize: 480,
                  initialWeight: 0.80,
                  label: 'Content',
                  dismissible: false,
                  child:
                      import != null
                          ? LibraryPgnPreviewPanel(buffer: import)
                          : localFullViewPath.value != null
                          ? LocalChessFilesView(
                            selectedPath: localFullViewPath.value!,
                            onSelectPath: openLocalFullView,
                          )
                          : _MyDatabasesHomeView(
                            folders: allFolders,
                            currentFolderId: currentLibraryFolderId.value,
                            selectedFolderId: selectedFolderId.value,
                            selectedLocalPath: selectedLocalPath.value,
                            onSelectFolder: selectCloudFolder,
                            onOpenFolder: enterCloudFolder,
                            onOpenDatabase: openCloudDatabase,
                            onNavigateToFolder: navigateToLibraryFolder,
                            onSelectLocalPath: activateLocalPath,
                            onOpenLocalPath: openLocalFullView,
                            onImportPgnFiles: importLocalPgnFiles,
                            onDropDatabase: addDatabaseDragShortcut,
                            onNewFolder:
                                () => _onCreateFolder(
                                  context: context,
                                  ref: ref,
                                  folders: allFolders,
                                  kind: LibraryFolderCreateKind.folder,
                                ),
                            onNewDatabase: () {
                              final currentFolder =
                                  currentLibraryFolderId.value == null
                                      ? null
                                      : allFolders.firstWhereOrNull(
                                        (folder) =>
                                            folder.id ==
                                            currentLibraryFolderId.value,
                                      );
                              _onCreateFolder(
                                context: context,
                                ref: ref,
                                folders: allFolders,
                                lockedParent:
                                    currentFolder != null &&
                                            !libraryFolderIsDatabase(
                                              currentFolder,
                                              allFolders,
                                            )
                                        ? currentFolder
                                        : null,
                                kind: LibraryFolderCreateKind.database,
                              );
                            },
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

@visibleForTesting
void syncLibraryLocalSelection({
  required LocalChessLibraryState localState,
  required String? currentSelectedLocalPath,
  required ValueChanged<String> selectLocalPath,
  required VoidCallback clearFolderSelection,
  required bool hasImportPreview,
  required VoidCallback clearImportPreview,
}) {
  final path = localState.selectedPath;
  if (path == null) return;
  if (currentSelectedLocalPath != path) {
    selectLocalPath(path);
    clearFolderSelection();
  }
  if (hasImportPreview) clearImportPreview();
}

final _twicPreviewPgnProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, gameId) async {
      final normalized = gameId.trim();
      if (normalized.isEmpty) return null;

      final resolved = await resolveBoardTabPgn(
        gameId: normalized,
        fetchSupabasePgn:
            (id) => ref.read(gameRepositoryProvider).getGamePgn(id),
        fetchGamebaseGameWithPgn:
            (id) => ref.read(gamebaseRepositoryProvider).getGameWithPgn(id),
      );
      if (!pgnHasMoves(resolved)) return null;
      return resolved!.trim();
    });

({ChessGame? game, bool isLoading}) _watchTwicPreviewGame(
  WidgetRef ref,
  GamesTourModel? selected,
) {
  if (selected == null) return (game: null, isLoading: false);

  final hasInitialMoves = pgnHasMoves(selected.pgn);
  final hydratedPgnAsync =
      hasInitialMoves
          ? null
          : ref.watch(_twicPreviewPgnProvider(selected.gameId));
  final hydratedPgn = hydratedPgnAsync?.valueOrNull;
  final previewSource =
      pgnHasMoves(hydratedPgn) ? selected.copyWith(pgn: hydratedPgn) : selected;

  return (
    game: _previewChessGameFromTourGame(previewSource),
    isLoading: hydratedPgnAsync?.isLoading ?? false,
  );
}

// =====================================================================
// Cloud Library rail (complete synced cloud collection)
// =====================================================================

class _FolderRail extends StatelessWidget {
  const _FolderRail({
    required this.ownedFolders,
    required this.subscribedFolders,
    required this.isLoading,
    required this.error,
    required this.selectedId,
    required this.selectedLocalPath,
    required this.onSelect,
    required this.onOpen,
    required this.onAction,
    required this.onCollapse,
  });

  final List<LibraryFolder> ownedFolders;
  final List<LibraryFolder> subscribedFolders;
  final bool isLoading;
  final Object? error;
  final String? selectedId;
  final String? selectedLocalPath;
  final ValueChanged<String> onSelect;
  final ValueChanged<LibraryFolder> onOpen;
  final void Function(LibraryFolder folder, LibraryFolderAction action)
  onAction;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBlack2Color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RailHeader(onCollapse: onCollapse),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (isLoading) return const _RailLoading();
    final folders = [kTwicFolder, ...ownedFolders, ...subscribedFolders];
    return ListView(
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        if (error != null) _RailSyncWarning(error: error!),
        const _RailGroupHeader(label: 'System', count: 1),
        _PinnedSystemFolderRow(
          folder: kTwicFolder,
          selected: kTwicBookId == selectedId,
          onTap: () => onSelect(kTwicBookId),
          onOpen: () => onOpen(kTwicFolder),
        ),
        if (ownedFolders.isNotEmpty) ...[
          const SizedBox(height: 14),
          _RailGroupHeader(label: 'Cloud folders', count: ownedFolders.length),
          for (final folder in ownedFolders)
            _FolderRow(
              folder: folder,
              iconKind: _cloudFolderIconKind(folder, folders),
              selected: folder.id == selectedId,
              onTap: () => onSelect(folder.id),
              onOpen: () => onOpen(folder),
              onAction: (action) => onAction(folder, action),
            ),
        ] else if (subscribedFolders.isEmpty) ...[
          const SizedBox(height: 14),
          const _RailEmptyHint(),
        ],
        if (subscribedFolders.isNotEmpty) ...[
          const SizedBox(height: 14),
          _RailGroupHeader(
            label: 'Subscribed',
            count: subscribedFolders.length,
          ),
          for (final folder in subscribedFolders)
            _FolderRow(
              folder: folder,
              iconKind: _cloudFolderIconKind(folder, folders),
              selected: folder.id == selectedId,
              onTap: () => onSelect(folder.id),
              onOpen: () => onOpen(folder),
              onAction: (action) => onAction(folder, action),
            ),
        ],
      ],
    );
  }
}

@visibleForTesting
Widget buildLibraryFolderRailForTest({
  List<LibraryFolder> ownedFolders = const <LibraryFolder>[],
  List<LibraryFolder> subscribedFolders = const <LibraryFolder>[],
  bool isLoading = false,
  Object? error,
  String? selectedId,
  String? selectedLocalPath,
}) {
  return SizedBox(
    width: 260,
    height: 420,
    child: _FolderRail(
      ownedFolders: ownedFolders,
      subscribedFolders: subscribedFolders,
      isLoading: isLoading,
      error: error,
      selectedId: selectedId,
      selectedLocalPath: selectedLocalPath,
      onSelect: (_) {},
      onOpen: (_) {},
      onAction: (_, _) {},
      onCollapse: () {},
    ),
  );
}

class _RailHeader extends StatelessWidget {
  const _RailHeader({required this.onCollapse});

  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDividerColor)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.view_sidebar_outlined,
            color: kLightGreyColor,
            size: 16,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Cloud Library',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          DesktopTooltip(
            message: 'Collapse sidebar',
            child: FButton.icon(
              style: FButtonStyle.ghost(),
              onPress: onCollapse,
              child: const Icon(Icons.close_rounded, size: 16),
            ),
          ),
        ],
      ),
    );
  }
}

/// Rail row for the pinned TWIC database. No right-click menu — TWIC is
/// non-deletable and not renamable.
class _PinnedSystemFolderRow extends StatefulWidget {
  const _PinnedSystemFolderRow({
    required this.folder,
    required this.selected,
    required this.onTap,
    required this.onOpen,
  });
  final LibraryFolder folder;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onOpen;

  @override
  State<_PinnedSystemFolderRow> createState() => _PinnedSystemFolderRowState();
}

class _PinnedSystemFolderRowState extends State<_PinnedSystemFolderRow>
    with DeferredPointerStateMixin<_PinnedSystemFolderRow> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final fg =
        widget.selected
            ? kPrimaryColor
            : (_hovered ? kWhiteColor : kWhiteColor70);
    final bg =
        widget.selected
            ? kPrimaryColor.withValues(alpha: 0.12)
            : (_hovered ? kBlack3Color : Colors.transparent);
    final nudgeX = _pressed ? -1.5 : (_hovered ? 3.0 : 0.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 1, 8, 1),
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
          onExit:
              (_) => setStateAfterPointerEvent(() {
                _hovered = false;
                _pressed = false;
              }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onDoubleTap: widget.onOpen,
            onTapDown: (_) => setStateAfterPointerEvent(() => _pressed = true),
            onTapUp: (_) => setStateAfterPointerEvent(() => _pressed = false),
            onTapCancel:
                () => setStateAfterPointerEvent(() => _pressed = false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color:
                      widget.selected
                          ? kPrimaryColor.withValues(alpha: 0.45)
                          : Colors.transparent,
                ),
              ),
              child: SingleMotionBuilder(
                value: nudgeX,
                motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
                builder:
                    (context, x, child) =>
                        Transform.translate(offset: Offset(x, 0), child: child),
                child: Row(
                  children: [
                    Icon(Icons.public_rounded, size: 14, color: fg),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.folder.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg,
                          fontSize: 13,
                          fontWeight:
                              widget.selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                        ),
                      ),
                    ),
                    DesktopTooltip(
                      message: 'System database (read-only)',
                      child: Icon(
                        Icons.lock_outline_rounded,
                        size: 11,
                        color: kLightGreyColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RailEmptyHint extends StatelessWidget {
  const _RailEmptyHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text(
            'YOUR FOLDERS',
            style: TextStyle(
              color: kLightGreyColor,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.7,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Create a cloud folder or database from Library Home.',
            style: TextStyle(color: kWhiteColor70, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _RailGroupHeader extends StatelessWidget {
  const _RailGroupHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 6),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.7,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: TextStyle(
              color: kLightGreyColor.withValues(alpha: 0.65),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _RailLoading extends StatelessWidget {
  const _RailLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
        ),
      ),
    );
  }
}

class _RailSyncWarning extends StatelessWidget {
  const _RailSyncWarning({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
        decoration: BoxDecoration(
          color: kBlack3Color.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: const Color(0xFFFFC857).withValues(alpha: 0.26),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(
                Icons.cloud_off_rounded,
                size: 14,
                color: Color(0xFFFFC857),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Cloud folders unavailable',
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    libraryFolderSyncErrorMessage(error),
                    style: const TextStyle(
                      color: kWhiteColor70,
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

@visibleForTesting
String libraryFolderSyncErrorMessage(Object error) {
  final message = error.toString().toLowerCase();
  if (message.contains('realtimesubscribestatus.timedout') ||
      message.contains('timedout') ||
      message.contains('timed out')) {
    return 'Sync timed out. Local databases are still available.';
  }
  if (message.contains('not authenticated') ||
      message.contains('sign in') ||
      message.contains('signin')) {
    return 'Sign in to sync cloud folders. Local databases are still available.';
  }
  return 'Cloud sync is unavailable. Local databases are still available.';
}

class _FolderRow extends ConsumerStatefulWidget {
  const _FolderRow({
    required this.folder,
    required this.iconKind,
    required this.selected,
    required this.onTap,
    required this.onOpen,
    required this.onAction,
  });

  final LibraryFolder folder;
  final _DatabaseBoardIconKind iconKind;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onOpen;
  final ValueChanged<LibraryFolderAction> onAction;

  @override
  ConsumerState<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends ConsumerState<_FolderRow>
    with DeferredPointerStateMixin<_FolderRow> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final chrome = _LibraryKindChrome.forKind(widget.iconKind);
    final isFolder = widget.iconKind == _DatabaseBoardIconKind.folder;
    final focusState = ref.watch(myDatabasesFocusProvider);
    final isShownOnLibraryHome =
        !focusState.hiddenCloudFolderIds.contains(widget.folder.id);
    final fg =
        widget.selected
            ? chrome.accent
            : (_hovered ? kWhiteColor : kWhiteColor70);
    final bg =
        widget.selected
            ? chrome.accent.withValues(alpha: 0.12)
            : (_hovered ? kBlack3Color : Colors.transparent);
    final nudgeX = _pressed ? -1.5 : (_hovered ? 3.0 : 0.0);
    final isChild = widget.folder.parentId != null;
    return FolderDropTarget(
      enabled: isWritableLibraryFolder(widget.folder),
      folderName: widget.folder.name,
      onAcceptPaths:
          (paths) => quickImportPathsToFolder(
            context: context,
            ref: ref,
            folder: widget.folder,
            paths: paths,
          ),
      child: LibraryFolderContextMenu(
        folder: widget.folder,
        canCreateDatabase: !widget.folder.isSubscribed && isFolder,
        hasGames: true, // count is unknown at rail level; menu still useful.
        includeLibraryHomeAction: !widget.folder.isPermanentLibraryFolder,
        isShownOnLibraryHome: isShownOnLibraryHome,
        onAction: widget.onAction,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 1, 8, 1),
          child: DesktopTooltip(
            message: widget.folder.name,
            child: ClickCursor(
              child: MouseRegion(
                onEnter:
                    (_) => setStateAfterPointerEvent(() => _hovered = true),
                onExit:
                    (_) => setStateAfterPointerEvent(() {
                      _hovered = false;
                      _pressed = false;
                    }),
                child: Focus(
                  canRequestFocus: true,
                  onKeyEvent: (_, event) {
                    if (event is! KeyDownEvent) return KeyEventResult.ignored;
                    if (event.logicalKey == LogicalKeyboardKey.enter ||
                        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
                      widget.onOpen();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onTap,
                    onDoubleTap: widget.onOpen,
                    onTapDown:
                        (_) => setStateAfterPointerEvent(() => _pressed = true),
                    onTapUp:
                        (_) =>
                            setStateAfterPointerEvent(() => _pressed = false),
                    onTapCancel:
                        () => setStateAfterPointerEvent(() => _pressed = false),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      padding: EdgeInsets.fromLTRB(isChild ? 20 : 10, 7, 8, 7),
                      decoration: BoxDecoration(
                        color: bg,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color:
                              widget.selected
                                  ? chrome.accent.withValues(alpha: 0.48)
                                  : Colors.transparent,
                        ),
                      ),
                      child: SingleMotionBuilder(
                        value: nudgeX,
                        motion:
                            _pressed ? DesktopMotion.tap : DesktopMotion.hover,
                        builder:
                            (context, x, child) => Transform.translate(
                              offset: Offset(x, 0),
                              child: child,
                            ),
                        child: Row(
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: chrome.wellFill,
                                borderRadius: BorderRadius.circular(
                                  isFolder ? 5 : 7,
                                ),
                                border: Border.all(
                                  color: chrome.wellBorder.withValues(
                                    alpha:
                                        widget.selected || _hovered
                                            ? 0.85
                                            : 0.45,
                                  ),
                                ),
                              ),
                              child: _DatabaseBoardIcon(
                                kind: widget.iconKind,
                                color: chrome.accent,
                                size: 13,
                              ),
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                widget.folder.name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: fg,
                                  fontSize: 13,
                                  fontWeight:
                                      widget.selected
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                ),
                              ),
                            ),
                            if (widget.folder.isSubscribed)
                              const Icon(
                                Icons.lock_outline_rounded,
                                size: 11,
                                color: kLightGreyColor,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// Folder content view (right side when no import is staged)
// =====================================================================

/// Library has one extra mode the rest of the panes don't: a sortable
/// data table (per-column sort, dense rows, no eval bar). The other three
/// match the global game-card toggle (compact / list / grid) so users get
/// the same visuals here as in Tournaments and Countrymen.
enum _GamesViewMode { table, compact, list, grid }

enum DatabaseWorkspaceSource { twic, folder, local }

@immutable
class DatabaseWorkspaceArgs {
  const DatabaseWorkspaceArgs.folder({
    required this.folderId,
    required this.title,
    required this.isSubscribed,
  }) : source = DatabaseWorkspaceSource.folder,
       localPath = null;

  const DatabaseWorkspaceArgs.twic()
    : source = DatabaseWorkspaceSource.twic,
      folderId = kTwicBookId,
      title = 'ChessEver',
      isSubscribed = true,
      localPath = null;

  const DatabaseWorkspaceArgs.local({
    required this.localPath,
    required this.title,
  }) : source = DatabaseWorkspaceSource.local,
       folderId = '',
       isSubscribed = false;

  final DatabaseWorkspaceSource source;
  final String folderId;
  final String title;
  final bool isSubscribed;
  final String? localPath;

  bool sameDatabase(DatabaseWorkspaceArgs other) =>
      source == other.source &&
      folderId == other.folderId &&
      isSubscribed == other.isSubscribed &&
      localPath == other.localPath;
}

final databaseWorkspaceArgsByTabIdProvider =
    StateProvider<Map<String, DatabaseWorkspaceArgs>>(
      (_) => const <String, DatabaseWorkspaceArgs>{},
    );

@immutable
class _TwicWorkspaceGamesQuery {
  const _TwicWorkspaceGamesQuery({
    required this.searchQuery,
    required this.filter,
  });

  final String searchQuery;
  final GamebaseFilter filter;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _TwicWorkspaceGamesQuery &&
          other.searchQuery == searchQuery &&
          other.filter == filter;

  @override
  int get hashCode => Object.hash(searchQuery, filter);
}

final _twicWorkspaceGamesProvider = StateNotifierProvider.autoDispose.family<
  DatabaseGamesPaginationNotifier,
  DatabaseGamesPaginationState,
  _TwicWorkspaceGamesQuery
>((ref, query) {
  return DatabaseGamesPaginationNotifier(
    ref,
    query.searchQuery,
    query.filter,
    null,
  );
});

String openDatabaseWorkspaceTab(WidgetRef ref, DatabaseWorkspaceArgs args) {
  return _openDatabaseWorkspaceTab(ref.read, args);
}

String openDatabaseWorkspaceTabForContainer(
  ProviderContainer container,
  DatabaseWorkspaceArgs args,
) {
  return _openDatabaseWorkspaceTab(container.read, args);
}

String _openDatabaseWorkspaceTab(
  T Function<T>(ProviderListenable<T> provider) read,
  DatabaseWorkspaceArgs args,
) {
  final tabs = read(desktopTabsProvider);
  final argsByTabId = read(databaseWorkspaceArgsByTabIdProvider);
  final existing = tabs.tabs.firstWhereOrNull((tab) {
    if (tab.kind != TabKind.databaseWorkspace) return false;
    final tabArgs = argsByTabId[tab.id];
    return tabArgs != null && tabArgs.sameDatabase(args);
  });
  if (existing != null) {
    read(desktopTabsProvider.notifier).activate(existing.id);
    return existing.id;
  }

  final tabId = read(desktopTabsProvider.notifier).open(
    TabKind.databaseWorkspace,
    title: args.title,
    subtitle: switch (args.source) {
      DatabaseWorkspaceSource.twic => 'System database',
      DatabaseWorkspaceSource.folder => 'Database',
      DatabaseWorkspaceSource.local => 'Local database',
    },
    reuseExisting: false,
  );
  read(databaseWorkspaceArgsByTabIdProvider.notifier).update((existing) {
    return <String, DatabaseWorkspaceArgs>{...existing, tabId: args};
  });
  return tabId;
}

enum _SortKey {
  number,
  white,
  whiteElo,
  result,
  black,
  blackElo,
  event,
  eco,
  date,
  saved,
}

enum _SortDir { asc, desc }

@immutable
class _SortConfig {
  const _SortConfig(this.key, this.dir);
  final _SortKey key;
  final _SortDir dir;

  _SortConfig _toggleOrSet(_SortKey k) {
    if (k == key) {
      return _SortConfig(k, dir == _SortDir.asc ? _SortDir.desc : _SortDir.asc);
    }
    // Saved + Date default to descending (most-recent first), text columns
    // to ascending (alphabetical) — same defaults a desktop file browser
    // gives you when you first click each column.
    final d =
        (k == _SortKey.saved ||
                k == _SortKey.date ||
                k == _SortKey.whiteElo ||
                k == _SortKey.blackElo)
            ? _SortDir.desc
            : _SortDir.asc;
    return _SortConfig(k, d);
  }
}

enum LibraryDatabaseCatalogSource { cloud, local }

enum LibraryDatabaseCatalogSourceFilter { all, cloud, local }

@immutable
class LibraryDatabaseCatalogColumns {
  const LibraryDatabaseCatalogColumns({
    required this.showSource,
    required this.showLastOpened,
    this.nameWidth = 320,
    this.gamesWidth = 110,
    this.sourceWidth = 82,
    this.lastOpenedWidth = 108,
  });

  final bool showSource;
  final bool showLastOpened;
  final double nameWidth;
  final double gamesWidth;
  final double sourceWidth;
  final double lastOpenedWidth;

  @override
  bool operator ==(Object other) {
    return other is LibraryDatabaseCatalogColumns &&
        showSource == other.showSource &&
        showLastOpened == other.showLastOpened &&
        nameWidth == other.nameWidth &&
        gamesWidth == other.gamesWidth &&
        sourceWidth == other.sourceWidth &&
        lastOpenedWidth == other.lastOpenedWidth;
  }

  @override
  int get hashCode => Object.hash(
    showSource,
    showLastOpened,
    nameWidth,
    gamesWidth,
    sourceWidth,
    lastOpenedWidth,
  );
}

@visibleForTesting
LibraryDatabaseCatalogColumns libraryDatabaseCatalogColumns(
  double width, {
  Map<String, double> savedWidths = const <String, double>{},
}) {
  double saved(String key, double fallback, double min, double max) {
    return (savedWidths[key] ?? fallback).clamp(min, max).toDouble();
  }

  final showSource = width >= 560;
  final showLastOpened = width >= 760;
  final gamesWidth = saved('games', 110, 72, 190);
  final sourceWidth = saved('source', 82, 70, 160);
  final lastOpenedWidth = saved('lastOpened', 108, 88, 200);
  final fixedWidth =
      39 +
      5 +
      12 +
      gamesWidth +
      (showSource ? 12 + sourceWidth : 0) +
      (showLastOpened ? 12 + lastOpenedWidth : 0) +
      8 +
      22;
  final availableNameWidth = math.max(160.0, width - fixedWidth - 20);
  return LibraryDatabaseCatalogColumns(
    showSource: showSource,
    showLastOpened: showLastOpened,
    nameWidth: saved('name', availableNameWidth, 160, availableNameWidth),
    gamesWidth: gamesWidth,
    sourceWidth: sourceWidth,
    lastOpenedWidth: lastOpenedWidth,
  );
}

@visibleForTesting
bool libraryDatabaseCatalogMatches({
  required String title,
  required String details,
  required LibraryDatabaseCatalogSource source,
  required LibraryDatabaseCatalogSourceFilter filter,
  required String query,
}) {
  final matchesSource = switch (filter) {
    LibraryDatabaseCatalogSourceFilter.all => true,
    LibraryDatabaseCatalogSourceFilter.cloud =>
      source == LibraryDatabaseCatalogSource.cloud,
    LibraryDatabaseCatalogSourceFilter.local =>
      source == LibraryDatabaseCatalogSource.local,
  };
  if (!matchesSource) return false;
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) return true;
  return '$title $details'.toLowerCase().contains(normalizedQuery);
}

@visibleForTesting
List<String> libraryCatalogReorderedKeys(
  List<String> keys, {
  required String draggedKey,
  required String targetKey,
}) {
  final oldIndex = keys.indexOf(draggedKey);
  final targetIndex = keys.indexOf(targetKey);
  if (oldIndex < 0 || targetIndex < 0 || oldIndex == targetIndex) {
    return List<String>.of(keys);
  }
  final reordered = List<String>.of(keys)..removeAt(oldIndex);
  reordered.insert(targetIndex.clamp(0, reordered.length), draggedKey);
  return reordered;
}

enum _LibraryDatabaseKind { cloud, local }

enum _DatabaseBoardView { list, grid }

enum _CloudDatabaseBoardAction { preview, open, pin, unpin, remove }

enum _LocalGroupBoardAction {
  open,
  pin,
  unpin,
  removeFromLibraryHome,
  deleteFromComputer,
}

enum _LocalDatabaseBoardAction {
  preview,
  open,
  pin,
  unpin,
  removeFromLibraryHome,
  deleteFromComputer,
}

class _MyDatabasesHomeView extends HookConsumerWidget {
  const _MyDatabasesHomeView({
    required this.folders,
    required this.currentFolderId,
    required this.selectedFolderId,
    required this.selectedLocalPath,
    required this.onSelectFolder,
    required this.onOpenFolder,
    required this.onOpenDatabase,
    required this.onNavigateToFolder,
    required this.onSelectLocalPath,
    required this.onOpenLocalPath,
    required this.onImportPgnFiles,
    required this.onDropDatabase,
    required this.onNewFolder,
    required this.onNewDatabase,
  });

  final List<LibraryFolder> folders;
  final String? currentFolderId;
  final String? selectedFolderId;
  final String? selectedLocalPath;
  final ValueChanged<LibraryFolder> onSelectFolder;
  final ValueChanged<LibraryFolder> onOpenFolder;
  final ValueChanged<LibraryFolder> onOpenDatabase;
  final ValueChanged<String?> onNavigateToFolder;
  final ValueChanged<String> onSelectLocalPath;
  final ValueChanged<String> onOpenLocalPath;
  final VoidCallback onImportPgnFiles;
  final Future<void> Function(LibraryDatabaseDragPayload payload)
  onDropDatabase;
  final VoidCallback onNewFolder;
  final VoidCallback onNewDatabase;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalogSearchController = useTextEditingController();
    final catalogQuery = useState('');
    final catalogSourceFilter = useState(
      LibraryDatabaseCatalogSourceFilter.all,
    );
    final catalogView = useState(_DatabaseBoardView.list);
    final homePreferences = ref.watch(myDatabasesFocusProvider);
    final localState = ref.watch(localChessLibraryProvider);
    final localSource = localState.source;
    final selectedFolder = folders.firstWhereOrNull(
      (folder) => folder.id == selectedFolderId,
    );
    final selectedLocalNode = localSource?.nodeForPath(selectedLocalPath);
    final selectedKind =
        selectedLocalPath != null
            ? _LibraryDatabaseKind.local
            : _LibraryDatabaseKind.cloud;
    final deleteProgress = useState<LocalChessScanProgress?>(null);
    final currentLocalGroupId = useState<String?>(null);
    final localEntries = ref.watch(localLibraryRegistryProvider).entries;
    final localGroups = _localLibraryEntryGroups(localEntries);
    final currentLocalGroup = localGroups.firstWhereOrNull(
      (group) => group.id == currentLocalGroupId.value,
    );
    final localGroupIdsKey = localGroups.map((group) => group.id).join('|');

    void setDeleteProgress(LocalChessScanProgress? progress) {
      if (!context.mounted) return;
      deleteProgress.value = progress;
    }

    useEffect(() {
      if (currentFolderId != null && currentLocalGroupId.value != null) {
        currentLocalGroupId.value = null;
      }
      return null;
    }, [currentFolderId]);

    useEffect(() {
      if (currentLocalGroupId.value != null && currentLocalGroup == null) {
        currentLocalGroupId.value = null;
      }
      return null;
    }, [currentLocalGroupId.value, localGroupIdsKey]);

    useEffect(() {
      if (homePreferences.loaded) {
        catalogView.value =
            homePreferences.listViewPreferred
                ? _DatabaseBoardView.list
                : _DatabaseBoardView.grid;
      }
      return null;
    }, [homePreferences.loaded]);

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MyDatabasesHeader(
              folders: folders,
              currentFolderId:
                  currentLocalGroup == null ? currentFolderId : null,
              localGroupLabel: currentLocalGroup?.label,
              onNavigate: (folderId) {
                currentLocalGroupId.value = null;
                onNavigateToFolder(folderId);
              },
              onNavigateLocalRoot:
                  currentLocalGroup == null
                      ? null
                      : () => currentLocalGroupId.value = null,
              onNewFolder: onNewFolder,
              onImportPgnFiles: onImportPgnFiles,
              searchController: catalogSearchController,
              sourceFilter: catalogSourceFilter.value,
              view: catalogView.value,
              onQueryChanged: (value) => catalogQuery.value = value,
              onSourceFilterChanged:
                  (value) => catalogSourceFilter.value = value,
              onViewChanged: (value) {
                catalogView.value = value;
                unawaited(
                  ref
                      .read(myDatabasesFocusProvider.notifier)
                      .setListViewPreferred(value == _DatabaseBoardView.list)
                      .catchError((Object error) {
                        if (kDebugMode) {
                          debugPrint(
                            'Library Home view preference persist failed: '
                            '$error',
                          );
                        }
                        if (!context.mounted) return;
                        final restored = ref.read(myDatabasesFocusProvider);
                        catalogView.value =
                            restored.listViewPreferred
                                ? _DatabaseBoardView.list
                                : _DatabaseBoardView.grid;
                        showDesktopToast(
                          context,
                          'Could not save the Library Home view.',
                          error: true,
                        );
                      }),
                );
              },
              onNewDatabase: onNewDatabase,
            ),
            Expanded(
              child: ResizableSplitView(
                axis: Axis.vertical,
                storageKey: 'library_pane.my_databases.home_split',
                children: [
                  SplitChild(
                    minSize: 124,
                    initialWeight: 0.24,
                    label: 'Library Home',
                    child: _MyDatabasesBoard(
                      folders: folders,
                      currentFolderId: currentFolderId,
                      currentLocalGroupId: currentLocalGroupId.value,
                      localSource: localSource,
                      selectedFolderId: selectedFolderId,
                      selectedLocalPath: selectedLocalPath,
                      isDeletingLocalDatabase: deleteProgress.value != null,
                      onDeleteProgress: setDeleteProgress,
                      onSelectFolder: onSelectFolder,
                      onOpenFolder: onOpenFolder,
                      onOpenDatabase: onOpenDatabase,
                      onCurrentLocalGroupChanged:
                          (value) => currentLocalGroupId.value = value,
                      onSelectLocalPath: onSelectLocalPath,
                      onOpenLocalPath: onOpenLocalPath,
                      onDropDatabase: onDropDatabase,
                      query: catalogQuery.value,
                      sourceFilter: catalogSourceFilter.value,
                      view: catalogView.value,
                    ),
                  ),
                  SplitChild(
                    minSize: 260,
                    initialWeight: 0.70,
                    label: 'Preview',
                    child: switch (selectedKind) {
                      _LibraryDatabaseKind.local => _LocalDatabaseMiniPreview(
                        source: localSource,
                        selectedNode: selectedLocalNode,
                        selectedPath: selectedLocalPath,
                      ),
                      _LibraryDatabaseKind.cloud => _CloudDatabaseMiniPreview(
                        folder: selectedFolder,
                      ),
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        if (deleteProgress.value != null)
          Positioned.fill(
            child: _LibraryBlockingProgressOverlay(
              title: 'Deleting local data',
              progress: deleteProgress.value!,
            ),
          ),
      ],
    );
  }
}

class _MyDatabasesHeader extends StatelessWidget {
  const _MyDatabasesHeader({
    required this.folders,
    required this.currentFolderId,
    required this.localGroupLabel,
    required this.onNavigate,
    required this.onNavigateLocalRoot,
    required this.onNewFolder,
    required this.onImportPgnFiles,
    required this.onNewDatabase,
    required this.searchController,
    required this.sourceFilter,
    required this.view,
    required this.onQueryChanged,
    required this.onSourceFilterChanged,
    required this.onViewChanged,
  });

  final List<LibraryFolder> folders;
  final String? currentFolderId;
  final String? localGroupLabel;
  final ValueChanged<String?> onNavigate;
  final VoidCallback? onNavigateLocalRoot;
  final VoidCallback? onNewFolder;
  final VoidCallback onImportPgnFiles;
  final VoidCallback onNewDatabase;
  final TextEditingController searchController;
  final LibraryDatabaseCatalogSourceFilter sourceFilter;
  final _DatabaseBoardView view;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<LibraryDatabaseCatalogSourceFilter> onSourceFilterChanged;
  final ValueChanged<_DatabaseBoardView> onViewChanged;

  @override
  Widget build(BuildContext context) {
    Widget filterButton(
      String label,
      IconData icon,
      LibraryDatabaseCatalogSourceFilter filter,
    ) {
      return DesktopToolbarPillButton(
        label: label,
        icon: icon,
        height: 30,
        tone:
            sourceFilter == filter
                ? DesktopToolbarPillTone.primary
                : DesktopToolbarPillTone.neutral,
        onPress: () => onSourceFilterChanged(filter),
      );
    }

    final filtersAndView = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        filterButton(
          'All',
          Icons.all_inbox_rounded,
          LibraryDatabaseCatalogSourceFilter.all,
        ),
        const SizedBox(width: 4),
        filterButton(
          'Cloud',
          Icons.cloud_outlined,
          LibraryDatabaseCatalogSourceFilter.cloud,
        ),
        const SizedBox(width: 4),
        filterButton(
          'Local',
          Icons.computer_rounded,
          LibraryDatabaseCatalogSourceFilter.local,
        ),
        const SizedBox(width: 8),
        DesktopHeaderIconButton(
          icon: Icons.view_list_rounded,
          selected: view == _DatabaseBoardView.list,
          tooltip: 'List view',
          onPress: () => onViewChanged(_DatabaseBoardView.list),
        ),
        const SizedBox(width: 2),
        DesktopHeaderIconButton(
          icon: Icons.grid_view_rounded,
          selected: view == _DatabaseBoardView.grid,
          tooltip: 'Grid view',
          onPress: () => onViewChanged(_DatabaseBoardView.grid),
        ),
      ],
    );

    return LibraryChromeBar(
      icon: Icons.storage_rounded,
      title: 'Library Home',
      titleWidget: _LibraryFolderBreadcrumb(
        folders: folders,
        currentFolderId: currentFolderId,
        localGroupLabel: localGroupLabel,
        onNavigate: onNavigate,
        onNavigateLocalRoot: onNavigateLocalRoot,
      ),
      meta:
          currentFolderId == null &&
                  (localGroupLabel == null || localGroupLabel!.trim().isEmpty)
              ? 'Local & cloud'
              : null,
      trailing: LibraryActionsToolbar(
        onNewFolder: onNewFolder,
        onImportPgnFiles: onImportPgnFiles,
        onNewDatabase: onNewDatabase,
        showLabels: true,
        buttonSize: 28,
        iconSize: 14.5,
        spacing: 4,
        hitSize: 34,
      ),
      bottom: LayoutBuilder(
        builder: (context, constraints) {
          final search = DesktopSearchField(
            controller: searchController,
            hintText: 'Search databases and folders',
            maxWidth: double.infinity,
            onChanged: onQueryChanged,
            onClear: () => onQueryChanged(''),
          );
          if (constraints.maxWidth >= 690) {
            return Row(
              children: [
                Expanded(child: search),
                const SizedBox(width: 12),
                filtersAndView,
              ],
            );
          }
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                SizedBox(width: 260, child: search),
                const SizedBox(width: 10),
                filtersAndView,
              ],
            ),
          );
        },
      ),
    );
  }
}

class _MyDatabasesBoard extends HookConsumerWidget {
  const _MyDatabasesBoard({
    required this.folders,
    required this.currentFolderId,
    required this.currentLocalGroupId,
    required this.localSource,
    required this.selectedFolderId,
    required this.selectedLocalPath,
    required this.isDeletingLocalDatabase,
    required this.onDeleteProgress,
    required this.onSelectFolder,
    required this.onOpenFolder,
    required this.onOpenDatabase,
    required this.onCurrentLocalGroupChanged,
    required this.onSelectLocalPath,
    required this.onOpenLocalPath,
    required this.onDropDatabase,
    required this.query,
    required this.sourceFilter,
    required this.view,
  });

  final List<LibraryFolder> folders;
  final String? currentFolderId;
  final String? currentLocalGroupId;
  final LocalChessSource? localSource;
  final String? selectedFolderId;
  final String? selectedLocalPath;
  final bool isDeletingLocalDatabase;
  final ValueChanged<LocalChessScanProgress?> onDeleteProgress;
  final ValueChanged<LibraryFolder> onSelectFolder;
  final ValueChanged<LibraryFolder> onOpenFolder;
  final ValueChanged<LibraryFolder> onOpenDatabase;
  final ValueChanged<String?> onCurrentLocalGroupChanged;
  final ValueChanged<String> onSelectLocalPath;
  final ValueChanged<String> onOpenLocalPath;
  final Future<void> Function(LibraryDatabaseDragPayload payload)
  onDropDatabase;
  final String query;
  final LibraryDatabaseCatalogSourceFilter sourceFilter;
  final _DatabaseBoardView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cloudCountsAsync = useFuture(
      useMemoized(
        () async {
          final repo = ref.read(libraryRepositoryProvider);
          final entries = <String, int>{};
          entries[kTwicBookId] = await ref.read(
            twicDatabaseTotalGamesProvider.future,
          );
          for (final folder in folders.where((f) => f.id != kTwicBookId)) {
            try {
              entries[folder.id] = await repo.getAnalysisCountInFolder(
                folder.id,
              );
            } catch (_) {
              entries[folder.id] = 0;
            }
          }
          return entries;
        },
        [
          folders
              .map((f) => '${f.id}:${f.updatedAt.millisecondsSinceEpoch}')
              .join('|'),
        ],
      ),
    );
    final counts = cloudCountsAsync.data ?? const <String, int>{};
    final focusState = ref.watch(myDatabasesFocusProvider);
    final hiddenCloudFolderIds = focusState.hiddenCloudFolderIds;
    final pinnedDatabaseKeys = focusState.pinnedDatabaseKeys;
    final localEntries = ref.watch(localLibraryRegistryProvider).entries;

    int? localGameCount(LocalLibraryEntry entry) {
      final source = localSource;
      if (source == null) return entry.gameCount;
      final node = source.root.find(entry.path);
      return switch (node) {
        LocalChessFolderNode(:final gameCount) => gameCount,
        LocalChessFileNode(:final gameCount) => gameCount,
        _ =>
          source.paths.length == 1 && source.paths.contains(entry.path)
              ? source.root.gameCount
              : entry.gameCount,
      };
    }

    final localGroups = _localLibraryEntryGroups(localEntries);
    final currentLocalGroup = localGroups.firstWhereOrNull(
      (group) => group.id == currentLocalGroupId,
    );
    final currentLocalGroupIsPlayerWorkspace =
        currentLocalGroup != null &&
        localLibraryGroupBelongsToPlayerWorkspace(
          groupId: currentLocalGroup.id,
          entries: currentLocalGroup.entries,
        );
    final groupedEntryPaths = <String>{
      for (final group in localGroups)
        for (final entry in group.entries) entry.path,
    };
    final visibleLocalEntries =
        currentLocalGroup != null
            ? currentLocalGroup.entries
            : localEntries
                .where((entry) => !groupedEntryPaths.contains(entry.path))
                .toList(growable: false);
    final visibleCloudFolders = libraryVisibleCloudFolders(
      folders: folders,
      parentId: currentLocalGroup == null ? currentFolderId : null,
      hiddenIds: hiddenCloudFolderIds,
      pinnedIds:
          currentFolderId == null && currentLocalGroup == null
              ? <String>{
                for (final folder in folders)
                  if (pinnedDatabaseKeys.contains(
                    libraryCloudDatabasePinKey(folder.id),
                  ))
                    folder.id,
              }
              : const <String>{},
    );
    final items = <_DatabaseBoardItem>[
      if (currentFolderId == null && currentLocalGroup == null)
        _DatabaseBoardItem.cloud(
          folder: kTwicFolder,
          count: counts[kTwicBookId],
        ),
      if (currentLocalGroup == null)
        for (final folder in visibleCloudFolders)
          _DatabaseBoardItem.cloud(
            folder: folder,
            count: counts[folder.id],
            userPinned: pinnedDatabaseKeys.contains(
              libraryCloudDatabasePinKey(folder.id),
            ),
          ),
      if (currentFolderId == null && currentLocalGroup == null)
        for (final group in localGroups)
          _DatabaseBoardItem.localGroup(
            localGroup: group,
            count: group.gameCount,
            userPinned: pinnedDatabaseKeys.contains('group:${group.id}'),
          ),
      if (currentFolderId == null)
        for (final entry in visibleLocalEntries)
          _DatabaseBoardItem.local(
            entry: entry,
            count: localGameCount(entry),
            userPinned: pinnedDatabaseKeys.contains(
              libraryLocalDatabasePinKey(entry.path),
            ),
          ),
    ];

    int persistedIndex(List<String> order, String key) {
      final index = order.indexOf(key);
      return index < 0 ? 1 << 30 : index;
    }

    int compareItems(_DatabaseBoardItem a, _DatabaseBoardItem b) {
      final byPin = compareLibraryDatabaseCatalogPinState(
        a.isPinned,
        b.isPinned,
      );
      if (byPin != 0) return byPin;
      if (currentFolderId == null && currentLocalGroup == null) {
        final bySection = a
            .sectionRank(folders)
            .compareTo(b.sectionRank(folders));
        if (bySection != 0) return bySection;
      }
      if (currentLocalGroupIsPlayerWorkspace &&
          a.entry != null &&
          b.entry != null) {
        final playerOrder = comparePlayerWorkspaceLibraryEntries(
          a.entry!,
          b.entry!,
        );
        if (playerOrder != 0) return playerOrder;
      }
      final section = a.sectionRank(folders);
      if (section == 0) {
        if (a.isTwic != b.isTwic) return a.isTwic ? -1 : 1;
        final aPermanent = a.folder?.isPermanentLibraryFolder ?? false;
        final bPermanent = b.folder?.isPermanentLibraryFolder ?? false;
        if (aPermanent != bPermanent) return aPermanent ? -1 : 1;
        if (focusState.pinnedOrderCustomized) {
          final byManualOrder = persistedIndex(
            focusState.orderedPinnedDatabaseKeys,
            a.stableKey,
          ).compareTo(
            persistedIndex(focusState.orderedPinnedDatabaseKeys, b.stableKey),
          );
          if (byManualOrder != 0) return byManualOrder;
        }
      } else if (section == 1) {
        final folderOrder = focusState.orderedFolderKeys;
        if (folderOrder.isNotEmpty) {
          final byManualOrder = persistedIndex(
            folderOrder,
            a.stableKey,
          ).compareTo(persistedIndex(folderOrder, b.stableKey));
          if (byManualOrder != 0) return byManualOrder;
        }
      } else {
        final aOpened = focusState.lastOpenedAtByItemKey[a.stableKey];
        final bOpened = focusState.lastOpenedAtByItemKey[b.stableKey];
        if (aOpened != null || bOpened != null) {
          if (aOpened == null) return 1;
          if (bOpened == null) return -1;
          final byOpened = bOpened.compareTo(aOpened);
          if (byOpened != 0) return byOpened;
        }
      }
      final byGames = (b.count ?? -1).compareTo(a.count ?? -1);
      if (byGames != 0) return byGames;
      if (a.isTwic) return -1;
      if (b.isTwic) return 1;
      final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      if (byTitle != 0) return byTitle;
      return a.stableKey.compareTo(b.stableKey);
    }

    items.sort(compareItems);
    final visibleItems = items
        .where((item) {
          final kind = item.iconKind(folders);
          return libraryDatabaseCatalogMatches(
            title: item.title,
            details: '${item.catalogDetails(kind)} ${item.sourceLabel}',
            source: item.catalogSource,
            filter: sourceFilter,
            query: query,
          );
        })
        .toList(growable: false);

    final reorderingEnabled =
        currentFolderId == null &&
        currentLocalGroup == null &&
        query.trim().isEmpty &&
        sourceFilter == LibraryDatabaseCatalogSourceFilter.all;

    bool canReorderItem(_DatabaseBoardItem item) {
      if (!reorderingEnabled) return false;
      final section = item.sectionRank(folders);
      return section == 1 || (section == 0 && item.userPinned);
    }

    Future<void> moveItemBefore(
      String draggedKey,
      _DatabaseBoardItem target,
    ) async {
      if (!canReorderItem(target) || draggedKey == target.stableKey) return;
      final section = target.sectionRank(folders);
      final keys = visibleItems
          .where(
            (item) =>
                item.sectionRank(folders) == section && canReorderItem(item),
          )
          .map((item) => item.stableKey)
          .toList(growable: false);
      final reordered = libraryCatalogReorderedKeys(
        keys,
        draggedKey: draggedKey,
        targetKey: target.stableKey,
      );
      if (listEquals(keys, reordered)) return;
      try {
        final notifier = ref.read(myDatabasesFocusProvider.notifier);
        if (section == 0) {
          await notifier.setPinnedDatabaseOrder(reordered);
        } else {
          await notifier.setFolderOrder(reordered);
        }
      } catch (error) {
        if (!context.mounted) return;
        showDesktopToast(
          context,
          'Could not save the Library Home order.',
          error: true,
        );
      }
    }

    Future<void> previewLocalEntry(LocalLibraryEntry entry) async {
      final opened = await ref
          .read(localChessLibraryProvider.notifier)
          .openPaths(<String>[entry.path], sourceLabel: entry.displayName);
      if (!opened) return;
      final selected = ref.read(localChessLibraryProvider).selectedPath;
      if (selected != null) onSelectLocalPath(selected);
    }

    Future<void> openLocalEntry(LocalLibraryEntry entry) async {
      final opened = await ref
          .read(localChessLibraryProvider.notifier)
          .openPaths(<String>[entry.path], sourceLabel: entry.displayName);
      if (!opened) return;
      final selected = ref.read(localChessLibraryProvider).selectedPath;
      if (selected != null) onOpenLocalPath(selected);
    }

    Future<({bool sourceDeleted})> deleteLocalEntryData(
      LocalLibraryEntry entry, {
      required ValueChanged<LocalChessScanProgress> onProgress,
      bool syncPlayerWorkspace = true,
    }) async {
      final repository = ref.read(localChessDatabaseRepositoryProvider);
      onProgress(
        LocalChessScanProgress(
          fraction: 0.20,
          message: 'Deleting source files...',
        ),
      );
      final sourceDeleted = await deleteLocalSourcePath(entry.path);
      repository.scheduleCachedSourceDelete(sourcePath: entry.path);
      onProgress(
        LocalChessScanProgress(fraction: 0.82, message: 'Updating library...'),
      );
      await ref
          .read(localLibraryRegistryProvider.notifier)
          .unregister(entry.path);
      if (syncPlayerWorkspace) {
        await ref
            .read(playerWorkspaceProvider.notifier)
            .syncDeletedLibraryDatabasePath(
              entry.path,
              playerId: playerWorkspaceIdFromLocalLibraryGroupId(entry.groupId),
            );
      }
      onProgress(
        LocalChessScanProgress(fraction: 1, message: 'Delete complete.'),
      );
      return (sourceDeleted: sourceDeleted);
    }

    void clearOpenLocalSourceIfNeeded(Set<String> deletedPaths) {
      final activeSource = ref.read(localChessLibraryProvider).source;
      if (activeSource == null) return;
      if (activeSource.paths.any(deletedPaths.contains)) {
        ref.read(localChessLibraryProvider.notifier).clear();
      }
    }

    Future<void> removeLocalEntry(LocalLibraryEntry entry) async {
      if (isDeletingLocalDatabase) return;
      void updateDeleteProgress(LocalChessScanProgress progress) {
        onDeleteProgress(progress);
      }

      try {
        updateDeleteProgress(
          LocalChessScanProgress(fraction: 0, message: 'Preparing delete...'),
        );
        localChessLog.info(
          'Local database remove requested',
          context: <String, Object?>{
            'path': entry.path,
            'label': entry.displayName,
          },
        );
        final result = await deleteLocalEntryData(
          entry,
          onProgress: updateDeleteProgress,
        );
        clearOpenLocalSourceIfNeeded(<String>{entry.path});
        localChessLog.info(
          'Local database remove finished',
          context: <String, Object?>{
            'path': entry.path,
            'label': entry.displayName,
            'cacheDeleteQueued': true,
            'sourceDeleted': result.sourceDeleted,
          },
        );
        if (context.mounted) {
          showDesktopToast(
            context,
            result.sourceDeleted
                ? 'Local database deleted from this computer.'
                : 'Local database removed. Source files were already gone.',
          );
        }
      } catch (e, st) {
        localChessLog.error(
          'Local database remove failed',
          e,
          st,
          tag: 'library.remove_local_database',
          context: <String, Object?>{
            'path': entry.path,
            'label': entry.displayName,
          },
        );
        if (context.mounted) {
          showDesktopToast(
            context,
            'Could not delete local database from this computer. Please try again.',
            error: true,
          );
        }
        return;
      } finally {
        onDeleteProgress(null);
      }
    }

    Future<void> removeLocalEntryFromMyDatabases(
      LocalLibraryEntry entry,
    ) async {
      if (isDeletingLocalDatabase) return;

      try {
        localChessLog.info(
          'Local database library removal requested',
          context: <String, Object?>{
            'path': entry.path,
            'label': entry.displayName,
          },
        );
        await ref
            .read(myDatabasesFocusProvider.notifier)
            .unpinDatabase(libraryLocalDatabasePinKey(entry.path));
        await ref
            .read(localLibraryRegistryProvider.notifier)
            .unregister(entry.path);
        clearOpenLocalSourceIfNeeded(<String>{entry.path});
        localChessLog.info(
          'Local database library removal finished',
          context: <String, Object?>{
            'path': entry.path,
            'label': entry.displayName,
            'sourceDeleted': false,
            'cacheDeleted': false,
          },
        );
        if (context.mounted) {
          showDesktopToast(
            context,
            'Removed from Library Home. The original files were not deleted.',
          );
        }
      } catch (e, st) {
        localChessLog.error(
          'Local database library removal failed',
          e,
          st,
          tag: 'library.remove_local_database_reference',
          context: <String, Object?>{
            'path': entry.path,
            'label': entry.displayName,
          },
        );
        if (context.mounted) {
          showDesktopToast(
            context,
            'Could not remove the database from Library Home. Please try again.',
            error: true,
          );
        }
      }
    }

    Future<void> confirmRemoveLocalEntryFromMyDatabases(
      LocalLibraryEntry entry,
    ) async {
      if (isDeletingLocalDatabase) return;
      final confirmed = await showDesktopDialog<bool>(
        context,
        barrierDismissible: true,
        builder: (_) => _ConfirmRemoveLocalDatabaseDialog(entry: entry),
      );
      if (confirmed != true || !context.mounted) return;
      await removeLocalEntryFromMyDatabases(entry);
    }

    Future<void> confirmRemoveLocalEntry(LocalLibraryEntry entry) async {
      if (isDeletingLocalDatabase) return;
      final confirmed = await showDesktopDialog<bool>(
        context,
        barrierDismissible: true,
        builder: (_) => _ConfirmDeleteLocalDatabaseDialog(entry: entry),
      );
      if (confirmed != true || !context.mounted) return;
      await removeLocalEntry(entry);
    }

    Future<void> removeLocalGroup(_LocalLibraryEntryGroup group) async {
      if (isDeletingLocalDatabase || group.entries.isEmpty) return;
      final entries = group.entries.toList(growable: false);
      final playerWorkspaceId = playerWorkspaceIdFromLocalLibraryGroupId(
        group.id,
      );
      final deletedPaths = <String>{};
      final parentDirs = <String>{};
      var sourceDeleted = 0;

      void updateDeleteProgress(LocalChessScanProgress progress) {
        onDeleteProgress(progress);
      }

      try {
        updateDeleteProgress(
          LocalChessScanProgress(
            fraction: 0,
            message: 'Preparing folder delete...',
          ),
        );
        localChessLog.info(
          'Local database folder remove requested',
          context: <String, Object?>{
            'groupId': group.id,
            'label': group.label,
            'databases': entries.length,
          },
        );
        for (var i = 0; i < entries.length; i++) {
          final entry = entries[i];
          deletedPaths.add(entry.path);
          parentDirs.add(p.dirname(entry.path));
          final start = i / entries.length;
          final span = 0.92 / entries.length;
          final result = await deleteLocalEntryData(
            entry,
            syncPlayerWorkspace: false,
            onProgress:
                (progress) => updateDeleteProgress(
                  LocalChessScanProgress(
                    fraction:
                        (start + progress.fraction * span)
                            .clamp(0.0, 0.94)
                            .toDouble(),
                    message:
                        entries.length == 1
                            ? progress.message
                            : '${i + 1}/${entries.length}: ${progress.message}',
                  ),
                ),
          );
          if (result.sourceDeleted) sourceDeleted++;
        }
        updateDeleteProgress(
          LocalChessScanProgress(
            fraction: 0.96,
            message: 'Removing empty player folder...',
          ),
        );
        for (final directory in parentDirs) {
          await deleteLocalSourcePath(directory);
        }
        await ref
            .read(playerWorkspaceProvider.notifier)
            .syncDeletedLibraryPlayerFolder(
              playerWorkspaceId ?? '',
              deletedPaths: deletedPaths,
            );
        clearOpenLocalSourceIfNeeded(deletedPaths);
        if (currentLocalGroupId == group.id) {
          onCurrentLocalGroupChanged(null);
        }
        localChessLog.info(
          'Local database folder remove finished',
          context: <String, Object?>{
            'groupId': group.id,
            'label': group.label,
            'databases': entries.length,
            'cacheDeleteQueued': true,
            'sourceDeleted': sourceDeleted,
          },
        );
        if (context.mounted) {
          showDesktopToast(
            context,
            'Folder "${group.label}" deleted from this computer.',
          );
        }
      } catch (e, st) {
        localChessLog.error(
          'Local database folder remove failed',
          e,
          st,
          tag: 'library.remove_local_database_folder',
          context: <String, Object?>{
            'groupId': group.id,
            'label': group.label,
            'databases': entries.length,
          },
        );
        if (context.mounted) {
          showDesktopToast(
            context,
            'Could not delete local folder from this computer. Please try again.',
            error: true,
          );
        }
      } finally {
        onDeleteProgress(null);
      }
    }

    Future<void> confirmRemoveLocalGroup(_LocalLibraryEntryGroup group) async {
      if (isDeletingLocalDatabase) return;
      final confirmed = await showDesktopDialog<bool>(
        context,
        barrierDismissible: true,
        builder: (_) => _ConfirmDeleteLocalFolderDialog(group: group),
      );
      if (confirmed != true || !context.mounted) return;
      await removeLocalGroup(group);
    }

    Future<void> updateDatabasePin({
      required String key,
      required String title,
      required bool pinned,
    }) async {
      final notifier = ref.read(myDatabasesFocusProvider.notifier);
      try {
        if (pinned) {
          await notifier.pinDatabase(key);
        } else {
          await notifier.unpinDatabase(key);
        }
      } catch (_) {
        if (!context.mounted) return;
        showDesktopToast(
          context,
          pinned ? 'Could not pin "$title".' : 'Could not unpin "$title".',
          error: true,
        );
        return;
      }
      if (!context.mounted) return;
      showDesktopToast(
        context,
        pinned ? 'Pinned "$title".' : 'Unpinned "$title".',
      );
    }

    Future<void> showLocalContextMenu(
      LocalLibraryEntry entry,
      Offset position,
    ) async {
      final pinKey = libraryLocalDatabasePinKey(entry.path);
      final isPinned = pinnedDatabaseKeys.contains(pinKey);
      final picked = await showDesktopContextMenu<_LocalDatabaseBoardAction>(
        context: context,
        position: position,
        width: 260,
        entries: [
          const DesktopContextMenuItem(
            value: _LocalDatabaseBoardAction.preview,
            icon: Icons.table_rows_outlined,
            label: 'Preview database',
          ),
          const DesktopContextMenuItem(
            value: _LocalDatabaseBoardAction.open,
            icon: Icons.open_in_new_rounded,
            label: 'Open full database',
          ),
          const DesktopContextMenuDivider(),
          DesktopContextMenuItem(
            value:
                isPinned
                    ? _LocalDatabaseBoardAction.unpin
                    : _LocalDatabaseBoardAction.pin,
            icon: isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
            label: isPinned ? 'Unpin database' : 'Pin database',
          ),
          const DesktopContextMenuDivider(),
          const DesktopContextMenuItem(
            value: _LocalDatabaseBoardAction.removeFromLibraryHome,
            icon: Icons.remove_circle_outline_rounded,
            label: 'Remove from Library Home',
          ),
          const DesktopContextMenuDivider(),
          const DesktopContextMenuItem(
            value: _LocalDatabaseBoardAction.deleteFromComputer,
            icon: Icons.delete_forever_outlined,
            label: 'Delete from computer',
            destructive: true,
          ),
        ],
      );
      if (picked == null || !context.mounted) return;
      switch (picked) {
        case _LocalDatabaseBoardAction.preview:
          await previewLocalEntry(entry);
        case _LocalDatabaseBoardAction.open:
          await openLocalEntry(entry);
        case _LocalDatabaseBoardAction.pin:
          await updateDatabasePin(
            key: pinKey,
            title: entry.displayName,
            pinned: true,
          );
        case _LocalDatabaseBoardAction.unpin:
          await updateDatabasePin(
            key: pinKey,
            title: entry.displayName,
            pinned: false,
          );
        case _LocalDatabaseBoardAction.removeFromLibraryHome:
          await confirmRemoveLocalEntryFromMyDatabases(entry);
        case _LocalDatabaseBoardAction.deleteFromComputer:
          await confirmRemoveLocalEntry(entry);
      }
    }

    Future<void> removeLocalGroupFromLibraryHome(
      _LocalLibraryEntryGroup group,
    ) async {
      if (isDeletingLocalDatabase) return;
      try {
        await ref
            .read(myDatabasesFocusProvider.notifier)
            .unpinDatabase('group:${group.id}');
        for (final entry in group.entries) {
          await ref
              .read(localLibraryRegistryProvider.notifier)
              .unregister(entry.path);
        }
        clearOpenLocalSourceIfNeeded(
          group.entries.map((entry) => entry.path).toSet(),
        );
        if (currentLocalGroupId == group.id) {
          onCurrentLocalGroupChanged(null);
        }
        if (context.mounted) {
          showDesktopToast(
            context,
            'Removed "${group.label}" from Library Home. Files were not deleted.',
          );
        }
      } catch (error) {
        if (context.mounted) {
          showDesktopToast(
            context,
            'Could not remove "${group.label}" from Library Home.',
            error: true,
          );
        }
      }
    }

    Future<void> showLocalGroupContextMenu(
      _LocalLibraryEntryGroup group,
      Offset position,
    ) async {
      final pinKey = 'group:${group.id}';
      final isPinned = pinnedDatabaseKeys.contains(pinKey);
      final picked = await showDesktopContextMenu<_LocalGroupBoardAction>(
        context: context,
        position: position,
        width: 260,
        entries: [
          const DesktopContextMenuItem(
            value: _LocalGroupBoardAction.open,
            icon: Icons.folder_open_outlined,
            label: 'Open folder',
          ),
          const DesktopContextMenuDivider(),
          DesktopContextMenuItem(
            value:
                isPinned
                    ? _LocalGroupBoardAction.unpin
                    : _LocalGroupBoardAction.pin,
            icon: isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
            label: isPinned ? 'Unpin folder' : 'Pin folder',
          ),
          const DesktopContextMenuDivider(),
          DesktopContextMenuItem(
            value: _LocalGroupBoardAction.removeFromLibraryHome,
            icon: Icons.remove_circle_outline_rounded,
            label: 'Remove from Library Home',
          ),
          const DesktopContextMenuDivider(),
          const DesktopContextMenuItem(
            value: _LocalGroupBoardAction.deleteFromComputer,
            icon: Icons.delete_forever_outlined,
            label: 'Delete from computer',
            destructive: true,
          ),
        ],
      );
      if (picked == null || !context.mounted) return;
      switch (picked) {
        case _LocalGroupBoardAction.open:
          onCurrentLocalGroupChanged(group.id);
        case _LocalGroupBoardAction.pin:
          await updateDatabasePin(
            key: pinKey,
            title: group.label,
            pinned: true,
          );
        case _LocalGroupBoardAction.unpin:
          await updateDatabasePin(
            key: pinKey,
            title: group.label,
            pinned: false,
          );
        case _LocalGroupBoardAction.removeFromLibraryHome:
          await removeLocalGroupFromLibraryHome(group);
        case _LocalGroupBoardAction.deleteFromComputer:
          await confirmRemoveLocalGroup(group);
      }
    }

    Future<void> removeCloudFolderFromBoard(LibraryFolder folder) async {
      if (!libraryCanRemoveCloudFolderFromBoard(folder)) return;
      try {
        await ref
            .read(myDatabasesFocusProvider.notifier)
            .hideCloudFolder(folder.id);
        if (selectedFolderId == folder.id && selectedLocalPath == null) {
          onSelectFolder(kTwicFolder);
        }
        if (context.mounted) {
          showDesktopToast(
            context,
            'Removed "${folder.name}" from Library Home.',
          );
        }
      } catch (error, stackTrace) {
        ErrorReporter.report(
          error,
          stackTrace: stackTrace,
          tag: 'library.remove_database_from_home',
        );
        if (context.mounted) {
          showDesktopToast(
            context,
            'Could not remove "${folder.name}" from Library Home.',
            error: true,
          );
        }
      }
    }

    Future<void> showCloudContextMenu(
      LibraryFolder folder,
      Offset position,
    ) async {
      if (folder.id == kTwicBookId) return;
      final pinKey = libraryCloudDatabasePinKey(folder.id);
      final isPinned = pinnedDatabaseKeys.contains(pinKey);
      final canChangePin = !folder.isPermanentLibraryFolder;
      final canRemove = libraryCanRemoveCloudFolderFromBoard(folder);
      final picked = await showDesktopContextMenu<_CloudDatabaseBoardAction>(
        context: context,
        position: position,
        width: 260,
        entries: [
          const DesktopContextMenuItem(
            value: _CloudDatabaseBoardAction.preview,
            icon: Icons.table_rows_outlined,
            label: 'Preview database',
          ),
          const DesktopContextMenuItem(
            value: _CloudDatabaseBoardAction.open,
            icon: Icons.open_in_new_rounded,
            label: 'Open full database',
          ),
          if (canChangePin) ...[
            const DesktopContextMenuDivider(),
            DesktopContextMenuItem(
              value:
                  isPinned
                      ? _CloudDatabaseBoardAction.unpin
                      : _CloudDatabaseBoardAction.pin,
              icon: isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
              label: isPinned ? 'Unpin database' : 'Pin database',
            ),
          ],
          if (canRemove) ...[
            const DesktopContextMenuDivider(),
            const DesktopContextMenuItem(
              value: _CloudDatabaseBoardAction.remove,
              icon: Icons.delete_outline_rounded,
              label: 'Remove from Library Home',
            ),
          ],
        ],
      );
      if (picked == null || !context.mounted) return;
      switch (picked) {
        case _CloudDatabaseBoardAction.preview:
          onSelectFolder(folder);
        case _CloudDatabaseBoardAction.open:
          onOpenDatabase(folder);
        case _CloudDatabaseBoardAction.pin:
          await updateDatabasePin(
            key: pinKey,
            title: folder.name,
            pinned: true,
          );
        case _CloudDatabaseBoardAction.unpin:
          await updateDatabasePin(
            key: pinKey,
            title: folder.name,
            pinned: false,
          );
        case _CloudDatabaseBoardAction.remove:
          await removeCloudFolderFromBoard(folder);
      }
    }

    void showCloudFolderContextMenu(LibraryFolder folder, Offset position) {
      final pinKey = libraryCloudDatabasePinKey(folder.id);
      showLibraryFolderActionsMenu(
        context: context,
        anchor: position,
        folder: folder,
        canCreateDatabase:
            !folder.isSubscribed &&
            !libraryFolderIsDatabase(
              folder,
              folders,
              gameCount: counts[folder.id],
            ),
        hasGames: (counts[folder.id] ?? 0) > 0,
        includeLibraryHomeAction: true,
        isShownOnLibraryHome: true,
        isPinned: pinnedDatabaseKeys.contains(pinKey),
        onPinnedChanged:
            (pinned) => unawaited(
              updateDatabasePin(
                key: pinKey,
                title: folder.name,
                pinned: pinned,
              ),
            ),
        onAction:
            (action) => unawaited(
              _onFolderAction(
                context: context,
                ref: ref,
                folder: folder,
                action: action,
                allFolders: folders,
              ),
            ),
      );
    }

    Widget buildBoardTile(_DatabaseBoardItem item) {
      final folder = item.folder;
      final entry = item.entry;
      final localGroup = item.localGroup;
      final iconKind = item.iconKind(folders);
      final isFolder = iconKind == _DatabaseBoardIconKind.folder;
      final tile = _DatabaseBoardTile(
        title: item.title,
        subtitle: item.subtitleForKind(iconKind),
        iconKind: iconKind,
        pinned: item.isPinned,
        selected:
            folder != null
                ? folder.id == selectedFolderId && selectedLocalPath == null
                : localGroup != null
                ? currentLocalGroup?.id == localGroup.id
                : selectedLocalPath == entry!.path ||
                    (localSource?.paths.contains(entry.path) == true &&
                        selectedLocalPath == localSource?.root.path),
        onSelect:
            folder != null
                ? () => onSelectFolder(folder)
                : localGroup != null
                ? () => onCurrentLocalGroupChanged(localGroup.id)
                : () => unawaited(previewLocalEntry(entry!)),
        onOpen:
            folder != null
                ? () {
                  if (isFolder) {
                    onOpenFolder(folder);
                  } else {
                    onOpenDatabase(folder);
                  }
                }
                : localGroup != null
                ? () => onCurrentLocalGroupChanged(localGroup.id)
                : () => unawaited(openLocalEntry(entry!)),
        onContextMenu:
            folder != null
                ? (folder.id == kTwicBookId
                    ? null
                    : isFolder
                    ? (position) => showCloudFolderContextMenu(folder, position)
                    : (position) =>
                        unawaited(showCloudContextMenu(folder, position)))
                : localGroup != null
                ? (position) =>
                    unawaited(showLocalGroupContextMenu(localGroup, position))
                : (position) =>
                    unawaited(showLocalContextMenu(entry!, position)),
      );
      if (folder == null) return tile;
      return FolderDropTarget(
        enabled: isWritableLibraryFolder(folder),
        folderName: folder.name,
        onAcceptPaths:
            (paths) => quickImportPathsToFolder(
              context: context,
              ref: ref,
              folder: folder,
              paths: paths,
            ),
        child: tile,
      );
    }

    Widget buildBoardRow(
      _DatabaseBoardItem item,
      LibraryDatabaseCatalogColumns columns,
    ) {
      final folder = item.folder;
      final entry = item.entry;
      final localGroup = item.localGroup;
      final iconKind = item.iconKind(folders);
      final isFolder = iconKind == _DatabaseBoardIconKind.folder;
      final lastOpened = focusState.lastOpenedAtByItemKey[item.stableKey];
      final row = _DatabaseBoardRow(
        title: item.title,
        details: item.catalogDetails(iconKind),
        source: item.sourceLabel,
        lastOpened: lastOpened == null ? 'Never' : _relativeTime(lastOpened),
        iconKind: iconKind,
        columns: columns,
        pinned: item.isPinned,
        selected:
            folder != null
                ? folder.id == selectedFolderId && selectedLocalPath == null
                : localGroup != null
                ? currentLocalGroup?.id == localGroup.id
                : selectedLocalPath == entry!.path ||
                    (localSource?.paths.contains(entry.path) == true &&
                        selectedLocalPath == localSource?.root.path),
        onSelect:
            folder != null
                ? () => onSelectFolder(folder)
                : localGroup != null
                ? () => onCurrentLocalGroupChanged(localGroup.id)
                : () => unawaited(previewLocalEntry(entry!)),
        onOpen:
            folder != null
                ? () {
                  if (isFolder) {
                    onOpenFolder(folder);
                  } else {
                    onOpenDatabase(folder);
                  }
                }
                : localGroup != null
                ? () => onCurrentLocalGroupChanged(localGroup.id)
                : () => unawaited(openLocalEntry(entry!)),
        onContextMenu:
            folder != null
                ? (folder.id == kTwicBookId
                    ? null
                    : isFolder
                    ? (position) => showCloudFolderContextMenu(folder, position)
                    : (position) =>
                        unawaited(showCloudContextMenu(folder, position)))
                : localGroup != null
                ? (position) =>
                    unawaited(showLocalGroupContextMenu(localGroup, position))
                : (position) =>
                    unawaited(showLocalContextMenu(entry!, position)),
        reorderKey: canReorderItem(item) ? item.stableKey : null,
        onMoveBefore:
            canReorderItem(item)
                ? (draggedKey) => unawaited(moveItemBefore(draggedKey, item))
                : null,
      );
      if (folder == null) return row;
      return FolderDropTarget(
        enabled: isWritableLibraryFolder(folder),
        folderName: folder.name,
        onAcceptPaths:
            (paths) => quickImportPathsToFolder(
              context: context,
              ref: ref,
              folder: folder,
              paths: paths,
            ),
        child: row,
      );
    }

    return DragTarget<LibraryDatabaseDragPayload>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => onDropDatabase(details.data),
      builder: (context, candidates, _) {
        final isHovering = candidates.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          color: kBlackColor,
          foregroundDecoration:
              isHovering
                  ? BoxDecoration(
                    border: Border.all(
                      color: kPrimaryColor.withValues(alpha: 0.70),
                      width: 2,
                    ),
                  )
                  : null,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = libraryDatabaseCatalogColumns(
                constraints.maxWidth,
                savedWidths: focusState.catalogColumnWidths,
              );
              final filteredOut = items.isNotEmpty && visibleItems.isEmpty;
              final empty = _LibraryEmpty(
                icon:
                    filteredOut
                        ? Icons.search_off_rounded
                        : Icons.folder_open_outlined,
                title:
                    filteredOut
                        ? 'No matching databases'
                        : 'This section is empty',
                message:
                    filteredOut
                        ? 'Try another search or source filter.'
                        : currentLocalGroup == null
                        ? 'Import PGN files or create a cloud database.'
                        : (currentLocalGroupIsPlayerWorkspace
                            ? 'Import PGN files or add player sources from Players.'
                            : 'Import PGN files here.'),
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child:
                        view == _DatabaseBoardView.grid
                            ? ListView(
                              physics: const DesktopScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
                              children: [
                                if (visibleItems.isNotEmpty)
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 10,
                                    children: [
                                      for (final item in visibleItems)
                                        buildBoardTile(item),
                                    ],
                                  )
                                else
                                  Padding(
                                    padding: const EdgeInsets.only(top: 28),
                                    child: empty,
                                  ),
                              ],
                            )
                            : Container(
                              margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                              clipBehavior: Clip.antiAlias,
                              decoration: BoxDecoration(
                                color: kBlack2Color,
                                borderRadius: BorderRadius.circular(9),
                                border: Border.all(color: kDividerColor),
                              ),
                              child: Column(
                                children: [
                                  _DatabaseBoardListHeader(
                                    columns: columns,
                                    onColumnWidthChanged: (key, width) {
                                      unawaited(
                                        ref
                                            .read(
                                              myDatabasesFocusProvider.notifier,
                                            )
                                            .setCatalogColumnWidth(key, width)
                                            .catchError((Object error) {
                                              if (kDebugMode) {
                                                debugPrint(
                                                  'Library Home column width '
                                                  'persist failed: $error',
                                                );
                                              }
                                            }),
                                      );
                                    },
                                    onResetWidths: () {
                                      unawaited(
                                        ref
                                            .read(
                                              myDatabasesFocusProvider.notifier,
                                            )
                                            .resetCatalogColumnWidths()
                                            .catchError((Object error) {
                                              if (kDebugMode) {
                                                debugPrint(
                                                  'Library Home column reset '
                                                  'failed: $error',
                                                );
                                              }
                                            }),
                                      );
                                    },
                                  ),
                                  Expanded(
                                    child:
                                        visibleItems.isEmpty
                                            ? Center(child: empty)
                                            : ListView.builder(
                                              physics:
                                                  const DesktopScrollPhysics(),
                                              itemCount: visibleItems.length,
                                              itemBuilder: (context, index) {
                                                final item =
                                                    visibleItems[index];
                                                final previous =
                                                    index == 0
                                                        ? null
                                                        : visibleItems[index -
                                                            1];
                                                final section = item
                                                    .sectionLabel(folders);
                                                final showSection =
                                                    currentFolderId == null &&
                                                    currentLocalGroup == null &&
                                                    (previous == null ||
                                                        previous.sectionLabel(
                                                              folders,
                                                            ) !=
                                                            section);
                                                return Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment
                                                          .stretch,
                                                  children: [
                                                    if (showSection)
                                                      _DatabaseBoardSectionLabel(
                                                        label: section,
                                                      ),
                                                    buildBoardRow(
                                                      item,
                                                      columns,
                                                    ),
                                                  ],
                                                );
                                              },
                                            ),
                                  ),
                                ],
                              ),
                            ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _LibraryFolderBreadcrumb extends StatelessWidget {
  const _LibraryFolderBreadcrumb({
    required this.folders,
    required this.currentFolderId,
    required this.localGroupLabel,
    required this.onNavigate,
    required this.onNavigateLocalRoot,
  });

  final List<LibraryFolder> folders;
  final String? currentFolderId;
  final String? localGroupLabel;
  final ValueChanged<String?> onNavigate;
  final VoidCallback? onNavigateLocalRoot;

  @override
  Widget build(BuildContext context) {
    final path = libraryFolderPath(folders, currentFolderId);
    final current = path.isEmpty ? null : path.last;
    final localLabel = localGroupLabel?.trim();
    return Semantics(
      label: libraryMyDatabasesBreadcrumbText(
        folders: folders,
        currentFolderId: currentFolderId,
        localGroupLabel: localGroupLabel,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FButton(
              style: FButtonStyle.ghost(),
              onPress:
                  currentFolderId == null && localLabel == null
                      ? null
                      : () {
                        onNavigateLocalRoot?.call();
                        onNavigate(null);
                      },
              child: const Text('Library Home'),
            ),
            if (localLabel != null && localLabel.isNotEmpty) ...[
              const _LibraryBreadcrumbChevron(),
              FButton(
                style: FButtonStyle.ghost(),
                onPress: null,
                child: Text(
                  localLabel,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
            for (final folder in path) ...[
              const _LibraryBreadcrumbChevron(),
              FButton(
                style: FButtonStyle.ghost(),
                onPress:
                    folder.id == currentFolderId
                        ? null
                        : () => onNavigate(folder.id),
                child: Text(
                  folder.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        folder.id == current?.id ? kWhiteColor : kWhiteColor70,
                    fontWeight:
                        folder.id == current?.id
                            ? FontWeight.w700
                            : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LibraryBreadcrumbChevron extends StatelessWidget {
  const _LibraryBreadcrumbChevron();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 2),
      child: Icon(
        Icons.chevron_right_rounded,
        color: kLightGreyColor,
        size: 15,
      ),
    );
  }
}

class _LibraryBlockingProgressOverlay extends StatelessWidget {
  const _LibraryBlockingProgressOverlay({
    required this.title,
    required this.progress,
  });

  final String title;
  final LocalChessScanProgress progress;

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      child: ColoredBox(
        color: kBlackColor.withValues(alpha: 0.72),
        child: Center(
          child: Container(
            width: 340,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: kBlack3Color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kDividerColor),
              boxShadow: [
                BoxShadow(
                  color: kBlackColor.withValues(alpha: 0.35),
                  blurRadius: 24,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        value:
                            progress.fraction <= 0 || progress.fraction >= 1
                                ? null
                                : progress.fraction,
                        valueColor: const AlwaysStoppedAnimation(kPrimaryColor),
                        backgroundColor: kWhiteColor.withValues(alpha: 0.10),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${progress.percent}%',
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    minHeight: 4,
                    value: progress.fraction,
                    backgroundColor: kWhiteColor.withValues(alpha: 0.10),
                    valueColor: const AlwaysStoppedAnimation(kPrimaryColor),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  progress.message,
                  style: const TextStyle(color: kWhiteColor70, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConfirmDeleteLocalDatabaseDialog extends StatelessWidget {
  const _ConfirmDeleteLocalDatabaseDialog({required this.entry});

  final LocalLibraryEntry entry;

  @override
  Widget build(BuildContext context) {
    final isPlayerDatabase = localLibraryEntryBelongsToPlayerWorkspace(entry);
    final playerLabel = entry.groupLabel?.trim();
    final details =
        isPlayerDatabase
            ? 'This deletes the local database source and its generated cache from this computer. It also removes this source from ${playerLabel == null || playerLabel.isEmpty ? 'the player' : playerLabel} in Players.\n\nDeleting sources one by one leaves the player in Players. Only deleting the whole player folder removes the player.\n\n${entry.path}'
            : 'This deletes the local database source and its generated cache from this computer. This cannot be undone.\n\n${entry.path}';
    return Center(
      child: Container(
        width: 440,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kDividerColor),
          boxShadow: [
            BoxShadow(
              color: kBlackColor.withValues(alpha: 0.42),
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
                  color: kRedColor,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Delete ${entry.displayName} from computer?',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              details,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                DesktopDialogButton(
                  label: 'Cancel',
                  icon: Icons.close_rounded,
                  onPress: () => Navigator.of(context).pop(false),
                ),
                const SizedBox(width: 8),
                DesktopDialogButton(
                  label: 'Delete',
                  icon: Icons.delete_outline_rounded,
                  tone: DesktopDialogButtonTone.danger,
                  onPress: () => Navigator.of(context).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfirmRemoveLocalDatabaseDialog extends StatelessWidget {
  const _ConfirmRemoveLocalDatabaseDialog({required this.entry});

  final LocalLibraryEntry entry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 440,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kDividerColor),
          boxShadow: [
            BoxShadow(
              color: kBlackColor.withValues(alpha: 0.42),
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
                  Icons.remove_circle_outline_rounded,
                  color: kPrimaryColor,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Remove ${entry.displayName}?',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'This removes the database from Library Home only. The original '
              'files stay on your computer and can be added again later.\n\n'
              '${entry.path}',
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                DesktopDialogButton(
                  label: 'Cancel',
                  icon: Icons.close_rounded,
                  onPress: () => Navigator.of(context).pop(false),
                ),
                const SizedBox(width: 8),
                DesktopDialogButton(
                  label: 'Remove',
                  icon: Icons.remove_circle_outline_rounded,
                  onPress: () => Navigator.of(context).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfirmDeleteLocalFolderDialog extends StatelessWidget {
  const _ConfirmDeleteLocalFolderDialog({required this.group});

  final _LocalLibraryEntryGroup group;

  @override
  Widget build(BuildContext context) {
    final count = group.entries.length;
    final databaseLabel = count == 1 ? 'database' : 'databases';
    final isPlayerFolder = localLibraryGroupBelongsToPlayerWorkspace(
      groupId: group.id,
      entries: group.entries,
    );
    final details =
        isPlayerFolder
            ? 'This is a Players folder. Deleting it removes ${group.label} from Players and deletes all $count local $databaseLabel, generated cache, and PGN files from this computer. This cannot be undone.'
            : 'This deletes all $count local $databaseLabel in this folder, '
                'their generated cache, and their PGN files from this computer. '
                'This cannot be undone.';
    return Center(
      child: Container(
        width: 460,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kDividerColor),
          boxShadow: [
            BoxShadow(
              color: kBlackColor.withValues(alpha: 0.42),
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
                  color: kRedColor,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Delete ${group.label}?',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              details,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                DesktopDialogButton(
                  label: 'Cancel',
                  icon: Icons.close_rounded,
                  onPress: () => Navigator.of(context).pop(false),
                ),
                const SizedBox(width: 8),
                DesktopDialogButton(
                  label: 'Delete folder',
                  icon: Icons.delete_outline_rounded,
                  tone: DesktopDialogButtonTone.danger,
                  onPress: () => Navigator.of(context).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DatabaseBoardItem {
  const _DatabaseBoardItem.cloud({
    required this.folder,
    required this.count,
    this.userPinned = false,
  }) : entry = null,
       localGroup = null;

  const _DatabaseBoardItem.local({
    required this.entry,
    required this.count,
    this.userPinned = false,
  }) : folder = null,
       localGroup = null;

  const _DatabaseBoardItem.localGroup({
    required this.localGroup,
    required this.count,
    this.userPinned = false,
  }) : folder = null,
       entry = null;

  final LibraryFolder? folder;
  final LocalLibraryEntry? entry;
  final _LocalLibraryEntryGroup? localGroup;
  final int? count;
  final bool userPinned;

  bool get isTwic => folder?.id == kTwicBookId;

  bool get isPinned =>
      userPinned || isTwic || (folder?.isPermanentLibraryFolder ?? false);

  String get stableKey {
    final cloudFolder = folder;
    if (cloudFolder != null) return 'cloud:${cloudFolder.id}';
    final localEntry = entry;
    if (localEntry != null) return libraryLocalDatabasePinKey(localEntry.path);
    return 'group:${localGroup!.id}';
  }

  LibraryDatabaseCatalogSource get catalogSource {
    return folder == null
        ? LibraryDatabaseCatalogSource.local
        : LibraryDatabaseCatalogSource.cloud;
  }

  String get sourceLabel {
    return catalogSource == LibraryDatabaseCatalogSource.cloud
        ? 'Cloud'
        : 'Local';
  }

  String get title => folder?.name ?? localGroup?.label ?? entry!.displayName;

  String catalogDetails(_DatabaseBoardIconKind kind) {
    final group = localGroup;
    if (group != null) {
      final databaseCount = group.entries.length;
      final databaseLabel = databaseCount == 1 ? 'database' : 'databases';
      final games = count;
      if (games == null) return '$databaseCount $databaseLabel';
      return '$databaseCount $databaseLabel · '
          '${formatCompactCount(games)} ${games == 1 ? 'game' : 'games'}';
    }
    final games = count;
    final gamesLabel =
        games == null
            ? (entry == null ? '' : 'Not indexed')
            : '${formatCompactCount(games)} ${games == 1 ? 'game' : 'games'}';
    if (kind == _DatabaseBoardIconKind.subscribedDatabase &&
        gamesLabel.isNotEmpty) {
      return '$gamesLabel · read-only';
    }
    return gamesLabel;
  }

  int sectionRank(List<LibraryFolder> folders) {
    if (isPinned) return 0;
    if (iconKind(folders) == _DatabaseBoardIconKind.folder) return 1;
    return 2;
  }

  String sectionLabel(List<LibraryFolder> folders) {
    return switch (sectionRank(folders)) {
      0 => 'Pinned',
      1 => 'Folders',
      _ => 'Databases',
    };
  }

  String? get subtitle {
    final group = localGroup;
    if (group != null) {
      final databases = group.entries.length;
      final databaseLabel = databases == 1 ? 'database' : 'databases';
      final games = count;
      if (games == null) return '$databases $databaseLabel';
      final gameLabel = games == 1 ? 'game' : 'games';
      return '$databases $databaseLabel · ${formatCompactCount(games)} $gameLabel';
    }
    final localEntry = entry;
    if (localEntry != null) {
      return localLibraryEntryStatusLine(localEntry, count: count);
    }
    return null;
  }

  /// Kind-aware fallback when [subtitle] is null (typical cloud folders).
  String? subtitleForKind(_DatabaseBoardIconKind kind) {
    final existing = subtitle;
    if (existing != null && existing.isNotEmpty) return existing;
    final games = count;
    final gamesLabel =
        games == null
            ? null
            : '${formatCompactCount(games)} ${games == 1 ? 'game' : 'games'}';
    return switch (kind) {
      _DatabaseBoardIconKind.folder => gamesLabel,
      _DatabaseBoardIconKind.twic => gamesLabel,
      _DatabaseBoardIconKind.subscribedDatabase =>
        gamesLabel == null ? 'Read-only' : '$gamesLabel · read-only',
      _DatabaseBoardIconKind.localDatabase => gamesLabel,
      _DatabaseBoardIconKind.cloudDatabase => gamesLabel,
    };
  }

  _DatabaseBoardIconKind iconKind(List<LibraryFolder> folders) {
    final f = folder;
    if (localGroup != null) return _DatabaseBoardIconKind.folder;
    if (f == null) return _DatabaseBoardIconKind.localDatabase;
    return _cloudFolderIconKind(f, folders, gameCount: count);
  }
}

/// Stable database ordering inside a Players-generated Library folder.
///
/// Kept as a public test seam because this ordering is part of the
/// Players↔Library synchronization contract.
@visibleForTesting
int comparePlayerWorkspaceLibraryEntries(
  LocalLibraryEntry a,
  LocalLibraryEntry b,
) {
  final aCombined = localLibraryEntryIsPlayerWorkspaceCombined(a);
  final bCombined = localLibraryEntryIsPlayerWorkspaceCombined(b);
  if (aCombined != bCombined) return aCombined ? -1 : 1;
  final byName = a.displayName.toLowerCase().compareTo(
    b.displayName.toLowerCase(),
  );
  if (byName != 0) return byName;
  return a.path.toLowerCase().compareTo(b.path.toLowerCase());
}

class _LocalLibraryEntryGroup {
  const _LocalLibraryEntryGroup({
    required this.id,
    required this.label,
    required this.entries,
  });

  final String id;
  final String label;
  final List<LocalLibraryEntry> entries;

  int? get gameCount {
    var total = 0;
    var hasAny = false;
    for (final entry in entries) {
      final count = entry.gameCount;
      if (count == null) continue;
      total += count;
      hasAny = true;
    }
    return hasAny ? total : null;
  }
}

List<_LocalLibraryEntryGroup> _localLibraryEntryGroups(
  List<LocalLibraryEntry> entries,
) {
  final byId = <String, List<LocalLibraryEntry>>{};
  final labels = <String, String>{};
  for (final entry in entries) {
    final groupId = entry.groupId?.trim();
    if (groupId == null || groupId.isEmpty) continue;
    byId.putIfAbsent(groupId, () => <LocalLibraryEntry>[]).add(entry);
    final label = entry.groupLabel?.trim();
    if (label != null && label.isNotEmpty) labels[groupId] = label;
  }
  final groups = <_LocalLibraryEntryGroup>[
    for (final item in byId.entries)
      _LocalLibraryEntryGroup(
        id: item.key,
        label: labels[item.key] ?? 'Player databases',
        entries: item.value,
      ),
  ];
  groups.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  return groups;
}

@visibleForTesting
bool localLibraryEntryBelongsToPlayerWorkspace(LocalLibraryEntry entry) {
  if (playerWorkspaceIdFromLocalLibraryGroupId(entry.groupId) != null) {
    return true;
  }
  return localLibraryPathBelongsToPlayerWorkspace(entry.path);
}

@visibleForTesting
bool localLibraryGroupBelongsToPlayerWorkspace({
  required String groupId,
  required List<LocalLibraryEntry> entries,
}) {
  if (playerWorkspaceIdFromLocalLibraryGroupId(groupId) != null) {
    return true;
  }
  return entries.any(localLibraryEntryBelongsToPlayerWorkspace);
}

@visibleForTesting
bool localLibraryPathBelongsToPlayerWorkspace(String path) {
  final parts = p.split(p.normalize(path));
  final index = parts.lastIndexWhere((part) => part == 'player-workspace');
  return index >= 0 && index + 1 < parts.length;
}

_DatabaseBoardIconKind _cloudFolderIconKind(
  LibraryFolder folder,
  List<LibraryFolder> folders, {
  int? gameCount,
}) {
  if (folder.id == kTwicBookId) return _DatabaseBoardIconKind.twic;
  if (!libraryFolderIsDatabase(folder, folders, gameCount: gameCount)) {
    return _DatabaseBoardIconKind.folder;
  }
  if (folder.isSubscribed) return _DatabaseBoardIconKind.subscribedDatabase;
  return _DatabaseBoardIconKind.cloudDatabase;
}

bool _isLibraryDatabase(LibraryFolder folder, List<LibraryFolder> folders) {
  return libraryFolderIsDatabase(folder, folders);
}

@visibleForTesting
bool libraryCanRemoveCloudFolderFromBoard(LibraryFolder folder) {
  return folder.id != kTwicBookId && !folder.isPermanentLibraryFolder;
}

bool libraryFolderIsDatabase(
  LibraryFolder folder,
  List<LibraryFolder> folders, {
  int? gameCount,
}) {
  if (folder.icon == 'database' || folder.icon == 'twic') return true;
  if (_isKnownRootDatabase(folder) &&
      !libraryFolderHasChildren(folders, folder.id)) {
    return true;
  }
  if (folder.icon != 'folder') return false;
  if (libraryFolderHasChildren(folders, folder.id)) return false;
  if (folder.parentId != null) return true;
  return gameCount != null && gameCount > 0;
}

bool _isKnownRootDatabase(LibraryFolder folder) {
  return folder.name.trim().toLowerCase() == 'liked games';
}

enum _DatabaseBoardIconKind {
  cloudDatabase,
  folder,
  localDatabase,
  subscribedDatabase,
  twic,
}

/// Visual hierarchy for Library containers:
/// - **Folder** (amber): can hold folders + databases
/// - **Database** (primary/cyan): holds games only
@immutable
class _LibraryKindChrome {
  const _LibraryKindChrome({
    required this.accent,
    required this.wellFill,
    required this.wellBorder,
    required this.kindLabel,
    required this.kindHint,
  });

  final Color accent;
  final Color wellFill;
  final Color wellBorder;
  final String kindLabel;
  final String kindHint;

  static const Color folderAmber = Color(0xFFF5A524);
  static const Color databaseCyan = Color(0xFF38BDF8);
  static const Color localViolet = Color(0xFFA78BFA);
  static const Color twicTeal = Color(0xFF2DD4BF);

  static _LibraryKindChrome forKind(_DatabaseBoardIconKind kind) {
    return switch (kind) {
      _DatabaseBoardIconKind.folder => _LibraryKindChrome(
        accent: folderAmber,
        wellFill: folderAmber.withValues(alpha: 0.14),
        wellBorder: folderAmber.withValues(alpha: 0.42),
        kindLabel: 'Folder',
        kindHint: 'Holds folders & databases',
      ),
      _DatabaseBoardIconKind.localDatabase => _LibraryKindChrome(
        accent: localViolet,
        wellFill: localViolet.withValues(alpha: 0.14),
        wellBorder: localViolet.withValues(alpha: 0.42),
        kindLabel: 'Local DB',
        kindHint: 'Games only',
      ),
      _DatabaseBoardIconKind.subscribedDatabase => _LibraryKindChrome(
        accent: databaseCyan,
        wellFill: databaseCyan.withValues(alpha: 0.12),
        wellBorder: databaseCyan.withValues(alpha: 0.40),
        kindLabel: 'Cloud DB',
        kindHint: 'Read-only games',
      ),
      _DatabaseBoardIconKind.twic => _LibraryKindChrome(
        accent: twicTeal,
        wellFill: twicTeal.withValues(alpha: 0.12),
        wellBorder: twicTeal.withValues(alpha: 0.40),
        kindLabel: 'System',
        kindHint: 'ChessEver archive',
      ),
      _DatabaseBoardIconKind.cloudDatabase => _LibraryKindChrome(
        accent: kPrimaryColor,
        wellFill: kPrimaryColor.withValues(alpha: 0.12),
        wellBorder: kPrimaryColor.withValues(alpha: 0.40),
        kindLabel: 'Database',
        kindHint: 'Games only',
      ),
    };
  }
}

class _DatabaseBoardIcon extends StatelessWidget {
  const _DatabaseBoardIcon({
    required this.kind,
    required this.color,
    this.size = 20,
  });

  final _DatabaseBoardIconKind kind;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return switch (kind) {
      _DatabaseBoardIconKind.folder => _FolderHierarchyGlyph(
        color: color,
        size: size,
      ),
      _DatabaseBoardIconKind.twic => Icon(
        Icons.public_rounded,
        color: color,
        size: size * 0.88,
      ),
      _DatabaseBoardIconKind.subscribedDatabase => Stack(
        clipBehavior: Clip.none,
        children: [
          _ChessDatabaseGlyph(color: color, size: size),
          Positioned(
            right: -size * 0.18,
            bottom: -size * 0.12,
            child: Container(
              width: size * 0.52,
              height: size * 0.52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: kBlack2Color,
                shape: BoxShape.circle,
                border: Border.all(color: color.withValues(alpha: 0.55)),
              ),
              child: Icon(
                Icons.cloud_done_rounded,
                color: color,
                size: size * 0.34,
              ),
            ),
          ),
        ],
      ),
      _ => _ChessDatabaseGlyph(color: color, size: size),
    };
  }
}

/// Folder glyph that reads as a *container* (not a database cylinder):
/// open folder shell + nested mini-db chip, so hierarchy is obvious.
class _FolderHierarchyGlyph extends StatelessWidget {
  const _FolderHierarchyGlyph({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Icon(Icons.folder_rounded, color: color, size: size * 0.96),
          ),
          Positioned(
            right: -size * 0.06,
            bottom: -size * 0.04,
            child: Container(
              width: size * 0.48,
              height: size * 0.42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: kBlack2Color,
                borderRadius: BorderRadius.circular(size * 0.10),
                border: Border.all(
                  color: color.withValues(alpha: 0.70),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.28),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Icon(
                Icons.table_rows_rounded,
                color: color,
                size: size * 0.26,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChessDatabaseGlyph extends StatelessWidget {
  const _ChessDatabaseGlyph({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _ChessDatabaseGlyphPainter(color)),
    );
  }
}

class _ChessDatabaseGlyphPainter extends CustomPainter {
  const _ChessDatabaseGlyphPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 20, size.height / 20);
    final stroke =
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.45
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
    final fill =
        Paint()
          ..color = color.withValues(alpha: 0.14)
          ..style = PaintingStyle.fill;
    final squareFill =
        Paint()
          ..color = color.withValues(alpha: 0.42)
          ..style = PaintingStyle.fill;

    final body = Rect.fromLTWH(3.2, 4.4, 13.6, 11.8);
    final top = Rect.fromLTWH(3.2, 2.2, 13.6, 5.0);
    final bottom = Rect.fromLTWH(3.2, 13.7, 13.6, 4.8);

    final path =
        Path()
          ..moveTo(body.left, top.center.dy)
          ..lineTo(body.left, bottom.center.dy)
          ..arcTo(bottom, math.pi, -math.pi, false)
          ..lineTo(body.right, top.center.dy);

    canvas.drawPath(path, fill);
    canvas.drawOval(top, fill);
    canvas.drawPath(path, stroke);
    canvas.drawOval(top, stroke);
    canvas.drawArc(bottom, 0, math.pi, false, stroke);

    const cell = 2.25;
    final boardLeft = body.left + 4.55;
    final boardTop = body.top + 5.25;
    final boardStroke =
        Paint()
          ..color = color.withValues(alpha: 0.72)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.75;
    final board = Rect.fromLTWH(boardLeft, boardTop, cell * 2, cell * 2);
    canvas.drawRect(board, boardStroke);
    canvas.drawRect(Rect.fromLTWH(boardLeft, boardTop, cell, cell), squareFill);
    canvas.drawRect(
      Rect.fromLTWH(boardLeft + cell, boardTop + cell, cell, cell),
      squareFill,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ChessDatabaseGlyphPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

const double _kDatabaseBoardTileWidth = 196;
const double _kDatabaseBoardTileHeight = 100;

class _DatabaseBoardTile extends StatefulWidget {
  const _DatabaseBoardTile({
    required this.title,
    required this.iconKind,
    required this.pinned,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
    this.subtitle,
    this.onContextMenu,
  });

  final String title;
  final String? subtitle;
  final _DatabaseBoardIconKind iconKind;
  final bool pinned;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onOpen;
  final ValueChanged<Offset>? onContextMenu;

  @override
  State<_DatabaseBoardTile> createState() => _DatabaseBoardTileState();
}

class _DatabaseBoardTileState extends State<_DatabaseBoardTile>
    with DeferredPointerStateMixin<_DatabaseBoardTile> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'library-database-tile');
  bool _hovered = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _selectFromTile() {
    _focusNode.requestFocus();
    widget.onSelect();
  }

  void _openFromTile() {
    _focusNode.requestFocus();
    widget.onOpen();
  }

  @override
  Widget build(BuildContext context) {
    final chrome = _LibraryKindChrome.forKind(widget.iconKind);
    final isFolder = widget.iconKind == _DatabaseBoardIconKind.folder;
    final borderColor =
        widget.selected
            ? chrome.accent.withValues(alpha: 0.78)
            : _hovered
            ? chrome.accent.withValues(alpha: 0.38)
            : kDividerColor;
    return SizedBox(
      width: _kDatabaseBoardTileWidth,
      height: _kDatabaseBoardTileHeight,
      child: Focus(
        focusNode: _focusNode,
        canRequestFocus: true,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) {
            _openFromTile();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: DesktopTooltip(
          message: widget.title,
          child: ClickCursor(
            child: MouseRegion(
              onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
              onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _selectFromTile,
                onDoubleTap: _openFromTile,
                onSecondaryTapDown:
                    widget.onContextMenu == null
                        ? null
                        : (details) =>
                            widget.onContextMenu!(details.globalPosition),
                child: MotionCard(
                  borderRadius: 10,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.fromLTRB(10, 9, 10, 8),
                    decoration: BoxDecoration(
                      color:
                          widget.selected
                              ? chrome.accent.withValues(alpha: 0.12)
                              : (_hovered ? kBlack3Color : kBlack2Color),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: borderColor),
                      // Left edge accent encodes kind (folder amber vs DB primary).
                      boxShadow:
                          widget.selected
                              ? [
                                BoxShadow(
                                  color: chrome.accent.withValues(alpha: 0.20),
                                  blurRadius: 16,
                                  offset: const Offset(0, 5),
                                ),
                              ]
                              : null,
                    ),
                    child: Row(
                      children: [
                        // Kind well — folders are rounded-square “containers”,
                        // databases are slightly rounder “records”.
                        Container(
                          width: 34,
                          height: 34,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: chrome.wellFill,
                            borderRadius: BorderRadius.circular(
                              isFolder ? 8 : 10,
                            ),
                            border: Border.all(color: chrome.wellBorder),
                          ),
                          child: _DatabaseBoardIcon(
                            kind: widget.iconKind,
                            color: chrome.accent,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      widget.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: kWhiteColor,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                        height: 1.15,
                                      ),
                                    ),
                                  ),
                                  if (widget.pinned) ...[
                                    const SizedBox(width: 5),
                                    Icon(
                                      Icons.push_pin_rounded,
                                      size: 13,
                                      color: chrome.accent,
                                    ),
                                  ],
                                ],
                              ),
                              if (widget.subtitle != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  widget.subtitle!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: kWhiteColor.withValues(alpha: 0.62),
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    height: 1.15,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DatabaseBoardListHeader extends StatelessWidget {
  const _DatabaseBoardListHeader({
    required this.columns,
    required this.onColumnWidthChanged,
    required this.onResetWidths,
  });

  final LibraryDatabaseCatalogColumns columns;
  final void Function(String key, double width) onColumnWidthChanged;
  final VoidCallback onResetWidths;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: kLightGreyColor,
      fontSize: 10.5,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.25,
    );
    return Container(
      height: 29,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: kBlack3Color.withValues(alpha: 0.52),
        border: const Border(bottom: BorderSide(color: kDividerColor)),
      ),
      child: _DatabaseBoardColumnsLayout(
        columns: columns,
        leading: const SizedBox.shrink(),
        name: _ResizableDatabaseHeaderCell(
          label: 'NAME',
          width: columns.nameWidth,
          style: style,
          onChanged: (width) => onColumnWidthChanged('name', width),
        ),
        details: _ResizableDatabaseHeaderCell(
          label: 'GAMES',
          width: columns.gamesWidth,
          style: style,
          onChanged: (width) => onColumnWidthChanged('games', width),
        ),
        source: _ResizableDatabaseHeaderCell(
          label: 'SOURCE',
          width: columns.sourceWidth,
          style: style,
          onChanged: (width) => onColumnWidthChanged('source', width),
        ),
        lastOpened: _ResizableDatabaseHeaderCell(
          label: 'LAST OPENED',
          width: columns.lastOpenedWidth,
          style: style,
          onChanged: (width) => onColumnWidthChanged('lastOpened', width),
        ),
        trailing: DesktopHeaderIconButton(
          icon: Icons.restart_alt_rounded,
          tooltip: 'Reset column widths',
          onPress: onResetWidths,
        ),
      ),
    );
  }
}

class _ResizableDatabaseHeaderCell extends StatefulWidget {
  const _ResizableDatabaseHeaderCell({
    required this.label,
    required this.width,
    required this.style,
    required this.onChanged,
  });

  final String label;
  final double width;
  final TextStyle style;
  final ValueChanged<double> onChanged;

  @override
  State<_ResizableDatabaseHeaderCell> createState() =>
      _ResizableDatabaseHeaderCellState();
}

class _ResizableDatabaseHeaderCellState
    extends State<_ResizableDatabaseHeaderCell> {
  late double _dragWidth = widget.width;

  @override
  void didUpdateWidget(covariant _ResizableDatabaseHeaderCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.width != widget.width) _dragWidth = widget.width;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(widget.label, style: widget.style),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) => _dragWidth = widget.width,
              onHorizontalDragUpdate: (details) {
                _dragWidth += details.delta.dx;
                widget.onChanged(_dragWidth);
              },
              child: const SizedBox(width: 7, height: double.infinity),
            ),
          ),
        ),
      ],
    );
  }
}

class _DatabaseBoardSectionLabel extends StatelessWidget {
  const _DatabaseBoardSectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 25,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: kBlackColor.withValues(alpha: 0.34),
      child: Text(
        label,
        style: TextStyle(
          color: kWhiteColor.withValues(alpha: 0.52),
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

@visibleForTesting
Widget buildLibraryDatabaseCatalogRowForTest({
  required String title,
  required VoidCallback onSelect,
  required VoidCallback onOpen,
  required ValueChanged<Offset> onContextMenu,
}) {
  return _DatabaseBoardRow(
    title: title,
    details: '1 game',
    source: 'Local',
    lastOpened: 'Never',
    iconKind: _DatabaseBoardIconKind.localDatabase,
    columns: const LibraryDatabaseCatalogColumns(
      showSource: true,
      showLastOpened: true,
    ),
    pinned: false,
    selected: false,
    onSelect: onSelect,
    onOpen: onOpen,
    onContextMenu: onContextMenu,
  );
}

class _DatabaseBoardRow extends StatefulWidget {
  const _DatabaseBoardRow({
    required this.title,
    required this.details,
    required this.source,
    required this.lastOpened,
    required this.iconKind,
    required this.columns,
    required this.pinned,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
    this.onContextMenu,
    this.reorderKey,
    this.onMoveBefore,
  });

  final String title;
  final String details;
  final String source;
  final String lastOpened;
  final _DatabaseBoardIconKind iconKind;
  final LibraryDatabaseCatalogColumns columns;
  final bool pinned;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onOpen;
  final ValueChanged<Offset>? onContextMenu;
  final String? reorderKey;
  final ValueChanged<String>? onMoveBefore;

  @override
  State<_DatabaseBoardRow> createState() => _DatabaseBoardRowState();
}

class _DatabaseBoardRowState extends State<_DatabaseBoardRow>
    with DeferredPointerStateMixin<_DatabaseBoardRow> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'library-database-row');
  bool _hovered = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _select() {
    _focusNode.requestFocus();
    widget.onSelect();
  }

  void _open() {
    _focusNode.requestFocus();
    widget.onOpen();
  }

  @override
  Widget build(BuildContext context) {
    final chrome = _LibraryKindChrome.forKind(widget.iconKind);
    final isFolder = widget.iconKind == _DatabaseBoardIconKind.folder;
    final titleColor = widget.selected ? kPrimaryColor : kWhiteColor;
    final row = Semantics(
      button: true,
      selected: widget.selected,
      label:
          '${widget.title}, ${widget.details}, ${widget.source}, '
          '${widget.lastOpened}',
      child: Focus(
        focusNode: _focusNode,
        canRequestFocus: true,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) {
            _open();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: ClickCursor(
          child: MouseRegion(
            onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
            onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _select,
              onDoubleTap: _open,
              onSecondaryTapUp:
                  widget.onContextMenu == null
                      ? null
                      : (details) {
                        _select();
                        widget.onContextMenu!(details.globalPosition);
                      },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color:
                      widget.selected
                          ? kPrimaryColor.withValues(alpha: 0.075)
                          : (_hovered
                              ? kBlack3Color.withValues(alpha: 0.72)
                              : Colors.transparent),
                  border: Border(
                    left: BorderSide(
                      color:
                          widget.selected ? kPrimaryColor : Colors.transparent,
                      width: 2,
                    ),
                    bottom: BorderSide(
                      color: kDividerColor.withValues(alpha: 0.72),
                    ),
                  ),
                ),
                child: _DatabaseBoardColumnsLayout(
                  columns: widget.columns,
                  leading: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 90),
                        opacity: _hovered && widget.reorderKey != null ? 0 : 1,
                        child: Container(
                          width: 27,
                          height: 27,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: chrome.wellFill,
                            borderRadius: BorderRadius.circular(
                              isFolder ? 6 : 8,
                            ),
                            border: Border.all(color: chrome.wellBorder),
                          ),
                          child: _DatabaseBoardIcon(
                            kind: widget.iconKind,
                            color: chrome.accent,
                            size: 15,
                          ),
                        ),
                      ),
                      if (_hovered && widget.reorderKey != null)
                        Draggable<String>(
                          data: widget.reorderKey!,
                          feedback: const Material(
                            color: Colors.transparent,
                            child: Icon(
                              Icons.drag_indicator_rounded,
                              size: 18,
                              color: kPrimaryColor,
                            ),
                          ),
                          childWhenDragging: const SizedBox(
                            width: 27,
                            height: 27,
                          ),
                          child: DesktopTooltip(
                            message: 'Drag to reorder',
                            child: MouseRegion(
                              cursor: SystemMouseCursors.grab,
                              child: const SizedBox(
                                key: ValueKey<String>(
                                  'library-home-reorder-handle',
                                ),
                                width: 27,
                                height: 27,
                                child: Icon(
                                  Icons.drag_indicator_rounded,
                                  size: 17,
                                  color: kWhiteColor70,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  name: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: titleColor,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  details: _DatabaseBoardMutedCell(widget.details),
                  source: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.source == 'Cloud'
                            ? Icons.cloud_outlined
                            : Icons.computer_rounded,
                        size: 12.5,
                        color: kLightGreyColor,
                      ),
                      const SizedBox(width: 5),
                      Flexible(child: _DatabaseBoardMutedCell(widget.source)),
                    ],
                  ),
                  lastOpened: _DatabaseBoardMutedCell(widget.lastOpened),
                  trailing: Icon(
                    widget.pinned
                        ? Icons.push_pin_rounded
                        : isFolder
                        ? Icons.chevron_right_rounded
                        : Icons.more_horiz_rounded,
                    size: 16,
                    color: widget.pinned ? chrome.accent : kLightGreyColor,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final reorderKey = widget.reorderKey;
    final onMoveBefore = widget.onMoveBefore;
    if (reorderKey == null || onMoveBefore == null) return row;
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != reorderKey,
      onAcceptWithDetails: (details) => onMoveBefore(details.data),
      builder: (context, candidates, rejected) {
        return DecoratedBox(
          decoration: BoxDecoration(
            border:
                candidates.isEmpty
                    ? null
                    : const Border(
                      top: BorderSide(color: kPrimaryColor, width: 2),
                    ),
          ),
          child: row,
        );
      },
    );
  }
}

class _DatabaseBoardColumnsLayout extends StatelessWidget {
  const _DatabaseBoardColumnsLayout({
    required this.columns,
    required this.leading,
    required this.name,
    required this.details,
    required this.source,
    required this.lastOpened,
    required this.trailing,
  });

  final LibraryDatabaseCatalogColumns columns;
  final Widget leading;
  final Widget name;
  final Widget details;
  final Widget source;
  final Widget lastOpened;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 39,
          child: Align(alignment: Alignment.centerLeft, child: leading),
        ),
        const SizedBox(width: 5),
        SizedBox(width: columns.nameWidth, child: name),
        const SizedBox(width: 12),
        SizedBox(width: columns.gamesWidth, child: details),
        if (columns.showSource) ...[
          const SizedBox(width: 12),
          SizedBox(width: columns.sourceWidth, child: source),
        ],
        if (columns.showLastOpened) ...[
          const SizedBox(width: 12),
          SizedBox(width: columns.lastOpenedWidth, child: lastOpened),
        ],
        const Spacer(),
        const SizedBox(width: 8),
        SizedBox(
          width: 22,
          child: Align(alignment: Alignment.centerRight, child: trailing),
        ),
      ],
    );
  }
}

class _DatabaseBoardMutedCell extends StatelessWidget {
  const _DatabaseBoardMutedCell(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: kLightGreyColor,
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _CloudDatabaseMiniPreview extends HookConsumerWidget {
  const _CloudDatabaseMiniPreview({required this.folder});

  final LibraryFolder? folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = useState<String?>(null);
    final selectedIds = useState<Set<String>>(<String>{});
    final selectionAnchor = useState<int?>(null);
    final selectionExtent = useState<int?>(null);
    final plyIndex = useState<int>(0);
    final sort = useState(const _SortConfig(_SortKey.saved, _SortDir.desc));
    final scrollController = useScrollController();
    final activeFolder = folder;
    if (activeFolder == null) {
      return const _LibraryEmpty(
        icon: Icons.storage_rounded,
        title: 'Select a database',
        message: 'Click a database tile above to preview it here.',
      );
    }
    if (activeFolder.id == kTwicBookId) {
      return const _TwicDatabaseMiniPreview();
    }
    final shortcutsFocusNode = useFocusNode(
      debugLabel: 'library-mini-saved-${activeFolder.id}',
    );
    // Focus the table on entry (and when the previewed database changes) so
    // arrow-key navigation works immediately without a mouse click first.
    useEffect(() {
      _requestDatabaseWorkspaceFocusAfterFrame(shortcutsFocusNode);
      return null;
    }, [activeFolder.id]);
    final cloudRefreshNonce = ref.watch(cloudLibraryRefreshNonceProvider);

    final analysesAsync = useFuture(
      useMemoized(
        () =>
            activeFolder.isSubscribed
                ? ref
                    .read(libraryRepositoryProvider)
                    .getSharedFolderAnalysesPaginated(
                      folderId: activeFolder.id,
                      limit: 120,
                    )
                : ref
                    .read(libraryRepositoryProvider)
                    .getSavedAnalyses(folderId: activeFolder.id),
        [activeFolder.id, activeFolder.isSubscribed, cloudRefreshNonce],
      ),
    );
    final all = analysesAsync.data ?? const <SavedAnalysis>[];
    final rows = useMemoized<List<SavedAnalysis>>(() {
      final copy = List<SavedAnalysis>.of(all);
      _sortAnalyses(copy, sort.value);
      return copy;
    }, [all, sort.value]);

    useEffect(() {
      if (rows.isEmpty) {
        selectedId.value = null;
      } else if (selectedId.value == null ||
          !rows.any((analysis) => analysis.id == selectedId.value)) {
        selectedId.value = rows.first.id;
      }
      return null;
    }, [rows]);

    final selected = rows.firstWhereOrNull(
      (analysis) => analysis.id == selectedId.value,
    );

    final selectedPlyCount = selected?.chessGame.mainline.length ?? 0;
    final visibleIds = rows.map((row) => row.id).toList(growable: false);
    final clampedSelectedIds = LibraryMultiSelect.clampToRows(
      selectedIds.value,
      visibleIds,
    );

    // Previews open from the natural starting position. Left/right then
    // behaves like normal game playback: right advances from move zero.
    useEffect(() {
      plyIndex.value = 0;
      return null;
    }, [selectedId.value, selectedPlyCount]);

    bool setSelectedPly(int next) {
      final current = selected;
      final clamped = _clampLibraryPreviewPly(current?.chessGame, next);
      if (clamped == plyIndex.value) return true;
      plyIndex.value = clamped;
      _playLibraryPreviewSfxForPly(ref, current?.chessGame, clamped);
      _requestDatabaseWorkspaceFocus(shortcutsFocusNode);
      return true;
    }

    bool selectSavedRow(int index) {
      if (rows.isEmpty) return false;
      final next = index.clamp(0, rows.length - 1).toInt();
      selectedId.value = rows[next].id;
      selectionAnchor.value = next;
      selectionExtent.value = next;
      if (selectedIds.value.isNotEmpty) {
        selectedIds.value = <String>{};
      }
      _requestDatabaseWorkspaceFocus(shortcutsFocusNode);
      _scrollDatabaseWorkspaceListToIndex(
        scrollController,
        next,
        _kDatabaseWorkspaceSavedRowExtent,
      );
      return true;
    }

    bool rangeSelectSavedRow(int index) {
      final next = _rangeSelectLibraryRows(
        rowIds: visibleIds,
        selectedIds: selectedIds.value,
        anchor: selectionAnchor.value,
        index: index,
      );
      if (next == null) return false;
      selectedIds.value = next.selectedIds;
      selectionAnchor.value = next.anchor;
      selectionExtent.value = next.extent;
      selectedId.value = visibleIds[next.extent];
      _requestDatabaseWorkspaceFocus(shortcutsFocusNode);
      _scrollDatabaseWorkspaceListToIndex(
        scrollController,
        next.extent,
        _kDatabaseWorkspaceSavedRowExtent,
      );
      return true;
    }

    bool extendSavedSelection(int delta) {
      final next = LibraryMultiSelect.nextExtent(
        rowIds: visibleIds,
        extent: selectionExtent.value ?? selectionAnchor.value,
        delta: delta,
      );
      return next == null ? false : rangeSelectSavedRow(next);
    }

    bool moveSavedRow(int delta) {
      if (rows.isEmpty) return false;
      final current = rows.indexWhere((a) => a.id == selectedId.value);
      return selectSavedRow((current < 0 ? 0 : current) + delta);
    }

    bool stepSelectedPly(int delta) {
      final current = selected;
      if (current == null) return false;
      return setSelectedPly(plyIndex.value + delta);
    }

    bool openSelectedSaved() {
      final current = rows.firstWhereOrNull((a) => a.id == selectedId.value);
      if (current == null) return false;
      _openAnalysis(
        ref,
        current,
        databaseTitle: activeFolder.name,
        databaseAnalyses: all,
        initialFen: _initialFenForPreviewPly(current.chessGame, plyIndex.value),
      );
      return true;
    }

    void copySelectedSaved() {
      final copyRows = _selectedSavedAnalysesForCopy(
        rows: rows,
        selectedIds: clampedSelectedIds,
        selectedId: selectedId.value,
      );
      unawaited(copySavedAnalysesAsPgn(context: context, analyses: copyRows));
    }

    return _databaseWorkspaceClipboardShortcuts(
      onCopy: copySelectedSaved,
      child: Focus(
        focusNode: shortcutsFocusNode,
        canRequestFocus: true,
        onKeyEvent:
            (_, event) => _handleDatabaseWorkspaceTableKey(
              event,
              {
                LogicalKeyboardKey.arrowDown: () => moveSavedRow(1),
                LogicalKeyboardKey.arrowUp: () => moveSavedRow(-1),
                LogicalKeyboardKey.arrowLeft: () => stepSelectedPly(-1),
                LogicalKeyboardKey.arrowRight: () => stepSelectedPly(1),
                LogicalKeyboardKey.home: () => selectSavedRow(0),
                LogicalKeyboardKey.end: () => selectSavedRow(rows.length - 1),
                LogicalKeyboardKey.enter: openSelectedSaved,
                LogicalKeyboardKey.numpadEnter: openSelectedSaved,
              },
              shiftActions: {
                LogicalKeyboardKey.arrowUp: () => extendSavedSelection(-1),
                LogicalKeyboardKey.arrowDown: () => extendSavedSelection(1),
                LogicalKeyboardKey.arrowLeft: () => setSelectedPly(0),
                LogicalKeyboardKey.arrowRight:
                    () => setSelectedPly(selectedPlyCount),
              },
            ),
        child: _MiniDatabasePreviewFrame(
          title: activeFolder.name,
          subtitle:
              analysesAsync.connectionState != ConnectionState.done
                  ? 'Loading games…'
                  : '${all.length} ${all.length == 1 ? 'game' : 'games'} · mini preview',
          child:
              analysesAsync.connectionState != ConnectionState.done
                  ? const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                      ),
                    ),
                  )
                  : rows.isEmpty
                  ? const _LibraryEmpty(
                    icon: Icons.collections_bookmark_outlined,
                    title: 'No games yet',
                    message: 'Open the database to import or paste games.',
                  )
                  : ResizableSplitView(
                    axis: Axis.horizontal,
                    storageKey:
                        'library_pane.mini.folder.${activeFolder.id}.wide-v2',
                    children: [
                      SplitChild(
                        minSize: 390,
                        initialWeight: 0.52,
                        label: 'Games',
                        child: _DatabaseSavedGamesTable(
                          rows: rows,
                          sort: sort.value,
                          selectedId: selectedId.value,
                          selectedIds: clampedSelectedIds,
                          scrollController: scrollController,
                          onSortChange: (next) => sort.value = next,
                          onRangeSelect: rangeSelectSavedRow,
                          onSelect: (analysis) {
                            final index = rows.indexWhere(
                              (row) => row.id == analysis.id,
                            );
                            if (index >= 0) selectSavedRow(index);
                          },
                          onOpen:
                              (analysis) => _openAnalysis(
                                ref,
                                analysis,
                                databaseTitle: activeFolder.name,
                                databaseAnalyses: all,
                              ),
                        ),
                      ),
                      SplitChild(
                        minSize: 380,
                        initialWeight: 0.48,
                        label: 'Preview',
                        child: _SavedAnalysisPreviewPanel(
                          analysis: selected,
                          plyIndex: plyIndex.value,
                          onPlyChanged: setSelectedPly,
                          onOpen:
                              selected == null
                                  ? null
                                  : () => _openAnalysis(
                                    ref,
                                    selected,
                                    databaseTitle: activeFolder.name,
                                    databaseAnalyses: all,
                                    initialFen: _initialFenForPreviewPly(
                                      selected.chessGame,
                                      plyIndex.value,
                                    ),
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

class _TwicDatabaseMiniPreview extends HookConsumerWidget {
  const _TwicDatabaseMiniPreview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scrollController = useScrollController();
    final selectedId = useState<String?>(null);
    final selectedIds = useState<Set<String>>(<String>{});
    final selectionAnchor = useState<int?>(null);
    final selectionExtent = useState<int?>(null);
    final plyIndex = useState<int>(0);
    final shortcutsFocusNode = useFocusNode(debugLabel: 'library-mini-twic');
    // Focus the table on entry so arrow-key navigation works immediately
    // without a mouse click first.
    useEffect(() {
      _requestDatabaseWorkspaceFocusAfterFrame(shortcutsFocusNode);
      return null;
    }, const <Object?>[]);
    final state = ref.watch(gamebaseDatabaseGamesPaginatedProvider);
    final totalAsync = ref.watch(twicDatabaseTotalGamesProvider);
    final games = state.games;
    useEffect(() {
      if (games.isEmpty) {
        selectedId.value = null;
      } else if (selectedId.value == null ||
          !games.any((game) => game.gameId == selectedId.value)) {
        selectedId.value = games.first.gameId;
      }
      return null;
    }, [games]);
    final selected = games.firstWhereOrNull(
      (game) => game.gameId == selectedId.value,
    );
    final selectedPreview = _watchTwicPreviewGame(ref, selected);
    final selectedPreviewGame = selectedPreview.game;
    final selectedPlyCount = selectedPreviewGame?.mainline.length ?? 0;
    final visibleIds = games.map((game) => game.gameId).toList(growable: false);
    final clampedSelectedIds = LibraryMultiSelect.clampToRows(
      selectedIds.value,
      visibleIds,
    );

    useEffect(() {
      plyIndex.value = 0;
      return null;
    }, [selectedId.value, selectedPlyCount]);

    bool setSelectedTwicPly(int next) {
      final clamped = _clampLibraryPreviewPly(selectedPreviewGame, next);
      if (clamped == plyIndex.value) return true;
      plyIndex.value = clamped;
      _playLibraryPreviewSfxForPly(ref, selectedPreviewGame, clamped);
      _requestDatabaseWorkspaceFocus(shortcutsFocusNode);
      return true;
    }

    bool selectTwicMiniIndex(int index) {
      if (games.isEmpty) return false;
      final next = index.clamp(0, games.length - 1).toInt();
      selectedId.value = games[next].gameId;
      selectionAnchor.value = next;
      selectionExtent.value = next;
      if (selectedIds.value.isNotEmpty) {
        selectedIds.value = <String>{};
      }
      _requestDatabaseWorkspaceFocus(shortcutsFocusNode);
      _scrollDatabaseWorkspaceListToIndex(
        scrollController,
        next,
        _kDatabaseWorkspaceTwicRowExtent,
      );
      return true;
    }

    bool rangeSelectTwicMiniIndex(int index) {
      final next = _rangeSelectLibraryRows(
        rowIds: visibleIds,
        selectedIds: selectedIds.value,
        anchor: selectionAnchor.value,
        index: index,
      );
      if (next == null) return false;
      selectedIds.value = next.selectedIds;
      selectionAnchor.value = next.anchor;
      selectionExtent.value = next.extent;
      selectedId.value = visibleIds[next.extent];
      _requestDatabaseWorkspaceFocus(shortcutsFocusNode);
      _scrollDatabaseWorkspaceListToIndex(
        scrollController,
        next.extent,
        _kDatabaseWorkspaceTwicRowExtent,
      );
      return true;
    }

    bool extendTwicMiniSelection(int delta) {
      final next = LibraryMultiSelect.nextExtent(
        rowIds: visibleIds,
        extent: selectionExtent.value ?? selectionAnchor.value,
        delta: delta,
      );
      return next == null ? false : rangeSelectTwicMiniIndex(next);
    }

    bool moveTwicMiniSelection(int delta) {
      if (games.isEmpty) return false;
      final current = games.indexWhere((g) => g.gameId == selectedId.value);
      return selectTwicMiniIndex((current < 0 ? 0 : current) + delta);
    }

    bool stepSelectedTwicPly(int delta) {
      final current = selected;
      if (current == null) return false;
      return setSelectedTwicPly(plyIndex.value + delta);
    }

    bool openSelectedTwic() {
      final current = games.firstWhereOrNull(
        (g) => g.gameId == selectedId.value,
      );
      if (current == null) return false;
      openBoardGameTab(
        ref,
        _buildTwicBoardArgs(
          ref,
          current,
          initialFen: _initialFenForPreviewPly(
            selectedPreviewGame,
            plyIndex.value,
          ),
        ),
      );
      return true;
    }

    void copySelectedTwic() {
      final copyGames = _selectedTwicGamesForCopy(
        games: games,
        selectedIds: clampedSelectedIds,
        selectedId: selectedId.value,
      );
      unawaited(
        copyDesktopGamesAsResolvedPgn(
          context: context,
          ref: ref,
          games: copyGames,
        ),
      );
    }

    return _databaseWorkspaceClipboardShortcuts(
      onCopy: copySelectedTwic,
      child: Focus(
        focusNode: shortcutsFocusNode,
        canRequestFocus: true,
        onKeyEvent:
            (_, event) => _handleDatabaseWorkspaceTableKey(
              event,
              {
                LogicalKeyboardKey.arrowDown: () => moveTwicMiniSelection(1),
                LogicalKeyboardKey.arrowUp: () => moveTwicMiniSelection(-1),
                LogicalKeyboardKey.arrowLeft: () => stepSelectedTwicPly(-1),
                LogicalKeyboardKey.arrowRight: () => stepSelectedTwicPly(1),
                LogicalKeyboardKey.home: () => selectTwicMiniIndex(0),
                LogicalKeyboardKey.end:
                    () => selectTwicMiniIndex(games.length - 1),
                LogicalKeyboardKey.enter: openSelectedTwic,
                LogicalKeyboardKey.numpadEnter: openSelectedTwic,
              },
              shiftActions: {
                LogicalKeyboardKey.arrowUp: () => extendTwicMiniSelection(-1),
                LogicalKeyboardKey.arrowDown: () => extendTwicMiniSelection(1),
                LogicalKeyboardKey.arrowLeft: () => setSelectedTwicPly(0),
                LogicalKeyboardKey.arrowRight:
                    () => setSelectedTwicPly(selectedPlyCount),
              },
            ),
        child: _MiniDatabasePreviewFrame(
          title: 'ChessEver',
          subtitle:
              totalAsync.valueOrNull == null
                  ? 'System database · mini preview'
                  : '${formatCompactCount(totalAsync.valueOrNull!)} games · mini preview',
          child:
              games.isEmpty && state.isLoading
                  ? const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                      ),
                    ),
                  )
                  : ResizableSplitView(
                    axis: Axis.horizontal,
                    storageKey: 'library_pane.mini.twic.wide-v2',
                    children: [
                      SplitChild(
                        minSize: 390,
                        initialWeight: 0.52,
                        label: 'Games',
                        child: _TwicGamesTable(
                          state: state,
                          scrollController: scrollController,
                          selectedGameId: selectedId.value,
                          selectedGameIds: clampedSelectedIds,
                          onRangeSelect: rangeSelectTwicMiniIndex,
                          onTapGame: (game) {
                            final index = games.indexWhere(
                              (row) => row.gameId == game.gameId,
                            );
                            if (index >= 0) selectTwicMiniIndex(index);
                          },
                          onOpenGame:
                              (game) => openBoardGameTab(
                                ref,
                                _buildTwicBoardArgs(ref, game),
                              ),
                          onContextMenuGame:
                              (game, position) => unawaited(
                                _showTwicGameContextMenu(
                                  context: context,
                                  ref: ref,
                                  position: position,
                                  game: game,
                                ),
                              ),
                        ),
                      ),
                      SplitChild(
                        minSize: 380,
                        initialWeight: 0.48,
                        label: 'Preview',
                        child: _TwicPreviewPanel(
                          game: selected,
                          previewGame: selectedPreviewGame,
                          isResolvingNotation: selectedPreview.isLoading,
                          plyIndex: plyIndex.value,
                          onPlyChanged: setSelectedTwicPly,
                          onOpen:
                              selected == null
                                  ? null
                                  : () => openBoardGameTab(
                                    ref,
                                    _buildTwicBoardArgs(
                                      ref,
                                      selected,
                                      initialFen: _initialFenForPreviewPly(
                                        selectedPreviewGame,
                                        plyIndex.value,
                                      ),
                                    ),
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

class _LocalDatabaseMiniPreview extends HookConsumerWidget {
  const _LocalDatabaseMiniPreview({
    required this.source,
    required this.selectedNode,
    required this.selectedPath,
  });

  final LocalChessSource? source;
  final LocalChessNode? selectedNode;
  final String? selectedPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final node = selectedNode;
    final scrollController = useScrollController();
    final searchController = useTextEditingController();
    final query = useState<String>('');
    final gameFilter = useState<LocalChessGameFilter>(LocalChessGameFilter());
    final selectedIndex = useState<int>(0);
    final selectedIds = useState<Set<String>>(<String>{});
    final selectionAnchor = useState<int?>(null);
    final selectionExtent = useState<int?>(null);
    final plyIndex = useState<int>(0);
    final shortcutsFocusNode = useFocusNode(debugLabel: 'library-mini-local');
    // Clear the query/filters when the previewed database changes so a stale
    // filter doesn't hide the next database's games.
    useEffect(() {
      searchController.clear();
      query.value = '';
      gameFilter.value = LocalChessGameFilter();
      return null;
    }, [selectedPath]);
    final enrichmentEpoch = ref.watch(localPlayerEnrichmentEpochProvider);
    // Focus the table on entry (and when the previewed database changes) so
    // arrow-key navigation works immediately without a mouse click first.
    useEffect(() {
      _requestDatabaseWorkspaceFocusAfterFrame(shortcutsFocusNode);
      return null;
    }, [selectedPath]);

    if (source == null || node == null || selectedPath == null) {
      return const _LibraryEmpty(
        icon: Icons.add_to_drive_outlined,
        title: 'Add a local database',
        message:
            'Open a local folder or files above, then click a tile to preview it.',
      );
    }
    final selectedDatabase = switch (node) {
      LocalChessFolderNode() => selectedLocalChessDatabaseFile(node),
      LocalChessFileNode() => node,
      _ => null,
    };
    final localOpeningTreeIndex = selectedDatabase?.openingTreeIndex;
    final openableLocalTreeIndex =
        localOpeningTreeIndex?.isUsable == true ? localOpeningTreeIndex : null;
    final treeBuildProgress = ref.watch(
      localChessLibraryProvider.select(
        (state) => state.treeBuildForPath(selectedDatabase?.path),
      ),
    );
    final games =
        selectedDatabase?.games ??
        switch (node) {
          LocalChessFolderNode() => node.gamesInSubtree,
          _ => const <LocalChessGame>[],
        };
    final databaseTitle = node.name.isEmpty ? source!.label : node.name;
    final previewEntryCount = selectedDatabase?.gameCount ?? games.length;
    final previewQueryKey =
        Object.hash(
          selectedPath,
          selectedDatabase?.path,
          selectedDatabase?.gameCount,
          selectedDatabase?.sizeBytes,
          selectedDatabase?.modifiedAt?.millisecondsSinceEpoch,
          enrichmentEpoch,
          query.value,
          gameFilter.value,
        ).toString();
    final previewPageWindow = useState(
      _LocalMiniPreviewPageWindow(previewQueryKey, 0),
    );
    final previewLoadedPages = useState(
      const _LoadedLocalMiniPreviewPages.empty(),
    );
    final effectivePreviewPageWindow =
        previewPageWindow.value.queryKey == previewQueryKey
            ? previewPageWindow.value
            : _LocalMiniPreviewPageWindow(previewQueryKey, 0);
    useEffect(() {
      if (previewPageWindow.value.queryKey != previewQueryKey) {
        previewPageWindow.value = _LocalMiniPreviewPageWindow(
          previewQueryKey,
          0,
        );
      }
      if (previewLoadedPages.value.queryKey != previewQueryKey) {
        previewLoadedPages.value = const _LoadedLocalMiniPreviewPages.empty();
      }
      return null;
    }, [previewQueryKey]);
    // Backfill titles/federations for this database in the background so the
    // preview rows and search pick them up (no-op once already enriched).
    useEffect(() {
      final path = selectedDatabase?.path;
      if (path == null || previewEntryCount <= 0) return null;
      Future<void>.microtask(
        () => ref
            .read(localPlayerEnrichmentServiceProvider)
            .ensureDatabaseEnriched(path),
      );
      return null;
    }, [selectedDatabase?.path, previewEntryCount]);
    final previewPageFuture = useMemoized<Future<LocalChessGameQueryPage?>?>(
      () {
        final database = selectedDatabase;
        if (database == null || previewEntryCount <= 0) return null;
        return _queryLocalMiniPreviewPage(
          ref.read(localChessDatabaseRepositoryProvider),
          databasePath: database.path,
          search: query.value,
          filter: gameFilter.value,
          pageNumber: effectivePreviewPageWindow.pageNumber,
          pageSize: _kLocalMiniPreviewGameQueryPageSize,
        );
      },
      [
        selectedDatabase?.path,
        previewEntryCount,
        query.value,
        gameFilter.value,
        effectivePreviewPageWindow.queryKey,
        effectivePreviewPageWindow.pageNumber,
      ],
    );
    final previewPageSnapshot = useFuture(
      previewPageFuture,
      preserveState: false,
    );
    final previewPage = previewPageSnapshot.data;
    useEffect(() {
      final page = previewPage;
      if (page == null) return null;
      if (previewPageWindow.value.queryKey != previewQueryKey) return null;
      previewLoadedPages.value = previewLoadedPages.value.merge(
        queryKey: previewQueryKey,
        page: page,
      );
      return null;
    }, [previewPage, previewQueryKey]);
    final previewRows = _visibleLocalMiniPreviewRows(
      queryKey: previewQueryKey,
      loaded: previewLoadedPages.value,
      livePage: previewPage,
    );
    // Folder-subtree previews aren't DB-backed, so the SQL search never runs;
    // filter those in memory with the same multi-term semantics.
    final fallbackGames = _filterLocalMiniPreviewGames(games, query.value);
    final visibleGames = previewRows?.games ?? fallbackGames;
    final previewTotalCount =
        previewRows?.totalCount ?? previewPage?.totalCount ?? previewEntryCount;
    final isLoadingPreviewPage =
        previewPageFuture != null &&
        previewPageSnapshot.connectionState != ConnectionState.done;
    final hasMorePreviewRows = previewRows?.hasMore ?? false;
    final previewContextGames = previewRows == null ? games : visibleGames;
    final showPreviewLoadingRow = hasMorePreviewRows || isLoadingPreviewPage;
    final lastScrollLoadRequest = useRef<int?>(null);
    final visibleIds = visibleGames
        .map((game) => game.id)
        .toList(growable: false);
    final clampedSelectedIds = LibraryMultiSelect.clampToRows(
      selectedIds.value,
      visibleIds,
    );

    useEffect(() {
      if (visibleGames.isEmpty) {
        selectedIndex.value = 0;
      } else if (selectedIndex.value >= visibleGames.length) {
        selectedIndex.value = 0;
      }
      return null;
    }, [selectedPath, visibleGames.length]);

    useEffect(
      () {
        lastScrollLoadRequest.value = null;
        return null;
      },
      [
        previewQueryKey,
        visibleGames.length,
        hasMorePreviewRows,
        isLoadingPreviewPage,
      ],
    );

    void requestNextPreviewPage() {
      if (!hasMorePreviewRows || isLoadingPreviewPage) return;
      if (previewRows == null) return;
      final nextPage = previewRows.nextPageNumber;
      if (lastScrollLoadRequest.value == nextPage) return;
      lastScrollLoadRequest.value = nextPage;
      previewPageWindow.value = _LocalMiniPreviewPageWindow(
        previewQueryKey,
        nextPage,
      );
    }

    useEffect(
      () {
        void maybeLoadMore() {
          if (!scrollController.hasClients) return;
          final position = scrollController.position;
          if (!position.hasContentDimensions) return;
          if (position.extentAfter >
              _kLocalMiniPreviewScrollLoadMoreThreshold) {
            return;
          }
          requestNextPreviewPage();
        }

        scrollController.addListener(maybeLoadMore);
        WidgetsBinding.instance.addPostFrameCallback((_) => maybeLoadMore());
        return () => scrollController.removeListener(maybeLoadMore);
      },
      [
        scrollController,
        previewQueryKey,
        visibleGames.length,
        hasMorePreviewRows,
        isLoadingPreviewPage,
        previewRows?.nextPageNumber,
      ],
    );

    final safeIndex =
        visibleGames.isEmpty
            ? 0
            : selectedIndex.value.clamp(0, visibleGames.length - 1).toInt();
    final selectedGame = visibleGames.isEmpty ? null : visibleGames[safeIndex];
    final selectedPreviewGame = useMemoized(
      () =>
          selectedGame == null
              ? null
              : _previewChessGameFromLocalGame(selectedGame),
      [
        selectedPath,
        selectedGame?.id,
        selectedGame?.sourceByteStart,
        selectedGame?.sourceByteEnd,
      ],
    );
    final selectedPlyCount = selectedPreviewGame?.mainline.length ?? 0;

    useEffect(() {
      plyIndex.value = 0;
      return null;
    }, [selectedPath, selectedGame?.id, selectedPlyCount]);

    bool setSelectedLocalPly(int next) {
      final clamped = _clampLibraryPreviewPly(selectedPreviewGame, next);
      if (clamped == plyIndex.value) return true;
      plyIndex.value = clamped;
      _playLibraryPreviewSfxForPly(ref, selectedPreviewGame, clamped);
      _requestDatabaseWorkspaceFocus(shortcutsFocusNode);
      return true;
    }

    bool selectLocalIndex(int index) {
      if (visibleGames.isEmpty) return false;
      final next = index.clamp(0, visibleGames.length - 1).toInt();
      selectedIndex.value = next;
      selectionAnchor.value = next;
      selectionExtent.value = next;
      if (selectedIds.value.isNotEmpty) {
        selectedIds.value = <String>{};
      }
      _requestDatabaseWorkspaceFocus(shortcutsFocusNode);
      _scrollDatabaseWorkspaceListToIndex(
        scrollController,
        next,
        _kLocalMiniPreviewRowExtent,
      );
      return true;
    }

    bool rangeSelectLocalIndex(int index) {
      final next = _rangeSelectLibraryRows(
        rowIds: visibleIds,
        selectedIds: selectedIds.value,
        anchor: selectionAnchor.value,
        index: index,
      );
      if (next == null) return false;
      selectedIds.value = next.selectedIds;
      selectionAnchor.value = next.anchor;
      selectionExtent.value = next.extent;
      selectedIndex.value = next.extent;
      _requestDatabaseWorkspaceFocus(shortcutsFocusNode);
      _scrollDatabaseWorkspaceListToIndex(
        scrollController,
        next.extent,
        _kLocalMiniPreviewRowExtent,
      );
      return true;
    }

    bool extendLocalSelection(int delta) {
      final next = LibraryMultiSelect.nextExtent(
        rowIds: visibleIds,
        extent: selectionExtent.value ?? selectionAnchor.value,
        delta: delta,
      );
      return next == null ? false : rangeSelectLocalIndex(next);
    }

    bool moveLocalSelection(int delta) => selectLocalIndex(safeIndex + delta);

    bool stepSelectedLocalPly(int delta) {
      final current = selectedGame;
      if (current == null) return false;
      return setSelectedLocalPly(plyIndex.value + delta);
    }

    bool openSelectedLocal() {
      final current = selectedGame;
      if (current == null) return false;
      _openLocalPreviewGame(
        ref,
        current,
        databaseTitle: databaseTitle,
        databaseGames: previewContextGames,
        localOpeningTreeIndex: openableLocalTreeIndex,
        initialFen: _initialFenForPreviewPly(
          selectedPreviewGame,
          plyIndex.value,
        ),
      );
      return true;
    }

    void copySelectedLocal() {
      final copyGames = _selectedLocalGamesForCopy(
        games: visibleGames,
        selectedIds: clampedSelectedIds,
        selectedIndex: safeIndex,
      );
      unawaited(
        copyPgnTextsAsPgn(
          context: context,
          pgns: copyGames.map((game) => game.rawPgn),
        ),
      );
    }

    void rebuildLocalTree() {
      final database = selectedDatabase;
      if (database == null) return;
      ref
          .read(localChessLibraryProvider.notifier)
          .rebuildOpeningTree(database.path);
    }

    return _databaseWorkspaceClipboardShortcuts(
      onCopy: copySelectedLocal,
      child: Focus(
        focusNode: shortcutsFocusNode,
        canRequestFocus: true,
        onKeyEvent:
            (_, event) => _handleDatabaseWorkspaceTableKey(
              event,
              {
                LogicalKeyboardKey.arrowDown: () => moveLocalSelection(1),
                LogicalKeyboardKey.arrowUp: () => moveLocalSelection(-1),
                LogicalKeyboardKey.arrowLeft: () => stepSelectedLocalPly(-1),
                LogicalKeyboardKey.arrowRight: () => stepSelectedLocalPly(1),
                LogicalKeyboardKey.home: () => selectLocalIndex(0),
                LogicalKeyboardKey.end:
                    () => selectLocalIndex(visibleGames.length - 1),
                LogicalKeyboardKey.enter: openSelectedLocal,
                LogicalKeyboardKey.numpadEnter: openSelectedLocal,
              },
              shiftActions: {
                LogicalKeyboardKey.arrowUp: () => extendLocalSelection(-1),
                LogicalKeyboardKey.arrowDown: () => extendLocalSelection(1),
                LogicalKeyboardKey.arrowLeft: () => setSelectedLocalPly(0),
                LogicalKeyboardKey.arrowRight:
                    () => setSelectedLocalPly(selectedPlyCount),
              },
            ),
        child: _MiniDatabasePreviewFrame(
          title: databaseTitle,
          treeBuildProgress: treeBuildProgress,
          onOpenTree:
              openableLocalTreeIndex == null
                  ? null
                  : () => _openLocalPreviewTree(
                    ref,
                    title: '$databaseTitle Tree',
                    sourceLabel: databaseTitle,
                    index: openableLocalTreeIndex,
                  ),
          onBuildTree:
              selectedDatabase == null || openableLocalTreeIndex != null
                  ? null
                  : rebuildLocalTree,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 16, 6),
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
                    const SizedBox(width: 8),
                    DesktopGameFilterButton(
                      key: const ValueKey<String>(
                        'library-mini-preview-filter-button',
                      ),
                      filter: gameFilter.value.base,
                      activeCountOverride: gameFilter.value.activeFilterCount,
                      onPress: () async {
                        final next = await showDesktopGameFilterDialog(
                          context: context,
                          currentFilter: gameFilter.value.base,
                          showFormatFilter: true,
                        );
                        if (next == null || !context.mounted) return;
                        gameFilter.value = gameFilter.value.applyingDialog(
                          next,
                        );
                      },
                    ),
                    if (gameFilter.value.hasActiveFilters) ...[
                      const SizedBox(width: 6),
                      ClearDesktopGameFiltersButton(
                        key: const ValueKey<String>(
                          'library-mini-preview-clear-filters',
                        ),
                        onPress: () {
                          gameFilter.value = LocalChessGameFilter();
                        },
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child:
                    visibleGames.isEmpty && isLoadingPreviewPage
                        ? const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                            ),
                          ),
                        )
                        : selectedGame == null
                        ? _LibraryEmpty(
                          icon:
                              query.value.trim().isEmpty
                                  ? Icons.description_outlined
                                  : Icons.search_off_rounded,
                          title:
                              query.value.trim().isEmpty
                                  ? 'No parsed games here'
                                  : 'No games match "${query.value.trim()}"',
                          message:
                              query.value.trim().isEmpty
                                  ? 'Open the local database view to browse folders/files.'
                                  : 'Try another player, event, opening, or ECO.',
                        )
                        : Row(
                          children: [
                            Expanded(
                              flex: 5,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  12,
                                  10,
                                  20,
                                ),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: kBlack2Color,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: kDividerColor),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: Column(
                                    children: [
                                      const _TwicTableHeader(),
                                      const Divider(
                                        height: 1,
                                        color: kDividerColor,
                                      ),
                                      Expanded(
                                        child: ListView.builder(
                                          controller: scrollController,
                                          physics: const DesktopScrollPhysics(),
                                          padding: EdgeInsets.zero,
                                          itemExtent:
                                              _kLocalMiniPreviewRowExtent,
                                          itemCount:
                                              visibleGames.length +
                                              (showPreviewLoadingRow ? 1 : 0),
                                          itemBuilder: (context, index) {
                                            if (index >= visibleGames.length) {
                                              return _LocalMiniPreviewLoadingRow(
                                                loadedCount:
                                                    visibleGames.length,
                                                totalCount: previewTotalCount,
                                                isLoading: isLoadingPreviewPage,
                                              );
                                            }
                                            final game = visibleGames[index];
                                            final selected =
                                                clampedSelectedIds.contains(
                                                  game.id,
                                                ) ||
                                                (clampedSelectedIds.isEmpty &&
                                                    index == safeIndex);
                                            return _LocalMiniPreviewTableRow(
                                              game: game,
                                              selected: selected,
                                              onTap:
                                                  () =>
                                                      HardwareKeyboard
                                                              .instance
                                                              .isShiftPressed
                                                          ? rangeSelectLocalIndex(
                                                            index,
                                                          )
                                                          : selectLocalIndex(
                                                            index,
                                                          ),
                                              onDoubleTap:
                                                  () => _openLocalPreviewGame(
                                                    ref,
                                                    game,
                                                    databaseTitle:
                                                        databaseTitle,
                                                    databaseGames:
                                                        previewContextGames,
                                                    localOpeningTreeIndex:
                                                        openableLocalTreeIndex,
                                                  ),
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 5,
                              child: _LocalPreviewPanel(
                                game: selectedGame,
                                previewGame: selectedPreviewGame,
                                plyIndex: plyIndex.value,
                                onPlyChanged: setSelectedLocalPly,
                                onOpen:
                                    () => _openLocalPreviewGame(
                                      ref,
                                      selectedGame,
                                      databaseTitle: databaseTitle,
                                      databaseGames: previewContextGames,
                                      localOpeningTreeIndex:
                                          openableLocalTreeIndex,
                                      initialFen: _initialFenForPreviewPly(
                                        selectedPreviewGame,
                                        plyIndex.value,
                                      ),
                                    ),
                              ),
                            ),
                          ],
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalMiniPreviewLoadingRow extends StatelessWidget {
  const _LocalMiniPreviewLoadingRow({
    required this.loadedCount,
    required this.totalCount,
    required this.isLoading,
  });

  final int loadedCount;
  final int totalCount;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: kBlack2Color,
        border: Border(bottom: BorderSide(color: kDividerColor, width: 1)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child:
                isLoading
                    ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                      ),
                    )
                    : const Icon(
                      Icons.expand_more_rounded,
                      size: 16,
                      color: kLightGreyColor,
                    ),
          ),
          Expanded(
            child: Text(
              isLoading
                  ? 'Loading more...'
                  : '$loadedCount of $totalCount loaded',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One row of the local-database mini preview table.
///
/// Deliberately mirrors [_TwicTableRow] — same compact preview column geometry
/// (`_kPreviewColWhite`/`_kPreviewColResult`/`_kPreviewColBlack`/
/// `_kPreviewColEvent`/`_kPreviewColEco`/`_kPreviewColDate`),
/// same [_TwicTableHeader] above it, same hover/selection decoration — so an
/// imported PGN database previews with the exact row shape as the cloud/TWIC
/// databases sitting next to it. The Elo folds into the player column (inline
/// rating) instead of a separate Elo column, matching the compact preview.
class _LocalMiniPreviewTableRow extends StatefulWidget {
  const _LocalMiniPreviewTableRow({
    required this.game,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
  });

  final LocalChessGame game;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;

  @override
  State<_LocalMiniPreviewTableRow> createState() =>
      _LocalMiniPreviewTableRowState();
}

class _LocalMiniPreviewTableRowState extends State<_LocalMiniPreviewTableRow>
    with DeferredPointerStateMixin<_LocalMiniPreviewTableRow> {
  bool _hovered = false;

  String _meta(Map<String, dynamic> md, String key) =>
      md[key]?.toString().trim() ?? '';

  String _ratingText(Map<String, dynamic> md, String key) {
    final value = int.tryParse(_meta(md, key));
    return value == null || value <= 0 ? '' : value.toString();
  }

  @override
  Widget build(BuildContext context) {
    final md = widget.game.game.metadata;
    final eventTag = _meta(md, 'Event');
    final event =
        desktopTableDisplayValue(eventTag).isEmpty
            ? desktopTableDisplayValue(_meta(md, 'Site'))
            : desktopTableDisplayValue(eventTag);
    final dateTag = _meta(md, 'Date');
    final date = _displayGameDate(dateTag);
    final resultTag = _meta(md, 'Result').replaceAll('½', '1/2');
    final result = resultTag.isEmpty ? '*' : resultTag;

    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
        onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onDoubleTap: widget.onDoubleTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            decoration: librarySelectedRowDecoration(
              selected: widget.selected,
              hovered: _hovered,
            ),
            padding: _kPreviewTableCellPadding,
            child: Row(
              children: [
                Expanded(
                  flex: _kPreviewColWhite,
                  child: LocalGamePlayerCell(
                    metadata: md,
                    side: 'White',
                    padding: EdgeInsets.zero,
                    rating: _ratingText(md, 'WhiteElo'),
                  ),
                ),
                const SizedBox(width: _kPreviewColGap),
                SizedBox(
                  width: _kPreviewColResult,
                  child: LibraryTableResultPill(result: result),
                ),
                const SizedBox(width: _kPreviewColGap),
                Expanded(
                  flex: _kPreviewColBlack,
                  child: LocalGamePlayerCell(
                    metadata: md,
                    side: 'Black',
                    padding: EdgeInsets.zero,
                    rating: _ratingText(md, 'BlackElo'),
                  ),
                ),
                const SizedBox(width: _kPreviewColGap),
                Expanded(
                  flex: _kPreviewColEvent,
                  child: Text(
                    event,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kWhiteColor, fontSize: 12),
                  ),
                ),
                const SizedBox(width: _kPreviewColGap),
                SizedBox(
                  width: _kPreviewColEco,
                  child: LibraryTableEcoCell(eco: _meta(md, 'ECO')),
                ),
                const SizedBox(width: _kPreviewColGap),
                SizedBox(
                  width: _kPreviewColDate,
                  child: Text(
                    date,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 11,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
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

class _MiniDatabasePreviewFrame extends StatelessWidget {
  const _MiniDatabasePreviewFrame({
    required this.title,
    this.subtitle,
    this.treeBuildProgress,
    this.onOpenTree,
    this.onBuildTree,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final LocalChessTreeBuildProgress? treeBuildProgress;
  final VoidCallback? onOpenTree;
  final VoidCallback? onBuildTree;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LibraryChromeBar(
          icon: Icons.preview_outlined,
          title: title,
          meta: subtitle,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onOpenTree != null ||
                  onBuildTree != null ||
                  treeBuildProgress != null) ...[
                LocalTreeActionButton(
                  progress: treeBuildProgress,
                  onOpen: onOpenTree,
                  onBuild: onBuildTree,
                ),
                const SizedBox(width: 6),
              ],
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

// Kept as the legacy direct-folder body while the Library home migrates to
// reference-style database tiles; full database browsing now opens via
// DatabaseWorkspacePane instead.
// ignore: unused_element
class _FolderContentView extends HookConsumerWidget {
  const _FolderContentView({
    required this.folderId,
    required this.folders,
    required this.onOpenLocalFiles,
    required this.onNewFolder,
    required this.onOpenEditor,
    required this.onOpenExplorer,
  });

  final String? folderId;
  final List<LibraryFolder> folders;
  final VoidCallback onOpenLocalFiles;
  final VoidCallback onNewFolder;
  final VoidCallback onOpenEditor;
  final VoidCallback onOpenExplorer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (folderId == null) {
      return const _LibraryEmpty(
        icon: Icons.collections_bookmark_outlined,
        title: 'Pick a folder',
        message:
            'Select one in the rail or create a new folder to start '
            'building your library.',
      );
    }
    // TWIC is the synthetic, read-only system database — it doesn't have a
    // saved-analysis backing, so it gets its own gamebase-driven view that
    // shares the same chrome (header / view-mode toggle / DesktopGameCard
    // layouts) as personal folders.
    if (folderId == kTwicBookId) {
      return _TwicContentView(
        onNewFolder: onNewFolder,
        onOpenLocalFiles: onOpenLocalFiles,
        onOpenEditor: onOpenEditor,
        onOpenExplorer: onOpenExplorer,
      );
    }
    LibraryFolder? folder;
    for (final f in folders) {
      if (f.id == folderId) {
        folder = f;
        break;
      }
    }
    if (folder == null) {
      return const _LibraryEmpty(
        icon: Icons.folder_off_outlined,
        title: 'Folder not found',
        message: 'It may have been removed or moved.',
      );
    }
    final activeFolder = folder;

    // Bump to re-fetch the analyses list after a destructive action
    // (delete) without invalidating any folder-level provider.
    final refreshNonce = useState(0);
    final cloudRefreshNonce = ref.watch(cloudLibraryRefreshNonceProvider);
    final analysesAsync = useFuture(
      useMemoized(
        () =>
            activeFolder.isSubscribed
                ? ref
                    .read(libraryRepositoryProvider)
                    .getSharedFolderAnalysesPaginated(
                      folderId: activeFolder.id,
                      limit: 200,
                    )
                : ref
                    .read(libraryRepositoryProvider)
                    .getSavedAnalyses(folderId: activeFolder.id),
        [
          activeFolder.id,
          activeFolder.isSubscribed,
          refreshNonce.value,
          cloudRefreshNonce,
        ],
      ),
    );

    final searchController = useTextEditingController();
    final query = useState<String>('');
    final viewMode = useState(_GamesViewMode.table);
    final sort = useState(const _SortConfig(_SortKey.saved, _SortDir.desc));
    final selectedIds = useState<Set<String>>(<String>{});
    final selectionAnchor = useState<int?>(null);
    final selectionExtent = useState<int?>(null);

    final filtered = useMemoized<List<SavedAnalysis>>(() {
      final all = analysesAsync.data ?? const <SavedAnalysis>[];
      final q = query.value.trim().toLowerCase();
      final base =
          q.isEmpty
              ? List<SavedAnalysis>.of(all)
              : all.where((a) {
                if (a.title.toLowerCase().contains(q)) return true;
                for (final entry in a.chessGame.metadata.entries) {
                  final v = entry.value;
                  if (v is String && v.toLowerCase().contains(q)) return true;
                }
                return false;
              }).toList();
      _sortAnalyses(base, sort.value);
      return base;
    }, [analysesAsync.data, query.value, sort.value]);

    final hasGames =
        analysesAsync.data != null && analysesAsync.data!.isNotEmpty;

    final visibleIds = filtered.map((a) => a.id).toList(growable: false);
    final clampedSelected = LibraryMultiSelect.clampToRows(
      selectedIds.value,
      visibleIds,
    );

    void setRangeSelection(int rowIndex) {
      if (visibleIds.isEmpty) return;
      final anchor =
          (selectionAnchor.value ?? rowIndex)
              .clamp(0, visibleIds.length - 1)
              .toInt();
      final extent = rowIndex.clamp(0, visibleIds.length - 1).toInt();
      selectedIds.value = LibraryMultiSelect.range(
        rowIds: visibleIds,
        from: anchor,
        to: extent,
      );
      selectionAnchor.value = anchor;
      selectionExtent.value = extent;
    }

    void primeSelectionAnchor(int rowIndex) {
      if (visibleIds.isEmpty) return;
      final anchor = rowIndex.clamp(0, visibleIds.length - 1).toInt();
      selectionAnchor.value = anchor;
      selectionExtent.value = anchor;
      if (selectedIds.value.isNotEmpty) {
        selectedIds.value = <String>{};
      }
    }

    void selectContextMenuRow(int rowIndex) {
      if (visibleIds.isEmpty) return;
      final index = rowIndex.clamp(0, visibleIds.length - 1).toInt();
      final rowId = visibleIds[index];
      // A context menu on one of several selected rows must retain that
      // selection so Copy PGN still acts on the intended group.
      if (clampedSelected.contains(rowId)) return;
      selectedIds.value = LibraryMultiSelect.contextMenuSelection(
        selectedIds: clampedSelected,
        rowId: rowId,
      );
      selectionAnchor.value = index;
      selectionExtent.value = index;
    }

    void extendSelectionBy(int delta) {
      final next = LibraryMultiSelect.nextExtent(
        rowIds: visibleIds,
        extent: selectionExtent.value ?? selectionAnchor.value,
        delta: delta,
      );
      if (next == null) return;
      setRangeSelection(next);
    }

    final selectedAnalyses =
        filtered.where((a) => selectedIds.value.contains(a.id)).toList();
    final copyScope = selectedAnalyses.isEmpty ? filtered : selectedAnalyses;

    void pasteIntoActiveFolder() {
      if (!isWritableLibraryFolder(activeFolder)) {
        showDesktopToast(
          context,
          '"${activeFolder.name}" is read-only.',
          error: true,
        );
        return;
      }
      unawaited(
        quickImportClipboardToFolder(
          context: context,
          ref: ref,
          folder: activeFolder,
        ),
      );
    }

    return Container(
      color: kBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FolderHeader(
            folder: activeFolder,
            count: analysesAsync.data?.length,
            isLoading: analysesAsync.connectionState != ConnectionState.done,
            isDatabase: libraryFolderIsDatabase(
              activeFolder,
              folders,
              gameCount: analysesAsync.data?.length,
            ),
            canCreateSubfolder:
                !activeFolder.isSubscribed &&
                !libraryFolderIsDatabase(
                  activeFolder,
                  folders,
                  gameCount: analysesAsync.data?.length,
                ),
            hasGames: hasGames,
            onAction:
                (action) => _onFolderAction(
                  context: context,
                  ref: ref,
                  folder: activeFolder,
                  action: action,
                  allFolders: folders,
                ),
            onNewFolder: onNewFolder,
            onOpenLocalFiles: onOpenLocalFiles,
            onOpenEditor: onOpenEditor,
            onOpenExplorer: onOpenExplorer,
          ),
          _ContentToolbar(
            searchController: searchController,
            onSearchChanged: (v) => query.value = v,
            onSearchClear: () => query.value = '',
            viewMode: viewMode.value,
            onViewModeChanged: (m) => viewMode.value = m,
            onExport:
                hasGames
                    ? () => _onFolderAction(
                      context: context,
                      ref: ref,
                      folder: activeFolder,
                      action: LibraryFolderAction.exportPgn,
                      allFolders: folders,
                    )
                    : null,
          ),
          Expanded(
            child: _LibraryBodyShortcuts(
              folder: activeFolder,
              copyScope: copyScope,
              onPaste: pasteIntoActiveFolder,
              onExtendSelectionUp: () => extendSelectionBy(-1),
              onExtendSelectionDown: () => extendSelectionBy(1),
              child: FolderDropTarget(
                enabled: isWritableLibraryFolder(activeFolder),
                folderName: activeFolder.name,
                style: FolderDropStyle.body,
                onAcceptPaths:
                    (paths) => quickImportPathsToFolder(
                      context: context,
                      ref: ref,
                      folder: activeFolder,
                      paths: paths,
                    ),
                child: _GamesBody(
                  folder: activeFolder,
                  snapshot: analysesAsync,
                  filtered: filtered,
                  query: query.value,
                  viewMode: viewMode.value,
                  sort: sort.value,
                  onSortChange: (next) => sort.value = next,
                  selectedIds: clampedSelected,
                  onPrimeSelectionAnchor: primeSelectionAnchor,
                  onRangeSelect: setRangeSelection,
                  onContextMenuSelect: selectContextMenuRow,
                  onGameAction: (analysis, action) {
                    if (action == LibraryGameAction.selectAll) {
                      selectedIds.value = visibleIds.toSet();
                      selectionAnchor.value = visibleIds.isEmpty ? null : 0;
                      selectionExtent.value =
                          visibleIds.isEmpty ? null : visibleIds.length - 1;
                      return;
                    }
                    if (action == LibraryGameAction.pasteGames) {
                      pasteIntoActiveFolder();
                      return;
                    }
                    if (action == LibraryGameAction.copyPgn &&
                        selectedIds.value.contains(analysis.id)) {
                      // A context menu can replace selection immediately
                      // before it dispatches this action. Resolve the scope
                      // at dispatch time so right-clicking an unselected row
                      // never copies a stale multi-selection.
                      final currentSelectedAnalyses =
                          filtered
                              .where(
                                (item) => selectedIds.value.contains(item.id),
                              )
                              .toList();
                      if (currentSelectedAnalyses.length <= 1) {
                        _onGameAction(
                          context: context,
                          ref: ref,
                          analysis: analysis,
                          action: action,
                          onChanged: () => refreshNonce.value++,
                        );
                        return;
                      }
                      unawaited(
                        copySavedAnalysesAsPgn(
                          context: context,
                          analyses: currentSelectedAnalyses,
                        ),
                      );
                      return;
                    }
                    _onGameAction(
                      context: context,
                      ref: ref,
                      analysis: analysis,
                      action: action,
                      onChanged: () => refreshNonce.value++,
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Wraps the active folder's games body with a focus + shortcut scope so
/// `Ctrl/Cmd+C` copies the visible games as a multi-PGN blob and
/// `Ctrl/Cmd+V` pastes clipboard PGN(s) directly into the folder. The
/// search field claims focus when interacted with, so typing-into-search
/// still pastes plain text — these shortcuts only fire when focus rests on
/// the body region.
class _LibraryBodyShortcuts extends HookWidget {
  const _LibraryBodyShortcuts({
    required this.folder,
    required this.copyScope,
    required this.onPaste,
    required this.onExtendSelectionUp,
    required this.onExtendSelectionDown,
    required this.child,
  });

  final LibraryFolder folder;
  final List<SavedAnalysis> copyScope;
  final VoidCallback onPaste;
  final VoidCallback onExtendSelectionUp;
  final VoidCallback onExtendSelectionDown;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final focusNode = useFocusNode(debugLabel: 'library_body_${folder.id}');
    // Re-claim focus when the user switches between folders so the next
    // Ctrl+V/Ctrl+C lands without having to click the empty listview first.
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (focusNode.canRequestFocus) focusNode.requestFocus();
      });
      return null;
    }, [folder.id]);

    void handleCopy() {
      unawaited(copySavedAnalysesAsPgn(context: context, analyses: copyScope));
    }

    return Focus(
      focusNode: focusNode,
      canRequestFocus: true,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (focusNode.canRequestFocus) focusNode.requestFocus();
        },
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.keyV, meta: true): onPaste,
            const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                onPaste,
            const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
                handleCopy,
            const SingleActivator(LogicalKeyboardKey.keyC, control: true):
                handleCopy,
            const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true):
                onExtendSelectionUp,
            const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true):
                onExtendSelectionDown,
          },
          child: child,
        ),
      ),
    );
  }
}

class _FolderHeader extends StatelessWidget {
  const _FolderHeader({
    required this.folder,
    required this.count,
    required this.isLoading,
    required this.isDatabase,
    required this.canCreateSubfolder,
    required this.hasGames,
    required this.onAction,
    required this.onNewFolder,
    required this.onOpenLocalFiles,
    required this.onOpenEditor,
    required this.onOpenExplorer,
    this.showOverflow = true,
    this.subtitleOverride,
    this.iconOverride,
    this.badge,
  });

  final LibraryFolder folder;
  final int? count;
  final bool isLoading;
  final bool isDatabase;
  final bool canCreateSubfolder;
  final bool hasGames;
  final ValueChanged<LibraryFolderAction>? onAction;
  final VoidCallback onNewFolder;
  final VoidCallback onOpenLocalFiles;
  final VoidCallback onOpenEditor;
  final VoidCallback onOpenExplorer;

  /// When false the overflow `…` button is hidden — used by TWIC, which is
  /// non-rename/non-delete and doesn't need an actions menu.
  final bool showOverflow;

  /// Replaces the auto-built "N games" subtitle when set.
  final String? subtitleOverride;

  /// Replaces the default folder icon (used for the TWIC system icon).
  final IconData? iconOverride;

  /// Optional badge widget rendered next to the folder name (TWIC uses
  /// this for the "System database" pill).
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final subtitle =
        subtitleOverride ??
        (isLoading
            ? 'Loading…'
            : (count == null
                ? 'Unknown count'
                : '${count!} ${count == 1 ? 'game' : 'games'}'));
    final icon =
        iconOverride ??
        (folder.isSubscribed
            ? Icons.cloud_done_outlined
            : isDatabase
            ? Icons.storage_outlined
            : Icons.folder_rounded);
    return LibraryChromeBar(
      icon: icon,
      title: folder.name,
      meta: subtitle,
      accent:
          isDatabase
              ? _LibraryKindChrome.databaseCyan
              : _LibraryKindChrome.folderAmber,
      badge: badge ?? (folder.isSubscribed ? const _ReadOnlyBadge() : null),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LibraryActionsToolbar(
            suggestedFolderId:
                (folder.isSubscribed || folder.id == kTwicBookId)
                    ? null
                    : folder.id,
            onNewFolder: null,
            onNewDatabase: onNewFolder,
            showNewFolderAction: false,
            onImportPgnFiles: onOpenLocalFiles,
            buttonSize: 28,
            iconSize: 14.5,
            spacing: 4,
            hitSize: 34,
          ),
          if (showOverflow &&
              onAction != null &&
              !folder.isSubscribed &&
              !folder.isPermanentLibraryFolder) ...[
            const SizedBox(width: 4),
            DesktopDialogIconButton(
              icon: Icons.delete_outline_rounded,
              tooltip: isDatabase ? 'Delete database' : 'Delete folder',
              tone: DesktopDialogButtonTone.danger,
              onPress: () => onAction!(LibraryFolderAction.delete),
            ),
          ],
          if (showOverflow && onAction != null) ...[
            const SizedBox(width: 2),
            _OverflowMenuButton(
              folder: folder,
              canCreateSubfolder: canCreateSubfolder,
              hasGames: hasGames,
              onAction: onAction!,
            ),
          ],
        ],
      ),
    );
  }
}

class _ReadOnlyBadge extends StatelessWidget {
  const _ReadOnlyBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: kBlack3Color.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: kDividerColor.withValues(alpha: 0.85)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline_rounded, size: 9, color: kLightGreyColor),
          SizedBox(width: 4),
          Text(
            'Subscribed',
            style: TextStyle(
              color: kLightGreyColor,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _OverflowMenuButton extends StatefulWidget {
  const _OverflowMenuButton({
    required this.folder,
    required this.canCreateSubfolder,
    required this.hasGames,
    required this.onAction,
  });

  final LibraryFolder folder;
  final bool canCreateSubfolder;
  final bool hasGames;
  final ValueChanged<LibraryFolderAction> onAction;

  @override
  State<_OverflowMenuButton> createState() => _OverflowMenuButtonState();
}

class _OverflowMenuButtonState extends State<_OverflowMenuButton>
    with DeferredPointerStateMixin<_OverflowMenuButton> {
  final GlobalKey _key = GlobalKey();
  bool _hovered = false;

  void _open() {
    final ctx = _key.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset(0, box.size.height + 4));
    showLibraryFolderActionsMenu(
      context: context,
      anchor: pos,
      folder: widget.folder,
      canCreateDatabase: widget.canCreateSubfolder,
      hasGames: widget.hasGames,
      includeLibraryHomeAction: false,
      onAction: widget.onAction,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: 'More actions',
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
          onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
          child: GestureDetector(
            key: _key,
            behavior: HitTestBehavior.opaque,
            onTap: _open,
            child: Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hovered ? kBlack3Color : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _hovered ? kDividerColor : Colors.transparent,
                ),
              ),
              child: Icon(
                Icons.more_horiz_rounded,
                size: 18,
                color: _hovered ? kWhiteColor : kWhiteColor70,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContentToolbar extends StatelessWidget {
  const _ContentToolbar({
    required this.searchController,
    required this.onSearchChanged,
    required this.onSearchClear,
    required this.viewMode,
    required this.onViewModeChanged,
    required this.onExport,
  });

  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchClear;
  final _GamesViewMode viewMode;
  final ValueChanged<_GamesViewMode> onViewModeChanged;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBackgroundColor,
        border: Border(
          bottom: BorderSide(color: kDividerColor.withValues(alpha: 0.75)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: DesktopSearchField(
                controller: searchController,
                hintText: 'Search games — names, event, opening, ECO',
                onChanged: onSearchChanged,
                onClear: onSearchClear,
              ),
            ),
            const SizedBox(width: 8),
            _ViewModeToggle(value: viewMode, onChanged: onViewModeChanged),
            const SizedBox(width: 8),
            DesktopTooltip(
              message:
                  onExport == null
                      ? 'Folder is empty'
                      : 'Export this folder as a .pgn file',
              child: FButton(
                style: FButtonStyle.outline(),
                onPress: onExport,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.save_alt_rounded, size: 12),
                    SizedBox(width: 5),
                    Text('Export', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ViewModeToggle extends StatelessWidget {
  const _ViewModeToggle({required this.value, required this.onChanged});

  final _GamesViewMode value;
  final ValueChanged<_GamesViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: kDividerColor),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ViewModeButton(
            icon: Icons.table_rows_outlined,
            tooltip: 'Table view',
            selected: value == _GamesViewMode.table,
            onTap: () => onChanged(_GamesViewMode.table),
          ),
          _ViewModeButton(
            icon: Icons.view_agenda_outlined,
            tooltip: 'Card view',
            selected: value == _GamesViewMode.compact,
            onTap: () => onChanged(_GamesViewMode.compact),
          ),
          _ViewModeButton(
            icon: Icons.view_list_rounded,
            tooltip: 'List view',
            selected: value == _GamesViewMode.list,
            onTap: () => onChanged(_GamesViewMode.list),
          ),
          _ViewModeButton(
            icon: Icons.grid_view_rounded,
            tooltip: 'Grid view',
            selected: value == _GamesViewMode.grid,
            onTap: () => onChanged(_GamesViewMode.grid),
          ),
        ],
      ),
    );
  }
}

class _ViewModeButton extends StatefulWidget {
  const _ViewModeButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ViewModeButton> createState() => _ViewModeButtonState();
}

class _ViewModeButtonState extends State<_ViewModeButton>
    with DeferredPointerStateMixin<_ViewModeButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final fg =
        widget.selected
            ? kPrimaryColor
            : (_hovered ? kWhiteColor : kWhiteColor70);
    final bg =
        widget.selected
            ? kPrimaryColor.withValues(alpha: 0.14)
            : (_hovered ? kBlack3Color : Colors.transparent);
    return DesktopTooltip(
      message: widget.tooltip,
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
          onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 30,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Icon(widget.icon, size: 13, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// Games body — table or cards
// =====================================================================

class _GamesBody extends ConsumerWidget {
  const _GamesBody({
    required this.folder,
    required this.snapshot,
    required this.filtered,
    required this.query,
    required this.viewMode,
    required this.sort,
    required this.onSortChange,
    required this.selectedIds,
    required this.onPrimeSelectionAnchor,
    required this.onRangeSelect,
    required this.onContextMenuSelect,
    required this.onGameAction,
  });

  final LibraryFolder folder;
  final AsyncSnapshot<List<SavedAnalysis>> snapshot;
  final List<SavedAnalysis> filtered;
  final String query;
  final _GamesViewMode viewMode;
  final _SortConfig sort;
  final ValueChanged<_SortConfig> onSortChange;
  final Set<String> selectedIds;
  final ValueChanged<int> onPrimeSelectionAnchor;
  final ValueChanged<int> onRangeSelect;
  final ValueChanged<int> onContextMenuSelect;
  final void Function(SavedAnalysis analysis, LibraryGameAction action)
  onGameAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
          ),
        ),
      );
    }
    if (snapshot.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Could not load games: ${snapshot.error}',
            style: const TextStyle(color: kRedColor, fontSize: 12),
          ),
        ),
      );
    }
    final all = snapshot.data ?? const <SavedAnalysis>[];
    if (all.isEmpty) {
      return _LibraryEmpty(
        icon:
            folder.isSubscribed
                ? Icons.cloud_off_rounded
                : Icons.collections_bookmark_outlined,
        title:
            folder.isSubscribed
                ? 'Subscribed folder is empty'
                : 'This folder is empty',
        message:
            folder.isSubscribed
                ? 'Wait for the owner to share games into it.'
                : 'Drop a .pgn onto this window, paste a PGN from your '
                    'clipboard, or use the Import PGN file action above.',
      );
    }
    if (filtered.isEmpty) {
      return _LibraryEmpty(
        icon: Icons.search_off_rounded,
        title: 'No games match "$query"',
        message: 'Try a different word or clear the search.',
      );
    }
    switch (viewMode) {
      case _GamesViewMode.table:
        return _GamesTable(
          rows: filtered,
          sort: sort,
          onSortChange: onSortChange,
          onOpen:
              (a) => _openAnalysis(
                ref,
                a,
                databaseTitle: folder.name,
                databaseAnalyses: all,
              ),
          canDelete: isWritableLibraryFolder(folder),
          selectedIds: selectedIds,
          onPrimeSelectionAnchor: onPrimeSelectionAnchor,
          onRangeSelect: onRangeSelect,
          onContextMenuSelect: onContextMenuSelect,
          onAction: onGameAction,
        );
      case _GamesViewMode.grid:
        return _GamesGrid(
          rows: filtered,
          databaseRows: all,
          databaseTitle: folder.name,
          onOpen:
              (a) => _openAnalysis(
                ref,
                a,
                databaseTitle: folder.name,
                databaseAnalyses: all,
              ),
          canDelete: isWritableLibraryFolder(folder),
          selectedIds: selectedIds,
          onPrimeSelectionAnchor: onPrimeSelectionAnchor,
          onRangeSelect: onRangeSelect,
          onContextMenuSelect: onContextMenuSelect,
          onAction: onGameAction,
        );
      case _GamesViewMode.compact:
        return _GamesCards(
          rows: filtered,
          databaseRows: all,
          databaseTitle: folder.name,
          layout: DesktopCardLayout.compact,
          onOpen:
              (a) => _openAnalysis(
                ref,
                a,
                databaseTitle: folder.name,
                databaseAnalyses: all,
              ),
          canDelete: isWritableLibraryFolder(folder),
          selectedIds: selectedIds,
          onPrimeSelectionAnchor: onPrimeSelectionAnchor,
          onRangeSelect: onRangeSelect,
          onContextMenuSelect: onContextMenuSelect,
          onAction: onGameAction,
        );
      case _GamesViewMode.list:
        return _GamesCards(
          rows: filtered,
          databaseRows: all,
          databaseTitle: folder.name,
          layout: DesktopCardLayout.list,
          onOpen:
              (a) => _openAnalysis(
                ref,
                a,
                databaseTitle: folder.name,
                databaseAnalyses: all,
              ),
          canDelete: isWritableLibraryFolder(folder),
          selectedIds: selectedIds,
          onPrimeSelectionAnchor: onPrimeSelectionAnchor,
          onRangeSelect: onRangeSelect,
          onContextMenuSelect: onContextMenuSelect,
          onAction: onGameAction,
        );
    }
  }
}

class _GamesCards extends StatelessWidget {
  const _GamesCards({
    required this.rows,
    required this.databaseRows,
    required this.databaseTitle,
    required this.layout,
    required this.onOpen,
    required this.canDelete,
    required this.selectedIds,
    required this.onPrimeSelectionAnchor,
    required this.onRangeSelect,
    required this.onContextMenuSelect,
    required this.onAction,
  });

  final List<SavedAnalysis> rows;
  final List<SavedAnalysis> databaseRows;
  final String databaseTitle;

  /// Vertical-list layouts only — [DesktopCardLayout.compact] or
  /// [DesktopCardLayout.list]. Grid renders through [_GamesGrid] (which
  /// can't share this single-column ListView).
  final DesktopCardLayout layout;
  final ValueChanged<SavedAnalysis> onOpen;
  final bool canDelete;
  final Set<String> selectedIds;
  final ValueChanged<int> onPrimeSelectionAnchor;
  final ValueChanged<int> onRangeSelect;
  final ValueChanged<int> onContextMenuSelect;
  final void Function(SavedAnalysis analysis, LibraryGameAction action)
  onAction;

  @override
  Widget build(BuildContext context) {
    return DesktopGameCardsFlow(
      layout: layout,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final a = rows[i];
        return LibraryGameContextMenu(
          analysis: a,
          canDelete: canDelete,
          canPaste: canDelete,
          onContextMenuOpening: () => onContextMenuSelect(i),
          onAction: (action) => onAction(a, action),
          child: _SelectableLibraryGameCard(
            index: i,
            selected: selectedIds.contains(a.id),
            onPrimeSelectionAnchor: onPrimeSelectionAnchor,
            onRangeSelect: onRangeSelect,
            child: DesktopGameCard(
              data: GameCardData.fromSavedAnalysis(a),
              onTap: () {
                if (HardwareKeyboard.instance.isShiftPressed) return;
                onOpen(a);
              },
              dragPayload: GameTabDragPayload(
                id: a.id,
                label: a.title,
                spawn: (r, {required focus}) async {
                  _openAnalysis(
                    r,
                    a,
                    focus: focus,
                    databaseTitle: databaseTitle,
                    databaseAnalyses: databaseRows,
                  );
                },
              ),
              layout: layout,
            ),
          ),
        );
      },
    );
  }
}

/// Grid rendering for the Library. Mirrors `_GamesGrid` in
/// `tournament_games_view.dart` (target ~280 px columns, square-ish
/// tiles), but wraps each cell in [LibraryGameContextMenu] so right-click
/// still opens the saved-analysis menu.
class _GamesGrid extends StatelessWidget {
  const _GamesGrid({
    required this.rows,
    required this.databaseRows,
    required this.databaseTitle,
    required this.onOpen,
    required this.canDelete,
    required this.selectedIds,
    required this.onPrimeSelectionAnchor,
    required this.onRangeSelect,
    required this.onContextMenuSelect,
    required this.onAction,
  });

  final List<SavedAnalysis> rows;
  final List<SavedAnalysis> databaseRows;
  final String databaseTitle;
  final ValueChanged<SavedAnalysis> onOpen;
  final bool canDelete;
  final Set<String> selectedIds;
  final ValueChanged<int> onPrimeSelectionAnchor;
  final ValueChanged<int> onRangeSelect;
  final ValueChanged<int> onContextMenuSelect;
  final void Function(SavedAnalysis analysis, LibraryGameAction action)
  onAction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const targetWidth = 280.0;
        final columns = (constraints.maxWidth / targetWidth).floor().clamp(
          2,
          6,
        );
        return GridView.builder(
          physics: const DesktopScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          itemCount: rows.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.95,
          ),
          itemBuilder: (context, i) {
            final a = rows[i];
            return LibraryGameContextMenu(
              analysis: a,
              canDelete: canDelete,
              canPaste: canDelete,
              onContextMenuOpening: () => onContextMenuSelect(i),
              onAction: (action) => onAction(a, action),
              child: _SelectableLibraryGameCard(
                index: i,
                selected: selectedIds.contains(a.id),
                onPrimeSelectionAnchor: onPrimeSelectionAnchor,
                onRangeSelect: onRangeSelect,
                child: DesktopGameCard(
                  data: GameCardData.fromSavedAnalysis(a),
                  onTap: () {
                    if (HardwareKeyboard.instance.isShiftPressed) return;
                    onOpen(a);
                  },
                  dragPayload: GameTabDragPayload(
                    id: a.id,
                    label: a.title,
                    spawn: (r, {required focus}) async {
                      _openAnalysis(
                        r,
                        a,
                        focus: focus,
                        databaseTitle: databaseTitle,
                        databaseAnalyses: databaseRows,
                      );
                    },
                  ),
                  layout: DesktopCardLayout.grid,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _SelectableLibraryGameCard extends StatefulWidget {
  const _SelectableLibraryGameCard({
    required this.index,
    required this.selected,
    required this.onPrimeSelectionAnchor,
    required this.onRangeSelect,
    required this.child,
  });

  final int index;
  final bool selected;
  final ValueChanged<int> onPrimeSelectionAnchor;
  final ValueChanged<int> onRangeSelect;
  final Widget child;

  @override
  State<_SelectableLibraryGameCard> createState() =>
      _SelectableLibraryGameCardState();
}

class _SelectableLibraryGameCardState
    extends State<_SelectableLibraryGameCard> {
  bool _suppressNextTap = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.buttons & kPrimaryMouseButton == 0) return;
        if (HardwareKeyboard.instance.isShiftPressed) {
          widget.onRangeSelect(widget.index);
          _suppressNextTap = true;
        } else {
          widget.onPrimeSelectionAnchor(widget.index);
        }
      },
      onPointerMove: (event) {
        if (event.buttons & kPrimaryMouseButton == 0) return;
        widget.onRangeSelect(widget.index);
        _suppressNextTap = true;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (_suppressNextTap) {
            _suppressNextTap = false;
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          decoration:
              widget.selected
                  ? BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kPrimaryColor, width: 1.5),
                    color: kPrimaryColor.withValues(alpha: 0.10),
                  )
                  : null,
          child: widget.child,
        ),
      ),
    );
  }
}

// =====================================================================
// Sortable games table
// =====================================================================

class _GamesTable extends HookWidget {
  const _GamesTable({
    required this.rows,
    required this.sort,
    required this.onSortChange,
    required this.onOpen,
    required this.canDelete,
    required this.selectedIds,
    required this.onPrimeSelectionAnchor,
    required this.onRangeSelect,
    required this.onContextMenuSelect,
    required this.onAction,
  });

  final List<SavedAnalysis> rows;
  final _SortConfig sort;
  final ValueChanged<_SortConfig> onSortChange;
  final ValueChanged<SavedAnalysis> onOpen;
  final bool canDelete;
  final Set<String> selectedIds;
  final ValueChanged<int> onPrimeSelectionAnchor;
  final ValueChanged<int> onRangeSelect;
  final ValueChanged<int> onContextMenuSelect;
  final void Function(SavedAnalysis analysis, LibraryGameAction action)
  onAction;

  @override
  Widget build(BuildContext context) {
    final scrollController = useScrollController();
    final columnFlexes = useState(const _GamesTableColumnFlexes());
    final columnOrder = useState(_defaultGamesTableColumns);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Container(
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kDividerColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            _GamesTableHeader(
              sort: sort,
              onSortChange: onSortChange,
              columnFlexes: columnFlexes.value,
              columnOrder: columnOrder.value,
              onColumnFlexesChanged: (next) => columnFlexes.value = next,
              onColumnOrderChanged: (next) => columnOrder.value = next,
            ),
            const Divider(height: 1, color: kDividerColor),
            Expanded(
              child: ListKeyboardScrollFocus(
                controller: scrollController,
                step: 48,
                child: ListView.separated(
                  controller: scrollController,
                  physics: const DesktopScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemCount: rows.length,
                  separatorBuilder:
                      (_, __) => const Divider(height: 1, color: kDividerColor),
                  itemBuilder:
                      (context, i) => _GamesTableRow(
                        index: i + 1,
                        analysis: rows[i],
                        onOpen: () => onOpen(rows[i]),
                        canDelete: canDelete,
                        selectedIds: selectedIds,
                        columnFlexes: columnFlexes.value,
                        columnOrder: columnOrder.value,
                        onPrimeSelectionAnchor:
                            (_) => onPrimeSelectionAnchor(i),
                        onRangeSelect: (_) => onRangeSelect(i),
                        onContextMenuSelect: (_) => onContextMenuSelect(i),
                        onAction: (action) => onAction(rows[i], action),
                      ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Shared column widths so header and rows always align. Every visible
// games-table column is resizable, reorderable, hideable, and addable.
const _kColNumber = 30.0;
const _kColElo = 56.0;
const _kColResult = 56.0;
const _kColEco = 62.0;
const _kColDate = 88.0;
const _kColSaved = 78.0;
const _kColPlayerWidth = 150.0;
const _kColEventWidth = 128.0;

const _defaultGamesTableColumns = <_GamesTableColumn>[
  _GamesTableColumn.number,
  _GamesTableColumn.white,
  _GamesTableColumn.whiteElo,
  _GamesTableColumn.result,
  _GamesTableColumn.black,
  _GamesTableColumn.blackElo,
  _GamesTableColumn.event,
  _GamesTableColumn.eco,
  _GamesTableColumn.date,
  _GamesTableColumn.saved,
];

enum _GamesTableColumn {
  number,
  white,
  whiteElo,
  result,
  black,
  blackElo,
  event,
  eco,
  date,
  saved,
}

extension _GamesTableColumnMeta on _GamesTableColumn {
  String get label => switch (this) {
    _GamesTableColumn.number => '#',
    _GamesTableColumn.white => 'White',
    _GamesTableColumn.whiteElo => 'Elo W',
    _GamesTableColumn.result => 'Result',
    _GamesTableColumn.black => 'Black',
    _GamesTableColumn.blackElo => 'Elo B',
    _GamesTableColumn.event => 'Event',
    _GamesTableColumn.eco => 'ECO',
    _GamesTableColumn.date => 'Date',
    _GamesTableColumn.saved => 'Saved',
  };

  _SortKey get sortKey => switch (this) {
    _GamesTableColumn.number => _SortKey.number,
    _GamesTableColumn.white => _SortKey.white,
    _GamesTableColumn.whiteElo => _SortKey.whiteElo,
    _GamesTableColumn.result => _SortKey.result,
    _GamesTableColumn.black => _SortKey.black,
    _GamesTableColumn.blackElo => _SortKey.blackElo,
    _GamesTableColumn.event => _SortKey.event,
    _GamesTableColumn.eco => _SortKey.eco,
    _GamesTableColumn.date => _SortKey.date,
    _GamesTableColumn.saved => _SortKey.saved,
  };

  bool get alignEnd => switch (this) {
    _GamesTableColumn.number ||
    _GamesTableColumn.whiteElo ||
    _GamesTableColumn.result ||
    _GamesTableColumn.blackElo ||
    _GamesTableColumn.saved => true,
    _ => false,
  };
}

class _GamesTableColumnFlexes {
  const _GamesTableColumnFlexes({
    this.number = _kColNumber,
    this.white = _kColPlayerWidth,
    this.whiteElo = _kColElo,
    this.result = _kColResult,
    this.black = _kColPlayerWidth,
    this.blackElo = _kColElo,
    this.event = _kColEventWidth,
    this.eco = _kColEco,
    this.date = _kColDate,
    this.saved = _kColSaved,
  });

  final double number;
  final double white;
  final double whiteElo;
  final double result;
  final double black;
  final double blackElo;
  final double event;
  final double eco;
  final double date;
  final double saved;

  double widthFor(_GamesTableColumn column) => switch (column) {
    _GamesTableColumn.number => number,
    _GamesTableColumn.white => white,
    _GamesTableColumn.whiteElo => whiteElo,
    _GamesTableColumn.result => result,
    _GamesTableColumn.black => black,
    _GamesTableColumn.blackElo => blackElo,
    _GamesTableColumn.event => event,
    _GamesTableColumn.eco => eco,
    _GamesTableColumn.date => date,
    _GamesTableColumn.saved => saved,
  };

  _GamesTableColumnFlexes resized(_GamesTableColumn column, double delta) {
    return switch (column) {
      _GamesTableColumn.number => copyWith(number: number + delta),
      _GamesTableColumn.white => copyWith(white: white + delta),
      _GamesTableColumn.whiteElo => copyWith(whiteElo: whiteElo + delta),
      _GamesTableColumn.result => copyWith(result: result + delta),
      _GamesTableColumn.black => copyWith(black: black + delta),
      _GamesTableColumn.blackElo => copyWith(blackElo: blackElo + delta),
      _GamesTableColumn.event => copyWith(event: event + delta),
      _GamesTableColumn.eco => copyWith(eco: eco + delta),
      _GamesTableColumn.date => copyWith(date: date + delta),
      _GamesTableColumn.saved => copyWith(saved: saved + delta),
    };
  }

  _GamesTableColumnFlexes copyWith({
    double? number,
    double? white,
    double? whiteElo,
    double? result,
    double? black,
    double? blackElo,
    double? event,
    double? eco,
    double? date,
    double? saved,
  }) {
    double clampWidth(double value, double min, double max) =>
        value.clamp(min, max).toDouble();
    return _GamesTableColumnFlexes(
      number: clampWidth(number ?? this.number, 22, 70),
      white: clampWidth(white ?? this.white, 82, 280),
      whiteElo: clampWidth(whiteElo ?? this.whiteElo, 44, 110),
      result: clampWidth(result ?? this.result, 44, 110),
      black: clampWidth(black ?? this.black, 82, 280),
      blackElo: clampWidth(blackElo ?? this.blackElo, 44, 110),
      event: clampWidth(event ?? this.event, 70, 260),
      eco: clampWidth(eco ?? this.eco, 44, 110),
      date: clampWidth(date ?? this.date, 64, 150),
      saved: clampWidth(saved ?? this.saved, 64, 150),
    );
  }
}

class _GamesTableHeader extends StatelessWidget {
  const _GamesTableHeader({
    required this.sort,
    required this.onSortChange,
    this.columnFlexes = const _GamesTableColumnFlexes(),
    this.columnOrder = _defaultGamesTableColumns,
    this.onColumnFlexesChanged,
    this.onColumnOrderChanged,
  });

  final _SortConfig sort;
  final ValueChanged<_SortConfig> onSortChange;
  final _GamesTableColumnFlexes columnFlexes;
  final List<_GamesTableColumn> columnOrder;
  final ValueChanged<_GamesTableColumnFlexes>? onColumnFlexesChanged;
  final ValueChanged<List<_GamesTableColumn>>? onColumnOrderChanged;

  @override
  Widget build(BuildContext context) {
    void updateWidths(_GamesTableColumnFlexes next) {
      onColumnFlexesChanged?.call(next);
    }

    void reorder(_GamesTableColumn dragged, _GamesTableColumn target) {
      if (dragged == target || onColumnOrderChanged == null) return;
      final next = List<_GamesTableColumn>.of(columnOrder)..remove(dragged);
      final targetIndex = next.indexOf(target);
      next.insert(targetIndex < 0 ? next.length : targetIndex, dragged);
      onColumnOrderChanged!(next);
    }

    Future<void> showColumnMenu(
      _GamesTableColumn column,
      Offset position,
    ) async {
      if (onColumnOrderChanged == null) return;
      final hidden = _defaultGamesTableColumns
          .where((candidate) => !columnOrder.contains(candidate))
          .toList(growable: false);
      final picked = await showDesktopContextMenu<String>(
        context: context,
        position: position,
        width: 220,
        entries: [
          DesktopContextMenuItem(
            value: 'hide:${column.name}',
            icon: Icons.visibility_off_outlined,
            label: 'Hide ${column.label}',
            enabled: columnOrder.length > 1,
          ),
          if (hidden.isNotEmpty) const DesktopContextMenuDivider(),
          for (final hiddenColumn in hidden)
            DesktopContextMenuItem(
              value: 'add:${hiddenColumn.name}',
              icon: Icons.add_rounded,
              label: 'Add ${hiddenColumn.label}',
            ),
        ],
      );
      if (picked == null) return;
      final parts = picked.split(':');
      if (parts.length != 2) return;
      final pickedColumn = _defaultGamesTableColumns.firstWhere(
        (candidate) => candidate.name == parts[1],
        orElse: () => column,
      );
      if (parts[0] == 'hide') {
        if (columnOrder.length <= 1) return;
        onColumnOrderChanged!(
          columnOrder.where((candidate) => candidate != pickedColumn).toList(),
        );
      } else if (parts[0] == 'add' && !columnOrder.contains(pickedColumn)) {
        onColumnOrderChanged!([...columnOrder, pickedColumn]);
      }
    }

    Widget columnHeader(_GamesTableColumn column) {
      final header = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown:
            (details) =>
                unawaited(showColumnMenu(column, details.globalPosition)),
        child: SizedBox(
          width: columnFlexes.widthFor(column),
          child: _HeaderCell(
            label: column.label,
            key_: column.sortKey,
            sort: sort,
            onSortChange: onSortChange,
            alignEnd: column.alignEnd,
          ),
        ),
      );

      return DragTarget<_GamesTableColumn>(
        onWillAcceptWithDetails: (details) => details.data != column,
        onAcceptWithDetails: (details) => reorder(details.data, column),
        builder: (context, candidateData, rejectedData) {
          final active = candidateData.isNotEmpty;
          return LongPressDraggable<_GamesTableColumn>(
            data: column,
            delay: const Duration(milliseconds: 150),
            feedback: Material(
              color: Colors.transparent,
              child: Container(
                width: columnFlexes.widthFor(column),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: kBlack3Color.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: kPrimaryColor),
                ),
                child: Text(
                  column.label,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            childWhenDragging: Opacity(opacity: 0.35, child: header),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border:
                    active
                        ? Border(
                          left: BorderSide(color: kPrimaryColor, width: 2),
                        )
                        : null,
              ),
              child: header,
            ),
          );
        },
      );
    }

    final visibleColumns =
        columnOrder.isEmpty ? _defaultGamesTableColumns : columnOrder;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 10, 14, 10),
      color: kBlack3Color.withValues(alpha: 0.4),
      child: Row(
        children: [
          for (final column in visibleColumns) ...[
            columnHeader(column),
            _HeaderResizeGap(
              enabled: onColumnFlexesChanged != null,
              onDrag:
                  (delta) => updateWidths(columnFlexes.resized(column, delta)),
            ),
          ],
        ],
      ),
    );
  }
}

class _HeaderResizeGap extends StatelessWidget {
  const _HeaderResizeGap({required this.enabled, required this.onDrag});

  final bool enabled;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox(width: 10);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) {
          final delta = details.primaryDelta ?? 0;
          if (delta.abs() < 2) return;
          onDrag(delta);
        },
        child: const SizedBox(
          width: 10,
          child: Center(
            child: SizedBox(
              width: 1,
              height: 18,
              child: DecoratedBox(
                decoration: BoxDecoration(color: kDividerColor),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeaderCell extends StatefulWidget {
  const _HeaderCell({
    required this.label,
    required this.key_,
    required this.sort,
    required this.onSortChange,
    this.alignEnd = false,
  });

  final String label;
  final _SortKey key_;
  final _SortConfig sort;
  final ValueChanged<_SortConfig> onSortChange;
  final bool alignEnd;

  @override
  State<_HeaderCell> createState() => _HeaderCellState();
}

class _HeaderCellState extends State<_HeaderCell>
    with DeferredPointerStateMixin<_HeaderCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.sort.key == widget.key_;
    final color =
        active ? kPrimaryColor : (_hovered ? kWhiteColor : kLightGreyColor);
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
        onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap:
              () => widget.onSortChange(widget.sort._toggleOrSet(widget.key_)),
          child: Row(
            mainAxisAlignment:
                widget.alignEnd
                    ? MainAxisAlignment.end
                    : MainAxisAlignment.start,
            children: [
              Text(
                widget.label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
              if (active) ...[
                const SizedBox(width: 4),
                Icon(
                  widget.sort.dir == _SortDir.asc
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded,
                  size: 11,
                  color: color,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _GamesTableRow extends StatefulWidget {
  const _GamesTableRow({
    required this.index,
    required this.analysis,
    required this.onOpen,
    required this.canDelete,
    required this.selectedIds,
    this.columnFlexes = const _GamesTableColumnFlexes(),
    this.columnOrder = _defaultGamesTableColumns,
    required this.onPrimeSelectionAnchor,
    required this.onRangeSelect,
    required this.onContextMenuSelect,
    required this.onAction,
  });

  final int index;
  final SavedAnalysis analysis;
  final VoidCallback onOpen;
  final bool canDelete;
  final Set<String> selectedIds;
  final _GamesTableColumnFlexes columnFlexes;
  final List<_GamesTableColumn> columnOrder;
  final ValueChanged<int> onPrimeSelectionAnchor;
  final ValueChanged<int> onRangeSelect;
  final ValueChanged<int> onContextMenuSelect;
  final ValueChanged<LibraryGameAction> onAction;

  @override
  State<_GamesTableRow> createState() => _GamesTableRowState();
}

class _GamesTableRowState extends State<_GamesTableRow>
    with DeferredPointerStateMixin<_GamesTableRow> {
  bool _hovered = false;
  bool _suppressNextTap = false;

  bool get _selected => widget.selectedIds.contains(widget.analysis.id);

  @override
  Widget build(BuildContext context) {
    final a = widget.analysis;
    final meta = a.chessGame.metadata;
    String s(String key) => (meta[key]?.toString() ?? '').trim();

    final whiteName = s('White').isNotEmpty ? s('White') : (a.whiteName ?? '');
    final blackName = s('Black').isNotEmpty ? s('Black') : (a.blackName ?? '');
    final whiteFed =
        s('WhiteFederation').isNotEmpty ? s('WhiteFederation') : s('WhiteFed');
    final blackFed =
        s('BlackFederation').isNotEmpty ? s('BlackFederation') : s('BlackFed');
    int? fideId(String key) {
      final value = int.tryParse(s(key)) ?? 0;
      return value > 0 ? value : null;
    }

    final whiteTitle = s('WhiteTitle');
    final blackTitle = s('BlackTitle');
    final whiteRating = s('WhiteElo');
    final blackRating = s('BlackElo');
    final whiteFideId = fideId('WhiteFideId');
    final blackFideId = fideId('BlackFideId');
    final event = desktopTableDisplayValue(s('Event'));
    final round = desktopTableDisplayValue(s('Round'));
    final eco = s('ECO');
    final result = s('Result');

    final eventLine =
        round.isNotEmpty && round != '?'
            ? (event.isEmpty ? 'Round $round' : '$event · R$round')
            : event;

    final card = GameTabDragPayload(
      id: a.id,
      label: a.title,
      spawn: (r, {required focus}) async {
        _openAnalysis(r, a, focus: focus);
      },
    );

    Widget cell(_GamesTableColumn column) {
      return SizedBox(
        width: widget.columnFlexes.widthFor(column),
        child: switch (column) {
          _GamesTableColumn.number => Text(
            widget.index.toString(),
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          _GamesTableColumn.white => _PlayerCell(
            name: whiteName,
            federation: whiteFed,
            fideId: whiteFideId,
            title: whiteTitle,
          ),
          _GamesTableColumn.whiteElo => _RatingCell(rating: whiteRating),
          _GamesTableColumn.result => _ResultPill(result: result),
          _GamesTableColumn.black => _PlayerCell(
            name: blackName,
            federation: blackFed,
            fideId: blackFideId,
            title: blackTitle,
          ),
          _GamesTableColumn.blackElo => _RatingCell(rating: blackRating),
          _GamesTableColumn.event => Text(
            eventLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: kWhiteColor70, fontSize: 12),
          ),
          _GamesTableColumn.eco => _EcoCell(eco: eco),
          _GamesTableColumn.date => Text(
            _displayGameDate(s('Date')),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          _GamesTableColumn.saved => Text(
            _relativeTime(a.updatedAt),
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        },
      );
    }

    return LibraryGameContextMenu(
      analysis: a,
      canDelete: widget.canDelete,
      canPaste: widget.canDelete,
      onContextMenuOpening: () => widget.onContextMenuSelect(0),
      useLongPress: false,
      onAction: widget.onAction,
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
          onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
          child: LongPressDraggable<GameTabDragPayload>(
            data: card,
            delay: const Duration(milliseconds: 220),
            hapticFeedbackOnStart: false,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: _RowDragFeedback(
              label: '${_short(whiteName)} vs ${_short(blackName)}',
            ),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                if (event.buttons & kPrimaryMouseButton != 0) {
                  if (HardwareKeyboard.instance.isShiftPressed) {
                    widget.onRangeSelect(0);
                    _suppressNextTap = true;
                  } else {
                    widget.onPrimeSelectionAnchor(0);
                  }
                }
                if (event.buttons & kTertiaryButton != 0) {
                  widget.onAction(LibraryGameAction.openInNewTab);
                }
              },
              onPointerMove: (event) {
                if (event.buttons & kPrimaryMouseButton != 0) {
                  widget.onRangeSelect(0);
                  _suppressNextTap = true;
                }
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (_suppressNextTap) {
                    _suppressNextTap = false;
                  }
                },
                onDoubleTap: () {
                  if (isNewTabModifierPressed()) {
                    widget.onAction(LibraryGameAction.openInNewTab);
                    return;
                  }
                  widget.onOpen();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  decoration: librarySelectedRowDecoration(
                    selected: _selected,
                    hovered: _hovered,
                    bottomDivider: false,
                    selectedTint: 0.18,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      for (final column in widget.columnOrder) ...[
                        cell(column),
                        const SizedBox(width: 10),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// The library table cells now live in library_table_row_style.dart so the
// imported-local-database table renders identical rows. These aliases keep the
// existing private call-sites in this file unchanged.
typedef _PlayerCell = LibraryTablePlayerCell;
typedef _RatingCell = LibraryTableRatingCell;
typedef _EcoCell = LibraryTableEcoCell;
typedef _ResultPill = LibraryTableResultPill;

class _RowDragFeedback extends StatelessWidget {
  const _RowDragFeedback({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: kBlack3Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.grid_4x4_outlined, size: 14, color: kPrimaryColor),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
// Sorting + relative-time helpers
// =====================================================================

void _sortAnalyses(List<SavedAnalysis> rows, _SortConfig c) {
  String s(SavedAnalysis x, String key) =>
      (x.chessGame.metadata[key]?.toString() ?? '').trim().toLowerCase();
  int rating(SavedAnalysis x, String key) => int.tryParse(s(x, key)) ?? -1;
  int cmp(SavedAnalysis a, SavedAnalysis b) {
    switch (c.key) {
      case _SortKey.number:
        return a.createdAt.compareTo(b.createdAt);
      case _SortKey.white:
        return s(a, 'White').compareTo(s(b, 'White'));
      case _SortKey.whiteElo:
        return rating(a, 'WhiteElo').compareTo(rating(b, 'WhiteElo'));
      case _SortKey.result:
        return s(a, 'Result').compareTo(s(b, 'Result'));
      case _SortKey.black:
        return s(a, 'Black').compareTo(s(b, 'Black'));
      case _SortKey.blackElo:
        return rating(a, 'BlackElo').compareTo(rating(b, 'BlackElo'));
      case _SortKey.event:
        return s(a, 'Event').compareTo(s(b, 'Event'));
      case _SortKey.eco:
        return s(a, 'ECO').compareTo(s(b, 'ECO'));
      case _SortKey.date:
        return s(a, 'Date').compareTo(s(b, 'Date'));
      case _SortKey.saved:
        return a.updatedAt.compareTo(b.updatedAt);
    }
  }

  rows.sort(c.dir == _SortDir.asc ? cmp : (a, b) => cmp(b, a));
}

String _displayGameDate(String raw) {
  final value = desktopTableDisplayValue(raw);
  if (value.isEmpty) return '';
  final parts = value.split('.');
  if (parts.length == 3) {
    final year = parts[0];
    final month = parts[1];
    final day = parts[2];
    if (year.isEmpty || year.contains('?')) return '';
    if (month == '??' && day == '??') return year;
    if (day == '??') return '$month.$year';
    return '$day.$month.$year';
  }
  return value;
}

@visibleForTesting
String debugLibraryDisplayGameDate(String raw) => _displayGameDate(raw);

@visibleForTesting
double get debugLibrarySavedRowExtent => _kDatabaseWorkspaceSavedRowExtent;

@visibleForTesting
double get debugLibraryTwicRowExtent => _kDatabaseWorkspaceTwicRowExtent;

@visibleForTesting
double get debugLibraryLocalRowExtent => _kLocalMiniPreviewRowExtent;

@visibleForTesting
List<LocalChessGame> debugFilterLocalMiniPreviewGames(
  List<LocalChessGame> games,
  String query,
) => _filterLocalMiniPreviewGames(games, query);

@visibleForTesting
void debugScrollLibraryListToIndex(
  ScrollController controller,
  int index,
  double rowExtent,
) {
  _scrollDatabaseWorkspaceListToIndex(controller, index, rowExtent);
}

@visibleForTesting
void debugSortLibraryAnalysesForTest(
  List<SavedAnalysis> rows, {
  required String key,
  required bool ascending,
}) {
  final sortKey = switch (key) {
    'number' => _SortKey.number,
    'white' => _SortKey.white,
    'eloW' => _SortKey.whiteElo,
    'result' => _SortKey.result,
    'black' => _SortKey.black,
    'eloB' => _SortKey.blackElo,
    'event' => _SortKey.event,
    'eco' => _SortKey.eco,
    'date' => _SortKey.date,
    'saved' => _SortKey.saved,
    _ => throw ArgumentError.value(key, 'key', 'Unknown library sort key'),
  };
  _sortAnalyses(
    rows,
    _SortConfig(sortKey, ascending ? _SortDir.asc : _SortDir.desc),
  );
}

String _relativeTime(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  if (d.inDays < 30) return '${d.inDays ~/ 7}w ago';
  if (d.inDays < 365) return '${d.inDays ~/ 30}mo ago';
  return '${d.inDays ~/ 365}y ago';
}

String _short(String n) {
  final t = n.trim();
  if (t.isEmpty) return '—';
  if (t.contains(',')) return t.split(',').first.trim();
  final parts = t.split(RegExp(r'\s+'));
  return parts.length == 1 ? parts.first : parts.last;
}

const String _kLocalPreviewTreeStartingFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

void _openLocalPreviewTree(
  WidgetRef ref, {
  required String title,
  required String sourceLabel,
  required PlayerOpeningTreeIndex index,
}) {
  if (!index.isUsable) return;
  final tabId = openBoardGameTab(
    ref,
    BoardTabGameArgs(
      pgn: '',
      label: title,
      whiteName: '',
      blackName: '',
      fenSeed: _kLocalPreviewTreeStartingFen,
      initialFen: _kLocalPreviewTreeStartingFen,
      databaseTitle: sourceLabel,
      localOpeningTreeIndex: index,
      localOpeningTreeTitle: sourceLabel,
      enableLocalOpeningTreePicker: true,
    ),
    reuseExisting: false,
  );
  ref.read(rightRailActivePageProvider(tabId).notifier).state = 1;
}

void _openLocalPreviewGame(
  WidgetRef ref,
  LocalChessGame localGame, {
  required String databaseTitle,
  required List<LocalChessGame> databaseGames,
  PlayerOpeningTreeIndex? localOpeningTreeIndex,
  String? initialFen,
  bool focus = true,
}) {
  final pgn = localGame.rawPgn.trim();
  if (pgn.isEmpty) return;
  openBoardGameTab(
    ref,
    _boardArgsForLocalPreviewGame(
      localGame,
      databaseTitle: databaseTitle,
      databaseGames: databaseGames,
      localOpeningTreeIndex: localOpeningTreeIndex,
      initialFen: initialFen,
    ),
    reuseExisting: false,
    focus: focus,
  );
}

BoardTabGameArgs _boardArgsForLocalPreviewGame(
  LocalChessGame localGame, {
  required String databaseTitle,
  required List<LocalChessGame> databaseGames,
  PlayerOpeningTreeIndex? localOpeningTreeIndex,
  String? initialFen,
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
    initialFen: initialFen,
    databaseTitle: databaseTitle,
    databaseGames: [
      for (final game in _localPreviewBoardContextGames(
        localGame,
        databaseGames,
      ))
        _summaryFromLocalPreviewGame(game),
    ],
    localOpeningTreeIndex: localOpeningTreeIndex,
    localOpeningTreeTitle: databaseTitle,
    enableLocalOpeningTreePicker: true,
    gameListSelectedId: localGame.id,
    librarySaveOrigin: BoardTabLibrarySaveOrigin.localPgnFile(
      sourcePath: localGame.sourcePath,
      sourceIndex: localGame.indexInFile,
      sourceFileGameCount: localGame.fileGameCount,
      sourcePgnFingerprint: localGame.pgnFingerprint,
      title: localGame.title,
    ),
  );
}

const int _kLocalPreviewBoardContextRadius = 30;

List<LocalChessGame> _localPreviewBoardContextGames(
  LocalChessGame selected,
  List<LocalChessGame> databaseGames,
) {
  if (databaseGames.isEmpty) return <LocalChessGame>[selected];

  final selectedIndex = databaseGames.indexWhere(
    (game) => game.id == selected.id,
  );
  if (selectedIndex < 0) return <LocalChessGame>[selected];

  final start =
      selectedIndex - _kLocalPreviewBoardContextRadius < 0
          ? 0
          : selectedIndex - _kLocalPreviewBoardContextRadius;
  final end =
      selectedIndex + _kLocalPreviewBoardContextRadius + 1 >
              databaseGames.length
          ? databaseGames.length
          : selectedIndex + _kLocalPreviewBoardContextRadius + 1;
  return databaseGames.sublist(start, end);
}

TournamentGameSummary _summaryFromLocalPreviewGame(LocalChessGame localGame) {
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
    localPgnSource: TournamentGameLocalPgnSource(
      sourcePath: localGame.sourcePath,
      sourceIndex: localGame.indexInFile,
      sourceFileGameCount: localGame.fileGameCount,
      pgnFingerprint: localGame.pgnFingerprint,
      title: localGame.title,
    ),
  );
}

void _openAnalysis(
  WidgetRef ref,
  SavedAnalysis analysis, {
  bool focus = true,
  String databaseTitle = '',
  List<SavedAnalysis> databaseAnalyses = const <SavedAnalysis>[],
  String? initialFen,
}) {
  final pgn = exportGameToPgn(analysis.chessGame).trim();
  if (pgn.isEmpty) return;
  openBoardGameTab(
    ref,
    _boardArgsForAnalysis(
      analysis,
      pgn: pgn,
      databaseTitle: databaseTitle,
      databaseAnalyses: databaseAnalyses,
      initialFen: initialFen,
    ),
    reuseExisting: false,
    focus: focus,
  );
}

Future<void> _openAnalysisWindow(
  WidgetRef ref,
  SavedAnalysis analysis, {
  String databaseTitle = '',
  List<SavedAnalysis> databaseAnalyses = const <SavedAnalysis>[],
  String? initialFen,
}) async {
  final pgn = exportGameToPgn(analysis.chessGame).trim();
  if (pgn.isEmpty) return;
  await openBoardGameWindow(
    ref,
    _boardArgsForAnalysis(
      analysis,
      pgn: pgn,
      databaseTitle: databaseTitle,
      databaseAnalyses: databaseAnalyses,
      initialFen: initialFen,
    ),
  );
}

BoardTabGameArgs _boardArgsForAnalysis(
  SavedAnalysis analysis, {
  required String pgn,
  String databaseTitle = '',
  List<SavedAnalysis> databaseAnalyses = const <SavedAnalysis>[],
  String? initialFen,
}) {
  final game = analysis.chessGame;
  final md = game.metadata;
  String s(String key) => (md[key]?.toString() ?? '').trim();
  int rating(String key) => int.tryParse(s(key)) ?? 0;
  int? fideId(String key) {
    final value = rating(key);
    return value > 0 ? value : null;
  }

  final whiteName =
      s('White').isNotEmpty ? s('White') : (analysis.whiteName ?? '');
  final blackName =
      s('Black').isNotEmpty ? s('Black') : (analysis.blackName ?? '');
  final fallbackTitle =
      whiteName.isEmpty && blackName.isEmpty
          ? analysis.title
          : '${whiteName.isEmpty ? 'White' : whiteName} vs '
              '${blackName.isEmpty ? 'Black' : blackName}';
  return BoardTabGameArgs(
    pgn: pgn,
    label: analysis.title.isEmpty ? fallbackTitle : analysis.title,
    whiteName: whiteName,
    blackName: blackName,
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
    initialFen: initialFen,
    databaseTitle: databaseTitle,
    databaseGames: _summariesFromAnalyses(
      databaseAnalyses.isEmpty ? <SavedAnalysis>[analysis] : databaseAnalyses,
    ),
    gameListSelectedId: analysis.id,
    librarySaveOrigin: BoardTabLibrarySaveOrigin.cloudSavedAnalysis(
      analysisId: analysis.id,
      title: analysis.title.isEmpty ? fallbackTitle : analysis.title,
    ),
  );
}

List<TournamentGameSummary> _summariesFromAnalyses(
  List<SavedAnalysis> analyses,
) {
  return [for (final analysis in analyses) _summaryFromAnalysis(analysis)];
}

TournamentGameSummary _summaryFromAnalysis(SavedAnalysis analysis) {
  final game = analysis.chessGame;
  final md = game.metadata;
  String s(String key) => (md[key]?.toString() ?? '').trim();
  int rating(String key) => int.tryParse(s(key)) ?? 0;
  int? fideId(String key) {
    final value = rating(key);
    return value > 0 ? value : null;
  }

  final whiteName =
      s('White').isNotEmpty ? s('White') : (analysis.whiteName ?? '');
  final blackName =
      s('Black').isNotEmpty ? s('Black') : (analysis.blackName ?? '');
  final fallbackTitle =
      whiteName.isEmpty && blackName.isEmpty
          ? 'Game ${analysis.id}'
          : '${whiteName.isEmpty ? 'White' : whiteName} vs '
              '${blackName.isEmpty ? 'Black' : blackName}';
  final pgn = exportGameToPgn(game).trim();
  final lastFen =
      game.mainline.isNotEmpty ? game.mainline.last.fen : game.startingFen;
  return TournamentGameSummary(
    id: analysis.id,
    name: analysis.title.isEmpty ? fallbackTitle : analysis.title,
    whitePlayer: whiteName,
    blackPlayer: blackName,
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
    openingName: analysis.openingName ?? s('Opening'),
    startsAt: analysis.updatedAt,
    hasStarted: game.mainline.isNotEmpty,
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

// =====================================================================
// Folder action handlers (rename / new sub / export / delete / drop)
// =====================================================================

Future<void> _onGameAction({
  required BuildContext context,
  required WidgetRef ref,
  required SavedAnalysis analysis,
  required LibraryGameAction action,
  required VoidCallback onChanged,
}) async {
  switch (action) {
    case LibraryGameAction.open:
      _openAnalysis(ref, analysis);
    case LibraryGameAction.openInNewTab:
      _openAnalysis(ref, analysis, focus: false);
    case LibraryGameAction.openInNewWindow:
      await _openAnalysisWindow(ref, analysis);
    case LibraryGameAction.share:
      await showSavedAnalysisShareDialog(context: context, analysis: analysis);
    case LibraryGameAction.copyShareLink:
      await copyDesktopShareUrl(
        context,
        buildSavedAnalysisShareUrl(analysis),
        copiedLabel: 'Game link copied to clipboard',
        missingLabel: 'This saved game has no source share link.',
      );
    case LibraryGameAction.copyPgn:
      await _onCopyPgn(context: context, analysis: analysis);
    case LibraryGameAction.selectAll:
    case LibraryGameAction.pasteGames:
      // These are handled by the folder list, where the complete visible
      // selection and shared Ctrl/Cmd+V import callback are available.
      return;
    case LibraryGameAction.copyFen:
      await _onCopyFen(context: context, analysis: analysis);
    case LibraryGameAction.exportPgn:
      await _onExportSingle(context: context, analysis: analysis);
    case LibraryGameAction.delete:
      await _onDeleteGame(
        context: context,
        ref: ref,
        analysis: analysis,
        onChanged: onChanged,
      );
  }
}

Future<void> _onCopyPgn({
  required BuildContext context,
  required SavedAnalysis analysis,
}) async {
  final pgn = exportGameToPgn(analysis.chessGame).trim();
  if (pgn.isEmpty) {
    if (!context.mounted) return;
    _toast(context, 'Nothing to copy — the game has no moves.', error: true);
    return;
  }
  await Clipboard.setData(ClipboardData(text: pgn));
  if (!context.mounted) return;
  _toast(context, 'Copied PGN to clipboard.');
}

Future<void> _onCopyFen({
  required BuildContext context,
  required SavedAnalysis analysis,
}) async {
  // Without entering the board view, the most useful position is the one
  // after the last played move (the "current" position from the player's
  // perspective). Falls back to the starting FEN for empty studies.
  final mainline = analysis.chessGame.mainline;
  final fen =
      mainline.isEmpty ? analysis.chessGame.startingFen : mainline.last.fen;
  await Clipboard.setData(ClipboardData(text: fen));
  if (!context.mounted) return;
  final label = mainline.isEmpty ? 'starting FEN' : 'final-position FEN';
  _toast(context, 'Copied $label to clipboard.');
}

Future<void> _onExportSingle({
  required BuildContext context,
  required SavedAnalysis analysis,
}) async {
  final result = await exportSingleAnalysisToDisk(analysis: analysis);
  if (!context.mounted) return;
  if (result.error != null) {
    _toast(context, 'Export failed: ${result.error}', error: true);
    return;
  }
  if (result.cancelled) return;
  if (!result.didWrite) {
    _toast(context, 'Nothing to export — this game has no moves.');
    return;
  }
  _toast(context, 'Exported "${analysis.title}" as PGN.');
}

Future<void> _onDeleteGame({
  required BuildContext context,
  required WidgetRef ref,
  required SavedAnalysis analysis,
  required VoidCallback onChanged,
}) async {
  final confirmed = await showLibraryDeleteAnalysisConfirmation(
    context,
    analysis: analysis,
  );
  if (!confirmed) return;
  try {
    await ref.read(libraryRepositoryProvider).deleteSavedAnalysis(analysis.id);
    onChanged();
    if (!context.mounted) return;
    _toast(context, 'Game "${analysis.title}" deleted.');
  } catch (e, st) {
    ErrorReporter.report(e, stackTrace: st, tag: 'library.delete_game');
    if (!context.mounted) return;
    _toast(context, 'Failed to delete game. Please try again.', error: true);
  }
}

Future<void> _onCreateFolder({
  required BuildContext context,
  required WidgetRef ref,
  required List<LibraryFolder> folders,
  LibraryFolder? lockedParent,
  LibraryFolderCreateKind kind = LibraryFolderCreateKind.folder,
  bool allowKindSelection = false,
}) async {
  final writableRoots = folders
      .where(
        (f) => !f.isSubscribed && f.parentId == null && f.id != kTwicBookId,
      )
      .toList(growable: false);
  final draft = await showLibraryCreateFolderDialog(
    context,
    availableParents: writableRoots,
    lockedParent: lockedParent,
    kind: kind,
    allowKindSelection: allowKindSelection,
  );
  if (draft == null) return;
  try {
    await ref
        .read(libraryRepositoryProvider)
        .createFolder(
          name: draft.name,
          parentId: draft.parentId,
          icon:
              draft.kind == LibraryFolderCreateKind.database
                  ? 'database'
                  : 'folder_container',
        );
    ref.invalidate(libraryFoldersStreamProvider);
    ref.invalidate(subscribedBooksProvider);
    if (!context.mounted) return;
    final noun =
        draft.kind == LibraryFolderCreateKind.database ? 'Database' : 'Folder';
    _toast(context, '$noun "${draft.name}" created');
  } catch (e, st) {
    ErrorReporter.report(e, stackTrace: st, tag: 'library.create_folder');
    if (!context.mounted) return;
    _toast(context, 'Failed to create folder. Please try again.', error: true);
  }
}

Future<void> _showFolderOnLibraryHome({
  required BuildContext context,
  required WidgetRef ref,
  required LibraryFolder folder,
}) async {
  if (folder.id == kTwicBookId) return;
  final focus = ref.read(myDatabasesFocusProvider);
  final isHidden = focus.hiddenCloudFolderIds.contains(folder.id);
  if (!isHidden) {
    _toast(context, '"${folder.name}" is already shown on Library Home.');
    return;
  }
  try {
    await ref
        .read(myDatabasesFocusProvider.notifier)
        .showCloudFolder(folder.id);
    if (!context.mounted) return;
    _toast(context, 'Showing "${folder.name}" on Library Home.');
  } catch (error, stackTrace) {
    ErrorReporter.report(
      error,
      stackTrace: stackTrace,
      tag: 'library.show_on_home',
    );
    if (!context.mounted) return;
    _toast(
      context,
      'Could not show "${folder.name}" on Library Home.',
      error: true,
    );
  }
}

Future<void> _removeFolderFromLibraryHome({
  required BuildContext context,
  required WidgetRef ref,
  required LibraryFolder folder,
}) async {
  if (!libraryCanRemoveCloudFolderFromBoard(folder)) return;
  try {
    await ref
        .read(myDatabasesFocusProvider.notifier)
        .hideCloudFolder(folder.id);
    if (!context.mounted) return;
    _toast(
      context,
      'Removed "${folder.name}" from Library Home. Cloud data was not deleted.',
    );
  } catch (error, stackTrace) {
    ErrorReporter.report(
      error,
      stackTrace: stackTrace,
      tag: 'library.remove_from_home',
    );
    if (!context.mounted) return;
    _toast(
      context,
      'Could not remove "${folder.name}" from Library Home.',
      error: true,
    );
  }
}

Future<void> _onFolderAction({
  required BuildContext context,
  required WidgetRef ref,
  required LibraryFolder folder,
  required LibraryFolderAction action,
  required List<LibraryFolder> allFolders,
}) async {
  switch (action) {
    case LibraryFolderAction.showOnLibraryHome:
      await _showFolderOnLibraryHome(
        context: context,
        ref: ref,
        folder: folder,
      );
    case LibraryFolderAction.removeFromLibraryHome:
      await _removeFolderFromLibraryHome(
        context: context,
        ref: ref,
        folder: folder,
      );
    case LibraryFolderAction.exportPgn:
      await _onExport(
        context: context,
        ref: ref,
        folder: folder,
        allFolders: allFolders,
      );
    case LibraryFolderAction.rename:
      await _onRename(context: context, ref: ref, folder: folder);
    case LibraryFolderAction.newDatabase:
      await _onCreateFolder(
        context: context,
        ref: ref,
        folders: allFolders,
        lockedParent: folder,
        kind: LibraryFolderCreateKind.database,
      );
    case LibraryFolderAction.delete:
      await _onDelete(context: context, ref: ref, folder: folder);
  }
}

Future<void> _onRename({
  required BuildContext context,
  required WidgetRef ref,
  required LibraryFolder folder,
}) async {
  if (folder.isPermanentLibraryFolder) {
    _toast(context, '"${folder.name}" is part of the default library.');
    return;
  }
  final next = await showLibraryRenameFolderDialog(context, folder: folder);
  if (next == null) return;
  try {
    await ref
        .read(libraryRepositoryProvider)
        .updateFolder(folder.copyWith(name: next, updatedAt: DateTime.now()));
    ref.invalidate(libraryFoldersStreamProvider);
    if (!context.mounted) return;
    _toast(context, 'Renamed to "$next"');
  } catch (e, st) {
    ErrorReporter.report(e, stackTrace: st, tag: 'library.rename_folder');
    if (!context.mounted) return;
    _toast(context, 'Failed to rename folder. Please try again.', error: true);
  }
}

Future<void> _onDelete({
  required BuildContext context,
  required WidgetRef ref,
  required LibraryFolder folder,
}) async {
  if (folder.isPermanentLibraryFolder) {
    _toast(context, '"${folder.name}" cannot be deleted.', error: true);
    return;
  }
  final confirmed = await showLibraryDeleteFolderConfirmation(
    context,
    folder: folder,
  );
  if (!confirmed) return;
  try {
    await ref.read(libraryRepositoryProvider).deleteFolder(folder.id);
    ref.invalidate(libraryFoldersStreamProvider);
    ref.invalidate(subscribedBooksProvider);
    if (!context.mounted) return;
    _toast(context, 'Folder "${folder.name}" deleted from Cloud');
  } catch (e, st) {
    ErrorReporter.report(e, stackTrace: st, tag: 'library.delete_folder');
    if (!context.mounted) return;
    _toast(context, 'Failed to delete folder. Please try again.', error: true);
  }
}

Future<void> _onExport({
  required BuildContext context,
  required WidgetRef ref,
  required LibraryFolder folder,
  required List<LibraryFolder> allFolders,
}) async {
  final repo = ref.read(libraryRepositoryProvider);
  final children = allFolders
      .where((f) => f.parentId == folder.id)
      .toList(growable: false);
  final progress = ValueNotifier<_ExportProgress>(
    const _ExportProgress(processed: 0, total: 0, done: false),
  );

  final dialogFuture = showDesktopDialog<void>(
    context,
    barrierDismissible: false,
    builder:
        (_) =>
            _ExportProgressDialog(progress: progress, folderName: folder.name),
  );

  late LibraryExportResult result;
  try {
    result = await exportFolderToDisk(
      repo: repo,
      folder: folder,
      childFolders: children,
      onProgress:
          (processed, total) =>
              progress.value = _ExportProgress(
                processed: processed,
                total: total,
                done: false,
              ),
    );
  } catch (e, st) {
    ErrorReporter.report(e, stackTrace: st, tag: 'library.export_folder');
    result = LibraryExportResult(cancelled: false, error: e);
  } finally {
    progress.value = progress.value.copyWith(done: true);
  }
  await dialogFuture;
  if (!context.mounted) return;

  if (result.error != null) {
    _toast(context, 'Export failed. Please try again.', error: true);
    return;
  }
  if (result.cancelled) return;
  if (!result.didWrite) {
    _toast(context, 'Nothing to export — this folder has no games.');
    return;
  }
  final fileWord = result.writtenFiles.length == 1 ? 'file' : 'files';
  _toast(
    context,
    'Exported ${result.totalGames} '
    '${result.totalGames == 1 ? 'game' : 'games'} to '
    '${result.writtenFiles.length} $fileWord.',
  );
}

void _toast(BuildContext context, String message, {bool error = false}) {
  showDesktopToast(context, message, error: error);
}

// =====================================================================
// Helpers
// =====================================================================

class _LibraryEmpty extends StatelessWidget {
  const _LibraryEmpty({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: kBlack2Color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: kPrimaryColor.withValues(alpha: 0.25),
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 26, color: kPrimaryColor),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kLightGreyColor,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExportProgress {
  const _ExportProgress({
    required this.processed,
    required this.total,
    required this.done,
  });
  final int processed;
  final int total;
  final bool done;

  double? get fraction {
    if (total <= 0) return null;
    return (processed / total).clamp(0.0, 1.0);
  }

  _ExportProgress copyWith({int? processed, int? total, bool? done}) =>
      _ExportProgress(
        processed: processed ?? this.processed,
        total: total ?? this.total,
        done: done ?? this.done,
      );
}

class _ExportProgressDialog extends StatefulWidget {
  const _ExportProgressDialog({
    required this.progress,
    required this.folderName,
  });

  final ValueNotifier<_ExportProgress> progress;
  final String folderName;

  @override
  State<_ExportProgressDialog> createState() => _ExportProgressDialogState();
}

class _ExportProgressDialogState extends State<_ExportProgressDialog> {
  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.progress.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    final p = widget.progress.value;
    if (p.done) {
      Navigator.of(context, rootNavigator: true).maybePop();
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.progress.value;
    final text =
        p.total > 0
            ? 'Exporting ${p.processed} / ${p.total} games…'
            : 'Preparing export…';
    return FTheme(
      data: FThemes.zinc.dark,
      child: Center(
        child: Container(
          width: 360,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kDividerColor),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Exporting "${widget.folderName}"',
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: p.fraction,
                  minHeight: 6,
                  color: kPrimaryColor,
                  backgroundColor: kWhiteColor.withValues(alpha: 0.06),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                text,
                style: const TextStyle(color: kLightGreyColor, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// TWIC content view — shares chrome with personal folders
// =====================================================================

/// Right-pane content view for the TWIC system database. Reuses the same
/// [_FolderHeader] and view-mode toggle as personal folders so the layout
/// stays consistent; the differences are: (1) data comes from the gamebase
/// search providers instead of saved analyses, (2) toolbar surfaces a
/// Filter button instead of Export, (3) when the user types a query or
/// applies filters, an event-aggregate chip strip appears so they can
/// drill into a single tournament.
class _TwicContentView extends HookConsumerWidget {
  const _TwicContentView({
    required this.onNewFolder,
    required this.onOpenLocalFiles,
    required this.onOpenEditor,
    required this.onOpenExplorer,
  });

  final VoidCallback onNewFolder;
  final VoidCallback onOpenLocalFiles;
  final VoidCallback onOpenEditor;
  final VoidCallback onOpenExplorer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searchController = useTextEditingController();
    final scrollController = useScrollController();
    final chipScrollController = useScrollController();
    final viewMode = useState(_GamesViewMode.list);
    final debounce = useRef<Timer?>(null);

    final paginationState = ref.watch(gamebaseDatabaseGamesPaginatedProvider);
    final eventState = ref.watch(twicEventAggregatesPaginatedProvider);
    final selectedEvent = ref.watch(twicSelectedEventProvider);
    final filterCount = ref.watch(activeGamebaseFilterCountProvider);
    final hasUserInput = ref.watch(hasUserInputProvider);
    final searchQuery = ref.watch(librarySearchQueryProvider).trim();
    final rootTotalAsync = ref.watch(twicDatabaseTotalGamesProvider);

    // Pagination on bottom of the games list.
    useEffect(() {
      void onScroll() {
        final pos = scrollController.position;
        if (pos.pixels >= pos.maxScrollExtent - 240) {
          final s = ref.read(gamebaseDatabaseGamesPaginatedProvider);
          if (!s.isLoading && s.hasMore) {
            ref
                .read(gamebaseDatabaseGamesPaginatedProvider.notifier)
                .loadNextPage();
          }
        }
      }

      scrollController.addListener(onScroll);
      return () => scrollController.removeListener(onScroll);
    }, [scrollController]);

    // Pagination on right edge of chip strip.
    useEffect(() {
      void onChipScroll() {
        if (!chipScrollController.hasClients) return;
        final pos = chipScrollController.position;
        if (pos.pixels >= pos.maxScrollExtent - 200) {
          final s = ref.read(twicEventAggregatesPaginatedProvider);
          if (!s.isLoading && s.hasMore) {
            ref
                .read(twicEventAggregatesPaginatedProvider.notifier)
                .loadNextPage();
          }
        }
      }

      chipScrollController.addListener(onChipScroll);
      return () => chipScrollController.removeListener(onChipScroll);
    }, [chipScrollController]);

    useEffect(() {
      return () => debounce.value?.cancel();
    }, const []);

    void onSearchChanged(String value) {
      debounce.value?.cancel();
      debounce.value = Timer(const Duration(milliseconds: 280), () {
        ref.read(twicSelectedEventProvider.notifier).state = null;
        ref.read(librarySearchQueryProvider.notifier).state = value.trim();
      });
    }

    Future<void> openFilters() async {
      final next = await showTwicFilterDialog(
        context: context,
        currentFilter: ref.read(gamebaseFilterProvider),
      );
      if (next != null) {
        ref.read(twicSelectedEventProvider.notifier).state = null;
        ref.read(gamebaseFilterProvider.notifier).state = next;
      }
    }

    final isDefaultView =
        searchQuery.isEmpty &&
        filterCount == 0 &&
        (selectedEvent == null || selectedEvent.trim().isEmpty);
    final int? totalCount;
    final bool isEstimate;
    if (isDefaultView) {
      final exactTotal = rootTotalAsync.valueOrNull;
      totalCount = (exactTotal != null && exactTotal > 0) ? exactTotal : null;
      isEstimate = false;
    } else {
      totalCount =
          paginationState.totalCount > 0 ? paginationState.totalCount : null;
      isEstimate = paginationState.totalCountIsEstimate;
    }

    final selectedAggregate =
        selectedEvent == null
            ? null
            : eventState.events.firstWhereOrNull(
              (a) => a.event == selectedEvent,
            );

    final isInitialLoading =
        paginationState.isLoading && paginationState.games.isEmpty;
    final subtitle =
        totalCount == null
            ? (isInitialLoading
                ? 'Loading games…'
                : 'Searchable ChessEver archive')
            : '${isEstimate ? '~' : ''}${formatCompactCount(totalCount)} games';

    return Container(
      color: kBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FolderHeader(
            folder: kTwicFolder,
            count: totalCount,
            isLoading: isInitialLoading,
            isDatabase: true,
            canCreateSubfolder: false,
            hasGames: paginationState.games.isNotEmpty,
            onAction: null,
            onNewFolder: onNewFolder,
            onOpenLocalFiles: onOpenLocalFiles,
            onOpenEditor: onOpenEditor,
            onOpenExplorer: onOpenExplorer,
            showOverflow: false,
            iconOverride: Icons.public_rounded,
            subtitleOverride: subtitle,
            badge: const _SystemDatabaseBadge(),
          ),
          _TwicContentToolbar(
            controller: searchController,
            viewMode: viewMode.value,
            onViewModeChanged: (m) => viewMode.value = m,
            filterCount: filterCount,
            onSearchChanged: onSearchChanged,
            onSearchClear: () {
              debounce.value?.cancel();
              ref.read(twicSelectedEventProvider.notifier).state = null;
              ref.read(librarySearchQueryProvider.notifier).state = '';
            },
            onOpenFilters: openFilters,
            onClearFilters:
                filterCount == 0
                    ? null
                    : () {
                      ref.read(twicSelectedEventProvider.notifier).state = null;
                      ref.read(gamebaseFilterProvider.notifier).state =
                          GamebaseFilter();
                    },
          ),
          if (hasUserInput && eventState.events.isNotEmpty) ...[
            const FDivider(),
            _TwicEventChips(
              controller: chipScrollController,
              events: eventState.events,
              selectedEvent: selectedEvent,
              isLoadingMore:
                  eventState.isLoading && eventState.events.isNotEmpty,
              onSelect: (event) {
                final current = ref.read(twicSelectedEventProvider);
                ref.read(twicSelectedEventProvider.notifier).state =
                    (event == null || current == event) ? null : event;
              },
            ),
          ] else if (hasUserInput && eventState.isLoading) ...[
            const FDivider(),
            const _TwicChipsSkeleton(),
          ],
          if (selectedAggregate != null) ...[
            const FDivider(),
            _TwicSelectedEventBar(
              aggregate: selectedAggregate,
              onClear:
                  () =>
                      ref.read(twicSelectedEventProvider.notifier).state = null,
            ),
          ],
          const FDivider(),
          Expanded(
            child: _TwicGamesBody(
              state: paginationState,
              viewMode: viewMode.value,
              scrollController: scrollController,
              isInitialLoading: isInitialLoading,
              onTapGame: (game) => _openTwicGame(ref, game),
              onContextMenuGame:
                  (game, position) => unawaited(
                    _showTwicGameContextMenu(
                      context: context,
                      ref: ref,
                      position: position,
                      game: game,
                    ),
                  ),
            ),
          ),
        ],
      ),
    );
  }

  void _openTwicGame(
    WidgetRef ref,
    GamesTourModel game, {
    bool focus = true,
    bool reuseExisting = false,
    bool replaceActive = false,
  }) {
    openBoardGameTab(
      ref,
      _buildTwicBoardArgs(ref, game),
      focus: focus,
      reuseExisting: reuseExisting,
      replaceActive: replaceActive,
    );
  }
}

BoardTabGameArgs _buildTwicBoardArgs(
  WidgetRef ref,
  GamesTourModel game, {
  String? initialFen,
}) {
  final summaries = _twicBoardContextGames(
    game,
    ref.read(gamebaseDatabaseGamesPaginatedProvider).games,
  ).map(TournamentGameSummary.fromGamesTourModel).toList(growable: false);
  return BoardTabGameArgs(
    gameId: game.gameId,
    pgn: game.pgn ?? '',
    label: '${game.whitePlayer.name} vs ${game.blackPlayer.name}',
    whiteName: game.whitePlayer.name,
    blackName: game.blackPlayer.name,
    whiteFederation: game.whitePlayer.federation,
    blackFederation: game.blackPlayer.federation,
    whiteTitle: game.whitePlayer.title,
    blackTitle: game.blackPlayer.title,
    whiteRating: game.whitePlayer.rating,
    blackRating: game.blackPlayer.rating,
    whiteFideId: game.whitePlayer.fideId,
    blackFideId: game.blackPlayer.fideId,
    fenSeed: game.fen,
    initialFen: initialFen,
    sourceGame: game,
    databaseTitle: 'ChessEver',
    databaseGames: summaries,
    databaseGamesContinuation: const BoardTabGamesContinuation.twicDatabase(),
    gameListSelectedId: game.gameId,
  );
}

const int _kTwicBoardContextRadius = 30;

List<GamesTourModel> _twicBoardContextGames(
  GamesTourModel selected,
  List<GamesTourModel> games,
) {
  if (games.isEmpty) return <GamesTourModel>[selected];

  final selectedIndex = games.indexWhere(
    (game) => game.gameId == selected.gameId,
  );
  if (selectedIndex < 0) return <GamesTourModel>[selected];

  final start =
      selectedIndex - _kTwicBoardContextRadius < 0
          ? 0
          : selectedIndex - _kTwicBoardContextRadius;
  final end =
      selectedIndex + _kTwicBoardContextRadius + 1 > games.length
          ? games.length
          : selectedIndex + _kTwicBoardContextRadius + 1;
  return games.sublist(start, end);
}

enum _TwicGameContextAction {
  open,
  openNewTab,
  openNewWindow,
  openBackground,
  saveToLibrary,
  share,
  copyShareLink,
  whiteProfile,
  blackProfile,
  copyGameId,
}

Future<void> _showTwicGameContextMenu({
  required BuildContext context,
  required WidgetRef ref,
  required Offset position,
  required GamesTourModel game,
}) async {
  final shareUrl = buildDesktopGameShareUrl(game: game);
  final canSaveToLibrary = canSaveDesktopGameToLibrary(game);
  final picked = await showDesktopContextMenu<_TwicGameContextAction>(
    context: context,
    position: position,
    width: 248,
    entries: [
      const DesktopContextMenuItem(
        value: _TwicGameContextAction.open,
        icon: Icons.open_in_new_rounded,
        label: 'Open game',
      ),
      const DesktopContextMenuItem(
        value: _TwicGameContextAction.openNewTab,
        icon: Icons.add_to_photos_outlined,
        label: 'Open in new tab',
      ),
      const DesktopContextMenuItem(
        value: _TwicGameContextAction.openNewWindow,
        icon: Icons.open_in_new_rounded,
        label: 'Open in new window',
      ),
      const DesktopContextMenuItem(
        value: _TwicGameContextAction.openBackground,
        icon: Icons.tab_unselected_rounded,
        label: 'Open in background',
      ),
      if (canSaveToLibrary) ...[
        const DesktopContextMenuDivider(),
        const DesktopContextMenuItem(
          value: _TwicGameContextAction.saveToLibrary,
          icon: Icons.library_add_outlined,
          label: 'Save to library',
        ),
      ],
      const DesktopContextMenuDivider(),
      const DesktopContextMenuItem(
        value: _TwicGameContextAction.share,
        icon: Icons.share_rounded,
        label: 'Share Game',
      ),
      DesktopContextMenuItem(
        value: _TwicGameContextAction.copyShareLink,
        icon: Icons.copy_rounded,
        label: 'Copy share link',
        enabled: shareUrl != null,
      ),
      const DesktopContextMenuDivider(),
      const DesktopContextMenuItem(
        value: _TwicGameContextAction.whiteProfile,
        icon: Icons.person_outline_rounded,
        label: 'Open White profile',
      ),
      const DesktopContextMenuItem(
        value: _TwicGameContextAction.blackProfile,
        icon: Icons.person_2_outlined,
        label: 'Open Black profile',
      ),
      const DesktopContextMenuDivider(),
      const DesktopContextMenuItem(
        value: _TwicGameContextAction.copyGameId,
        icon: Icons.tag_rounded,
        label: 'Copy game ID',
      ),
    ],
  );
  if (picked == null || !context.mounted) return;

  switch (picked) {
    case _TwicGameContextAction.open:
      openBoardGameTab(
        ref,
        _buildTwicBoardArgs(ref, game),
        focus: true,
        reuseExisting: true,
        replaceActive: true,
      );
    case _TwicGameContextAction.openNewTab:
      openBoardGameTab(
        ref,
        _buildTwicBoardArgs(ref, game),
        focus: true,
        reuseExisting: false,
        replaceActive: false,
      );
    case _TwicGameContextAction.openNewWindow:
      await openBoardGameWindow(ref, _buildTwicBoardArgs(ref, game));
    case _TwicGameContextAction.openBackground:
      openBoardGameTab(
        ref,
        _buildTwicBoardArgs(ref, game),
        focus: false,
        reuseExisting: false,
        replaceActive: false,
      );
    case _TwicGameContextAction.saveToLibrary:
      await saveDesktopGameToLibrary(
        context: context,
        ref: ref,
        game: game,
        sourceLabel: 'ChessEver',
      );
    case _TwicGameContextAction.share:
      await showDesktopGameShareDialog(context: context, ref: ref, game: game);
    case _TwicGameContextAction.copyShareLink:
      await copyDesktopShareUrl(
        context,
        shareUrl,
        copiedLabel: 'Game link copied to clipboard',
        missingLabel: 'This game has no shareable link yet.',
      );
    case _TwicGameContextAction.whiteProfile:
      _openTwicPlayerProfile(ref, game.whitePlayer);
    case _TwicGameContextAction.blackProfile:
      _openTwicPlayerProfile(ref, game.blackPlayer);
    case _TwicGameContextAction.copyGameId:
      await Clipboard.setData(ClipboardData(text: game.gameId));
  }
}

void _openTwicPlayerProfile(WidgetRef ref, PlayerCard player) {
  final name = player.name.trim();
  if (name.isEmpty) return;
  openPlayerProfile(
    ref,
    PlayerProfileArgs(
      playerName: name,
      fideId: player.fideId,
      title: player.title.trim().isEmpty ? null : player.title.trim(),
      federation:
          player.federation.trim().isNotEmpty
              ? player.federation.trim()
              : (player.countryCode.trim().isEmpty
                  ? null
                  : player.countryCode.trim()),
      rating: player.rating > 0 ? player.rating : null,
      gamebasePlayerId: player.gamebasePlayerId,
    ),
  );
}

class _SystemDatabaseBadge extends StatelessWidget {
  const _SystemDatabaseBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: kPrimaryColor.withValues(alpha: 0.40)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline_rounded, size: 9, color: kPrimaryColor),
          SizedBox(width: 4),
          Text(
            'System',
            style: TextStyle(
              color: kPrimaryColor,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.25,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Mirror of [_ContentToolbar] for TWIC: search field + view mode toggle on
/// the left/center, Filters button (with active-count badge) on the right
/// in place of Export. Visually identical chrome — same paddings, same
/// `_ViewModeToggle`, same `DesktopSearchField` so users see one library.
class _TwicContentToolbar extends StatelessWidget {
  const _TwicContentToolbar({
    required this.controller,
    required this.viewMode,
    required this.onViewModeChanged,
    required this.filterCount,
    required this.onSearchChanged,
    required this.onSearchClear,
    required this.onOpenFilters,
    required this.onClearFilters,
  });

  final TextEditingController controller;
  final _GamesViewMode viewMode;
  final ValueChanged<_GamesViewMode> onViewModeChanged;
  final int filterCount;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchClear;
  final VoidCallback onOpenFilters;
  final VoidCallback? onClearFilters;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBackgroundColor,
        border: Border(
          bottom: BorderSide(color: kDividerColor.withValues(alpha: 0.75)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: DesktopSearchField(
                controller: controller,
                hintText: 'Search players, events, openings…',
                onChanged: onSearchChanged,
                onClear: onSearchClear,
              ),
            ),
            const SizedBox(width: 8),
            _ViewModeToggle(value: viewMode, onChanged: onViewModeChanged),
            const SizedBox(width: 8),
            DesktopTooltip(
              message:
                  filterCount == 0
                      ? 'Filter games'
                      : '$filterCount filter${filterCount == 1 ? '' : 's'} active',
              child: FButton(
                style:
                    filterCount == 0
                        ? FButtonStyle.outline()
                        : FButtonStyle.primary(),
                onPress: onOpenFilters,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.tune_rounded, size: 12),
                    const SizedBox(width: 5),
                    const Text('Filters', style: TextStyle(fontSize: 12)),
                    if (filterCount > 0) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: kBlackColor.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '$filterCount',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (onClearFilters != null) ...[
              const SizedBox(width: 6),
              DesktopTooltip(
                message: 'Clear filters',
                child: FButton(
                  style: FButtonStyle.ghost(),
                  onPress: onClearFilters,
                  child: const Icon(Icons.close_rounded, size: 13),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TwicEventChips extends StatelessWidget {
  const _TwicEventChips({
    required this.controller,
    required this.events,
    required this.selectedEvent,
    required this.isLoadingMore,
    required this.onSelect,
  });

  final ScrollController controller;
  final List<TwicEventAggregate> events;
  final String? selectedEvent;
  final bool isLoadingMore;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final itemCount = events.length + 1 + (isLoadingMore ? 1 : 0);
    return SizedBox(
      height: 52,
      child: ListView.separated(
        controller: controller,
        scrollDirection: Axis.horizontal,
        physics: const DesktopScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        itemCount: itemCount,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _TwicChip(
              label: 'All events',
              isSelected: selectedEvent == null,
              onTap: () => onSelect(null),
            );
          }
          if (index > events.length) {
            return const SizedBox(
              width: 28,
              child: Center(
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                  ),
                ),
              ),
            );
          }
          final aggregate = events[index - 1];
          return _TwicChip(
            label: aggregate.displayEvent,
            count: aggregate.gameCount,
            isSelected: selectedEvent == aggregate.event,
            onTap: () => onSelect(aggregate.event),
          );
        },
      ),
    );
  }
}

class _TwicChipsSkeleton extends StatelessWidget {
  const _TwicChipsSkeleton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        itemCount: 6,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder:
            (_, i) => Container(
              width: i == 0 ? 80 : 140 + (i * 14),
              decoration: BoxDecoration(
                color: kBlack3Color,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
      ),
    );
  }
}

class _TwicChip extends StatefulWidget {
  const _TwicChip({
    required this.label,
    this.count,
    required this.isSelected,
    required this.onTap,
  });
  final String label;
  final int? count;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<_TwicChip> createState() => _TwicChipState();
}

class _TwicChipState extends State<_TwicChip>
    with DeferredPointerStateMixin<_TwicChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final fg =
        widget.isSelected
            ? kPrimaryColor
            : (_hovered ? kWhiteColor : kWhiteColor70);
    final bg =
        widget.isSelected
            ? kPrimaryColor.withValues(alpha: 0.14)
            : (_hovered ? kBlack3Color : kBlack2Color);
    final border =
        widget.isSelected
            ? kPrimaryColor.withValues(alpha: 0.6)
            : kDividerColor;
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
        onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (widget.count != null && widget.count! > 0) ...[
                  const SizedBox(width: 6),
                  Text(
                    formatCompactCount(widget.count!),
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.65),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TwicSelectedEventBar extends StatelessWidget {
  const _TwicSelectedEventBar({required this.aggregate, required this.onClear});

  final TwicEventAggregate aggregate;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final dateStr = TimeUtils.formatDateRange(
      aggregate.startDate,
      aggregate.endDate,
    );
    final infoParts = <Widget>[];
    if (aggregate.site != null && aggregate.site!.trim().isNotEmpty) {
      infoParts.add(
        _TwicInfoChip(
          icon: Icons.location_on_rounded,
          label: aggregate.site!.trim(),
        ),
      );
    }
    if (dateStr.isNotEmpty) {
      infoParts.add(_TwicInfoChip(icon: Icons.event_outlined, label: dateStr));
    }
    if (aggregate.avgElo != null) {
      infoParts.add(
        _TwicInfoChip(
          icon: Icons.equalizer_rounded,
          label: 'Avg ${aggregate.avgElo}',
        ),
      );
    }
    if (aggregate.maxElo != null) {
      infoParts.add(
        _TwicInfoChip(
          icon: Icons.star_rounded,
          label: 'Top ${aggregate.maxElo}',
        ),
      );
    }
    if (aggregate.gameCount > 0) {
      infoParts.add(
        _TwicInfoChip(
          icon: Icons.style_outlined,
          label: '${formatCompactCount(aggregate.gameCount)} games',
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
      decoration: const BoxDecoration(
        color: kBlack2Color,
        border: Border(left: BorderSide(color: kPrimaryColor, width: 2.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  aggregate.displayEvent,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.1,
                  ),
                ),
                if (infoParts.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 4, children: infoParts),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          DesktopTooltip(
            message: 'Clear event filter',
            child: FButton(
              style: FButtonStyle.ghost(),
              onPress: onClear,
              child: const Icon(Icons.close_rounded, size: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _TwicInfoChip extends StatelessWidget {
  const _TwicInfoChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: kLightGreyColor),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// TWIC equivalent of [_GamesBody]. Switches between table / compact /
/// list / grid the same way personal folders do, but renders
/// [GamesTourModel] rows instead of [SavedAnalysis] (TWIC games come from
/// the gamebase API, not the user's library).
class _TwicGamesBody extends StatelessWidget {
  const _TwicGamesBody({
    required this.state,
    required this.viewMode,
    required this.scrollController,
    required this.isInitialLoading,
    required this.onTapGame,
    required this.onContextMenuGame,
  });

  final DatabaseGamesPaginationState state;
  final _GamesViewMode viewMode;
  final ScrollController scrollController;
  final bool isInitialLoading;
  final ValueChanged<GamesTourModel> onTapGame;
  final void Function(GamesTourModel game, Offset position) onContextMenuGame;

  @override
  Widget build(BuildContext context) {
    if (isInitialLoading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
          ),
        ),
      );
    }
    if (state.error != null && state.games.isEmpty) {
      return const _LibraryEmpty(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load games',
        message: 'Something went wrong loading games. Please try again.',
      );
    }
    if (state.games.isEmpty) {
      return const _LibraryEmpty(
        icon: Icons.search_off_rounded,
        title: 'No games match',
        message:
            'Try a different player, event, or opening — or clear filters.',
      );
    }

    switch (viewMode) {
      case _GamesViewMode.table:
        return _TwicGamesTable(
          state: state,
          scrollController: scrollController,
          selectedGameId: null,
          onTapGame: onTapGame,
          onContextMenuGame: onContextMenuGame,
        );
      case _GamesViewMode.grid:
        return _TwicGamesGrid(
          state: state,
          scrollController: scrollController,
          onTapGame: onTapGame,
          onContextMenuGame: onContextMenuGame,
        );
      case _GamesViewMode.compact:
        return _TwicGamesCards(
          state: state,
          scrollController: scrollController,
          layout: DesktopCardLayout.compact,
          onTapGame: onTapGame,
          onContextMenuGame: onContextMenuGame,
        );
      case _GamesViewMode.list:
        return _TwicGamesCards(
          state: state,
          scrollController: scrollController,
          layout: DesktopCardLayout.list,
          onTapGame: onTapGame,
          onContextMenuGame: onContextMenuGame,
        );
    }
  }
}

class _TwicGamesCards extends StatelessWidget {
  const _TwicGamesCards({
    required this.state,
    required this.scrollController,
    required this.layout,
    required this.onTapGame,
    required this.onContextMenuGame,
  });

  final DatabaseGamesPaginationState state;
  final ScrollController scrollController;
  final DesktopCardLayout layout;
  final ValueChanged<GamesTourModel> onTapGame;
  final void Function(GamesTourModel game, Offset position) onContextMenuGame;

  @override
  Widget build(BuildContext context) {
    final itemCount = state.games.length + (state.hasMore ? 1 : 0);
    return DesktopGameCardsFlow(
      layout: layout,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      scrollController: scrollController,
      itemCount: itemCount,
      itemBuilder: (context, i) {
        if (i >= state.games.length) {
          return const _TwicLoadingMoreRow();
        }
        final game = state.games[i];
        return DesktopGameCard(
          data: GameCardData.fromGamesTourModel(game),
          onTap: () => onTapGame(game),
          onContextMenu: (position) => onContextMenuGame(game, position),
          layout: layout,
          allowStockfishFallback: false,
        );
      },
    );
  }
}

class _TwicGamesGrid extends StatelessWidget {
  const _TwicGamesGrid({
    required this.state,
    required this.scrollController,
    required this.onTapGame,
    required this.onContextMenuGame,
  });

  final DatabaseGamesPaginationState state;
  final ScrollController scrollController;
  final ValueChanged<GamesTourModel> onTapGame;
  final void Function(GamesTourModel game, Offset position) onContextMenuGame;

  @override
  Widget build(BuildContext context) {
    final itemCount = state.games.length + (state.hasMore ? 1 : 0);
    return LayoutBuilder(
      builder: (context, constraints) {
        const targetWidth = 280.0;
        final columns = (constraints.maxWidth / targetWidth).floor().clamp(
          2,
          6,
        );
        return GridView.builder(
          controller: scrollController,
          physics: const DesktopScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          itemCount: itemCount,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.95,
          ),
          itemBuilder: (context, i) {
            if (i >= state.games.length) {
              return const _TwicLoadingMoreRow();
            }
            final game = state.games[i];
            return DesktopGameCard(
              data: GameCardData.fromGamesTourModel(game),
              onTap: () => onTapGame(game),
              onContextMenu: (position) => onContextMenuGame(game, position),
              layout: DesktopCardLayout.grid,
              allowStockfishFallback: false,
            );
          },
        );
      },
    );
  }
}

/// TWIC table view — same column shape as [_GamesTable], same
/// [_PlayerCell]/[_ResultPill] components, but the "Saved" column becomes
/// "Date" (gamebase rows have a game date, not a saved-at timestamp) and
/// header cells aren't sort-clickable: gamebase sort is server-side and
/// not exposed by the paginated provider, so client-side reordering of a
/// single page would be misleading.
class _TwicGamesTable extends StatelessWidget {
  const _TwicGamesTable({
    required this.state,
    required this.scrollController,
    required this.selectedGameId,
    this.selectedGameIds,
    required this.onTapGame,
    required this.onContextMenuGame,
    this.onOpenGame,
    this.onRangeSelect,
  });

  final DatabaseGamesPaginationState state;
  final ScrollController scrollController;
  final String? selectedGameId;
  final Set<String>? selectedGameIds;
  final ValueChanged<GamesTourModel> onTapGame;
  final ValueChanged<GamesTourModel>? onOpenGame;
  final ValueChanged<int>? onRangeSelect;
  final void Function(GamesTourModel game, Offset position) onContextMenuGame;

  @override
  Widget build(BuildContext context) {
    final itemCount = state.games.length + (state.hasMore ? 1 : 0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Container(
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kDividerColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            const _TwicTableHeader(),
            const Divider(height: 1, color: kDividerColor),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                physics: const DesktopScrollPhysics(),
                padding: EdgeInsets.zero,
                itemCount: itemCount,
                itemBuilder: (context, i) {
                  if (i >= state.games.length) {
                    return SizedBox(
                      height: _kDatabaseWorkspaceTwicRowExtent + 16,
                      child: const _TwicLoadingMoreRow(),
                    );
                  }
                  final game = state.games[i];
                  return SizedBox(
                    height: _kDatabaseWorkspaceTwicRowExtent,
                    child: _TwicTableRow(
                      game: game,
                      selected:
                          (selectedGameIds?.contains(game.gameId) ?? false) ||
                          game.gameId == selectedGameId,
                      onRangeSelect:
                          onRangeSelect == null
                              ? null
                              : () => onRangeSelect!(i),
                      onTap: () => onTapGame(game),
                      onDoubleTap: () => (onOpenGame ?? onTapGame)(game),
                      onContextMenu:
                          (position) => onContextMenuGame(game, position),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const int _kPreviewColWhite = 6;
const int _kPreviewColBlack = 6;
const int _kPreviewColEvent = 3;
const double _kPreviewColResult = 48.0;
const double _kPreviewColEco = 52.0;
const double _kPreviewColDate = 82.0;
const double _kPreviewColGap = 8.0;
const EdgeInsets _kPreviewTableCellPadding = EdgeInsets.fromLTRB(
  10,
  10,
  10,
  10,
);

class _TwicTableHeader extends StatelessWidget {
  const _TwicTableHeader();

  @override
  Widget build(BuildContext context) {
    Widget label(String text, {bool alignEnd = false}) => Text(
      text,
      style: const TextStyle(
        color: kLightGreyColor,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
      ),
      textAlign: alignEnd ? TextAlign.right : TextAlign.left,
    );
    return Container(
      padding: _kPreviewTableCellPadding,
      color: kBlack3Color.withValues(alpha: 0.4),
      child: Row(
        children: [
          Expanded(flex: _kPreviewColWhite, child: label('White')),
          const SizedBox(width: _kPreviewColGap),
          SizedBox(
            width: _kPreviewColResult,
            child: Center(child: label('Result')),
          ),
          const SizedBox(width: _kPreviewColGap),
          Expanded(flex: _kPreviewColBlack, child: label('Black')),
          const SizedBox(width: _kPreviewColGap),
          Expanded(flex: _kPreviewColEvent, child: label('Event')),
          const SizedBox(width: _kPreviewColGap),
          SizedBox(width: _kPreviewColEco, child: label('ECO')),
          const SizedBox(width: _kPreviewColGap),
          SizedBox(
            width: _kPreviewColDate,
            child: Align(
              alignment: Alignment.centerRight,
              child: label('Date', alignEnd: true),
            ),
          ),
        ],
      ),
    );
  }
}

class _TwicTableRow extends StatefulWidget {
  const _TwicTableRow({
    required this.game,
    required this.selected,
    this.onRangeSelect,
    required this.onTap,
    required this.onDoubleTap,
    required this.onContextMenu,
  });

  final GamesTourModel game;
  final bool selected;
  final VoidCallback? onRangeSelect;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final ValueChanged<Offset> onContextMenu;

  @override
  State<_TwicTableRow> createState() => _TwicTableRowState();
}

class _TwicTableRowState extends State<_TwicTableRow>
    with DeferredPointerStateMixin<_TwicTableRow> {
  bool _hovered = false;
  bool _suppressNextTap = false;

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final eco = (game.eco ?? '').trim();
    final result = game.gameStatus.displayText;
    final dateLabel = _formatTwicDate(game.lastMoveTime);

    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
        onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (event.buttons & kPrimaryMouseButton == 0) return;
            if (HardwareKeyboard.instance.isShiftPressed &&
                widget.onRangeSelect != null) {
              widget.onRangeSelect!();
              _suppressNextTap = true;
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTapDown:
                (details) => widget.onContextMenu(details.globalPosition),
            onDoubleTap: widget.onDoubleTap,
            onTap: () {
              if (_suppressNextTap) {
                _suppressNextTap = false;
                return;
              }
              if (isNewTabModifierPressed()) {
                widget.onTap();
                return;
              }
              widget.onTap();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              decoration: librarySelectedRowDecoration(
                selected: widget.selected,
                hovered: _hovered,
              ),
              padding: _kPreviewTableCellPadding,
              child: Row(
                children: [
                  Expanded(
                    flex: _kPreviewColWhite,
                    child: _PlayerCell(
                      name: game.whitePlayer.name,
                      federation: game.whitePlayer.federation,
                      title: game.whitePlayer.title,
                      rating:
                          game.whitePlayer.rating > 0
                              ? game.whitePlayer.rating.toString()
                              : '',
                    ),
                  ),
                  const SizedBox(width: _kPreviewColGap),
                  SizedBox(
                    width: _kPreviewColResult,
                    child: _ResultPill(result: result),
                  ),
                  const SizedBox(width: _kPreviewColGap),
                  Expanded(
                    flex: _kPreviewColBlack,
                    child: _PlayerCell(
                      name: game.blackPlayer.name,
                      federation: game.blackPlayer.federation,
                      title: game.blackPlayer.title,
                      rating:
                          game.blackPlayer.rating > 0
                              ? game.blackPlayer.rating.toString()
                              : '',
                    ),
                  ),
                  const SizedBox(width: _kPreviewColGap),
                  Expanded(
                    flex: _kPreviewColEvent,
                    child: Text(
                      game.tourId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kWhiteColor, fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: _kPreviewColGap),
                  SizedBox(
                    width: _kPreviewColEco,
                    child:
                        desktopTableDisplayValue(eco).isEmpty
                            ? const SizedBox.shrink()
                            : Container(
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: kBlack3Color,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: kDividerColor),
                              ),
                              child: Text(
                                eco,
                                style: const TextStyle(
                                  color: kWhiteColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                  ),
                  const SizedBox(width: _kPreviewColGap),
                  SizedBox(
                    width: _kPreviewColDate,
                    child: Text(
                      dateLabel,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: kLightGreyColor,
                        fontSize: 11,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TwicLoadingMoreRow extends StatelessWidget {
  const _TwicLoadingMoreRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
          ),
        ),
      ),
    );
  }
}

String _formatTwicDate(DateTime? date) {
  if (date == null) return '';
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '${date.year}-$m-$d';
}

// =====================================================================
// Opened database workspace tab
// =====================================================================

class DatabaseWorkspacePane extends HookConsumerWidget {
  const DatabaseWorkspacePane({super.key, required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = ref.watch(databaseWorkspaceArgsByTabIdProvider)[tabId];
    if (args == null) {
      return const _LibraryEmpty(
        icon: Icons.table_chart_outlined,
        title: 'Database not available',
        message: 'Open a database from the Library rail to create a workspace.',
      );
    }
    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        color: kBackgroundColor,
        child: switch (args.source) {
          DatabaseWorkspaceSource.twic => _TwicDatabaseWorkspace(tabId: tabId),
          DatabaseWorkspaceSource.folder => _FolderDatabaseWorkspace(
            tabId: tabId,
            args: args,
          ),
          DatabaseWorkspaceSource.local => _LocalDatabaseWorkspace(
            tabId: tabId,
            args: args,
          ),
        },
      ),
    );
  }
}

// Row extents below MUST match the actual rendered height of each list's row
// (including the in-row 1px bottom divider) or `_scrollDatabaseWorkspaceListToIndex`
// will compute the wrong scroll target and push the selected row off-screen on
// every keystroke. The lists below pin each row to these heights via SizedBox.
const double _kDatabaseWorkspaceSavedRowExtent = 44.0;
const double _kDatabaseWorkspaceTwicRowExtent = 44.0;
const double _kLocalMiniPreviewRowExtent = 44.0;
const int _kLocalMiniPreviewGameQueryPageSize = 1000;
const double _kLocalMiniPreviewScrollLoadMoreThreshold = 420.0;

typedef _DatabaseWorkspaceKeyAction = bool Function();

class _LocalMiniPreviewPageWindow {
  const _LocalMiniPreviewPageWindow(this.queryKey, this.pageNumber);

  final String queryKey;
  final int pageNumber;
}

class _LoadedLocalMiniPreviewPages {
  const _LoadedLocalMiniPreviewPages({
    required this.queryKey,
    required this.games,
    required this.totalCount,
    required this.nextPageNumber,
    required this.pageSize,
  });

  const _LoadedLocalMiniPreviewPages.empty()
    : queryKey = '',
      games = const <LocalChessGame>[],
      totalCount = 0,
      nextPageNumber = 0,
      pageSize = _kLocalMiniPreviewGameQueryPageSize;

  final String queryKey;
  final List<LocalChessGame> games;
  final int totalCount;
  final int nextPageNumber;
  final int pageSize;

  bool get hasRows => games.isNotEmpty;

  bool get hasMore => nextPageNumber * pageSize < totalCount;

  _LoadedLocalMiniPreviewPages merge({
    required String queryKey,
    required LocalChessGameQueryPage page,
  }) {
    if (page.pageNumber == 0 || this.queryKey != queryKey) {
      return _LoadedLocalMiniPreviewPages(
        queryKey: queryKey,
        games: List<LocalChessGame>.unmodifiable(page.games),
        totalCount: page.totalCount,
        nextPageNumber: page.pageNumber + 1,
        pageSize: page.pageSize,
      );
    }
    if (page.pageNumber < nextPageNumber) return this;
    if (page.pageNumber > nextPageNumber) {
      return _LoadedLocalMiniPreviewPages(
        queryKey: queryKey,
        games: List<LocalChessGame>.unmodifiable(page.games),
        totalCount: page.totalCount,
        nextPageNumber: page.pageNumber + 1,
        pageSize: page.pageSize,
      );
    }
    return _LoadedLocalMiniPreviewPages(
      queryKey: queryKey,
      games: List<LocalChessGame>.unmodifiable(<LocalChessGame>[
        ...games,
        ...page.games,
      ]),
      totalCount: page.totalCount,
      nextPageNumber: page.pageNumber + 1,
      pageSize: page.pageSize,
    );
  }
}

_LoadedLocalMiniPreviewPages? _visibleLocalMiniPreviewRows({
  required String queryKey,
  required _LoadedLocalMiniPreviewPages loaded,
  required LocalChessGameQueryPage? livePage,
}) {
  final hasLoadedRows = loaded.queryKey == queryKey && loaded.hasRows;
  if (livePage == null) return hasLoadedRows ? loaded : null;
  if (livePage.pageNumber == 0 || !hasLoadedRows) {
    return _LoadedLocalMiniPreviewPages(
      queryKey: queryKey,
      games: List<LocalChessGame>.unmodifiable(livePage.games),
      totalCount: livePage.totalCount,
      nextPageNumber: livePage.pageNumber + 1,
      pageSize: livePage.pageSize,
    );
  }
  if (livePage.pageNumber < loaded.nextPageNumber) return loaded;
  if (livePage.pageNumber > loaded.nextPageNumber) {
    return _LoadedLocalMiniPreviewPages(
      queryKey: queryKey,
      games: List<LocalChessGame>.unmodifiable(livePage.games),
      totalCount: livePage.totalCount,
      nextPageNumber: livePage.pageNumber + 1,
      pageSize: livePage.pageSize,
    );
  }
  return _LoadedLocalMiniPreviewPages(
    queryKey: queryKey,
    games: List<LocalChessGame>.unmodifiable(<LocalChessGame>[
      ...loaded.games,
      ...livePage.games,
    ]),
    totalCount: livePage.totalCount,
    nextPageNumber: livePage.pageNumber + 1,
    pageSize: livePage.pageSize,
  );
}

// Multi-term in-memory filter mirroring the repository's SQL search: every
// whitespace-separated term must match the file name, path, or a header value.
List<LocalChessGame> _filterLocalMiniPreviewGames(
  List<LocalChessGame> games,
  String rawQuery,
) {
  final terms = rawQuery
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toList(growable: false);
  if (terms.isEmpty) return games;
  bool matchesTerm(LocalChessGame game, String term) {
    if (game.fileName.toLowerCase().contains(term)) return true;
    if (game.sourceRelativePath.toLowerCase().contains(term)) return true;
    for (final value in game.game.metadata.values) {
      if (value is String && value.toLowerCase().contains(term)) return true;
    }
    return false;
  }

  return games
      .where((game) => terms.every((term) => matchesTerm(game, term)))
      .toList(growable: false);
}

Future<LocalChessGameQueryPage?> _queryLocalMiniPreviewPage(
  LocalChessDatabaseRepository repository, {
  required String databasePath,
  required String search,
  LocalChessGameFilter? filter,
  required int pageNumber,
  required int pageSize,
}) async {
  try {
    return await repository.localDatabaseGamesPage(
      databasePath: databasePath,
      search: search,
      sortBy: LocalChessGameSortField.originalOrder,
      sortDirection: LocalChessGameSortDirection.asc,
      filter: filter,
      pageNumber: pageNumber,
      pageSize: pageSize,
    );
  } on Object {
    return null;
  }
}

class _LibraryRangeSelection {
  const _LibraryRangeSelection({
    required this.selectedIds,
    required this.anchor,
    required this.extent,
  });

  final Set<String> selectedIds;
  final int anchor;
  final int extent;
}

_LibraryRangeSelection? _rangeSelectLibraryRows({
  required List<String> rowIds,
  required Set<String> selectedIds,
  required int? anchor,
  required int index,
}) {
  if (rowIds.isEmpty) return null;
  final extent = index.clamp(0, rowIds.length - 1).toInt();
  final resolvedAnchor = (anchor ?? extent).clamp(0, rowIds.length - 1).toInt();
  return _LibraryRangeSelection(
    selectedIds: LibraryMultiSelect.range(
      rowIds: rowIds,
      from: resolvedAnchor,
      to: extent,
    ),
    anchor: resolvedAnchor,
    extent: extent,
  );
}

bool _databaseWorkspaceListShortcutAllowed() {
  final focusedContext = primaryFocus?.context;
  if (focusedContext == null) return true;
  if (focusedContext.widget is EditableText) return false;
  return focusedContext.findAncestorWidgetOfExactType<EditableText>() == null;
}

bool _databaseWorkspaceNavigationModifierPressed() {
  final pressed = HardwareKeyboard.instance.logicalKeysPressed;
  return pressed.contains(LogicalKeyboardKey.control) ||
      pressed.contains(LogicalKeyboardKey.controlLeft) ||
      pressed.contains(LogicalKeyboardKey.controlRight) ||
      pressed.contains(LogicalKeyboardKey.meta) ||
      pressed.contains(LogicalKeyboardKey.metaLeft) ||
      pressed.contains(LogicalKeyboardKey.metaRight) ||
      pressed.contains(LogicalKeyboardKey.alt) ||
      pressed.contains(LogicalKeyboardKey.altLeft) ||
      pressed.contains(LogicalKeyboardKey.altRight);
}

KeyEventResult _handleDatabaseWorkspaceTableKey(
  KeyEvent event,
  Map<LogicalKeyboardKey, _DatabaseWorkspaceKeyAction> actions, {
  Map<LogicalKeyboardKey, _DatabaseWorkspaceKeyAction> shiftActions =
      const <LogicalKeyboardKey, _DatabaseWorkspaceKeyAction>{},
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  if (!_databaseWorkspaceListShortcutAllowed()) {
    return KeyEventResult.ignored;
  }
  if (_databaseWorkspaceNavigationModifierPressed()) {
    return KeyEventResult.ignored;
  }

  final action =
      HardwareKeyboard.instance.isShiftPressed
          ? shiftActions[event.logicalKey]
          : actions[event.logicalKey];
  if (action == null) return KeyEventResult.ignored;
  return action() ? KeyEventResult.handled : KeyEventResult.ignored;
}

void _requestDatabaseWorkspaceFocus(FocusNode focusNode) {
  if (focusNode.canRequestFocus) focusNode.requestFocus();
}

void _requestDatabaseWorkspaceFocusAfterFrame(FocusNode focusNode) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!_databaseWorkspaceListShortcutAllowed()) return;
    _requestDatabaseWorkspaceFocus(focusNode);
  });
}

Widget _databaseWorkspaceClipboardShortcuts({
  required Widget child,
  VoidCallback? onCopy,
  VoidCallback? onPaste,
}) {
  final bindings = <ShortcutActivator, VoidCallback>{};
  if (onCopy != null) {
    bindings[const SingleActivator(LogicalKeyboardKey.keyC, meta: true)] =
        onCopy;
    bindings[const SingleActivator(LogicalKeyboardKey.keyC, control: true)] =
        onCopy;
  }
  if (onPaste != null) {
    bindings[const SingleActivator(LogicalKeyboardKey.keyV, meta: true)] =
        onPaste;
    bindings[const SingleActivator(LogicalKeyboardKey.keyV, control: true)] =
        onPaste;
  }
  if (bindings.isEmpty) return child;
  return CallbackShortcuts(bindings: bindings, child: child);
}

LibraryFolder _workspaceFolderFromArgs(DatabaseWorkspaceArgs args) {
  final now = DateTime.now();
  return LibraryFolder(
    id: args.folderId,
    userId: '',
    name: args.title,
    color: '#0FB4E5',
    icon: 'database',
    orderIndex: 0,
    createdAt: now,
    updatedAt: now,
    isSubscribed: args.isSubscribed,
  );
}

List<SavedAnalysis> _selectedSavedAnalysesForCopy({
  required List<SavedAnalysis> rows,
  required Set<String> selectedIds,
  required String? selectedId,
}) {
  final selectedRows =
      rows.where((row) => selectedIds.contains(row.id)).toList();
  if (selectedRows.isNotEmpty) return selectedRows;
  final current = rows.firstWhereOrNull((row) => row.id == selectedId);
  return current == null ? const <SavedAnalysis>[] : <SavedAnalysis>[current];
}

List<GamesTourModel> _selectedTwicGamesForCopy({
  required List<GamesTourModel> games,
  required Set<String> selectedIds,
  required String? selectedId,
}) {
  final selectedRows =
      games.where((game) => selectedIds.contains(game.gameId)).toList();
  if (selectedRows.isNotEmpty) return selectedRows;
  final current = games.firstWhereOrNull((game) => game.gameId == selectedId);
  return current == null ? const <GamesTourModel>[] : <GamesTourModel>[current];
}

List<LocalChessGame> _selectedLocalGamesForCopy({
  required List<LocalChessGame> games,
  required Set<String> selectedIds,
  required int selectedIndex,
}) {
  final selectedRows =
      games.where((game) => selectedIds.contains(game.id)).toList();
  if (selectedRows.isNotEmpty) return selectedRows;
  if (games.isEmpty) return const <LocalChessGame>[];
  final index = selectedIndex.clamp(0, games.length - 1).toInt();
  return <LocalChessGame>[games[index]];
}

/// Bring row [index] into view with the minimum scroll possible. Only moves
/// the viewport when the row is currently outside it — arrow-key navigation
/// shouldn't snap the selected row to the top of the list on every step.
void _scrollDatabaseWorkspaceListToIndex(
  ScrollController controller,
  int index,
  double rowExtent,
) {
  if (!controller.hasClients) return;
  final position = controller.position;
  if (!position.hasViewportDimension) return;
  final viewport = position.viewportDimension;
  final pixels = position.pixels;
  final rowTop = index * rowExtent;
  final rowBottom = rowTop + rowExtent;

  double? target;
  if (rowTop < pixels) {
    target = rowTop;
  } else if (rowBottom > pixels + viewport) {
    target = rowBottom - viewport;
  }
  if (target == null) return;

  final clamped = target.clamp(
    position.minScrollExtent,
    position.maxScrollExtent,
  );
  if ((clamped - pixels).abs() < 0.5) return;
  controller.animateTo(
    clamped.toDouble(),
    duration: const Duration(milliseconds: 120),
    curve: Curves.easeOut,
  );
}

/// Identifies a local database source to open in a workspace. [revision] bumps
/// only when the underlying database's contents change (e.g. a player sync
/// appended games). A stable [path]+[revision] lets the kept-alive source be
/// re-served instantly on re-open, while a new revision forces one fresh reload
/// so synced games appear.
@immutable
class LocalDatabaseWorkspaceKey {
  const LocalDatabaseWorkspaceKey(this.path, {this.revision = 0});

  final String path;
  final int revision;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalDatabaseWorkspaceKey &&
          other.path == path &&
          other.revision == revision;

  @override
  int get hashCode => Object.hash(path, revision);
}

/// Loads a persisted local database source and keeps it cached for the session.
///
/// A source that was already imported and persisted loads from its warm
/// resqlite cache and is then pinned with [KeepAliveLink] so re-opening the
/// same database (Library tab, Players "Games" tab) is instant — never
/// re-showing a loading indicator. Content changes flow through the key's
/// [LocalDatabaseWorkspaceKey.revision]; explicit refresh invalidates the entry.
final localDatabaseWorkspaceSourceProvider = FutureProvider.autoDispose
    .family<LocalChessSource, LocalDatabaseWorkspaceKey>((ref, key) async {
      final path = key.path;
      final live = ref.watch(
        localChessLibraryProvider.select(
          (state) => localDatabaseWorkspaceLiveSource(state, key),
        ),
      );
      final liveSource = live.source;
      if (liveSource != null) {
        if (!live.isIndexing) ref.keepAlive();
        return liveSource;
      }
      final repository = ref.read(localChessDatabaseRepositoryProvider);
      final cached = await repository.loadFreshSource(<String>[path]);
      if (cached != null) {
        ref.keepAlive();
        return cached;
      }
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.file && looksLikeLocalChessFile(path)) {
        final imported = await repository.importSingleFileSource(path: path);
        if (imported != null) {
          ref.keepAlive();
          return imported;
        }
      }
      final paths = <String>[path];
      final source = await scanLocalChessPaths(paths, buildOpeningTree: false);
      await repository.persistSource(source);
      ref.keepAlive();
      return source;
    });

({LocalChessSource? source, bool isIndexing}) localDatabaseWorkspaceLiveSource(
  LocalChessLibraryState state,
  LocalDatabaseWorkspaceKey key,
) {
  final source =
      state.sessionSourceForPath(key.path) ??
      (state.source?.nodeForPath(key.path) == null ? null : state.source);
  final isIndexing = state.backgroundImportForPath(key.path) != null;
  if (source == null || (!isIndexing && key.revision != 0)) {
    return (source: null, isIndexing: false);
  }
  return (source: source, isIndexing: isIndexing);
}

class _LocalDatabaseWorkspace extends HookConsumerWidget {
  const _LocalDatabaseWorkspace({required this.tabId, required this.args});

  final String tabId;
  final DatabaseWorkspaceArgs args;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sourceRevision = useState(0);
    final localPath = args.localPath;
    if (localPath == null || localPath.isEmpty) {
      return const _LibraryEmpty(
        icon: Icons.table_chart_outlined,
        title: 'Local database not available',
        message: 'Open the local database again from the Library home.',
      );
    }

    final workspaceKey = LocalDatabaseWorkspaceKey(
      localPath,
      revision: sourceRevision.value,
    );
    final sourceAsync = ref.watch(
      localDatabaseWorkspaceSourceProvider(workspaceKey),
    );
    final backgroundImportProgress = ref.watch(
      localChessLibraryProvider.select(
        (state) => state.backgroundImportForPath(localPath),
      ),
    );

    Future<void> refreshLocalSource() async {
      sourceRevision.value++;
      final refreshKey = LocalDatabaseWorkspaceKey(
        localPath,
        revision: sourceRevision.value,
      );
      await ref.read(localDatabaseWorkspaceSourceProvider(refreshKey).future);
    }

    void selectPath(String path) {
      final source = sourceAsync.valueOrNull;
      final title = localDatabaseWorkspaceTitle(source, path);
      ref.read(databaseWorkspaceArgsByTabIdProvider.notifier).update((
        existing,
      ) {
        return <String, DatabaseWorkspaceArgs>{
          ...existing,
          tabId: DatabaseWorkspaceArgs.local(localPath: path, title: title),
        };
      });
      ref
          .read(desktopTabsProvider.notifier)
          .rename(tabId, title: title, subtitle: 'Local database');
    }

    return sourceAsync.when(
      loading: () => const _RailLoading(),
      error:
          (error, _) => _LibraryEmpty(
            icon: Icons.error_outline_rounded,
            title: 'Could not open local database',
            message: localChessOpenErrorMessage(error),
          ),
      data:
          (source) => LocalChessFilesView(
            selectedPath: localPath,
            onSelectPath: selectPath,
            stateOverride: LocalChessLibraryState(
              source: source,
              selectedPath: localPath,
              backgroundImports:
                  backgroundImportProgress == null
                      ? const <String, LocalChessScanProgress>{}
                      : <String, LocalChessScanProgress>{
                        localChessInputPathKey(localPath):
                            backgroundImportProgress,
                      },
            ),
            onRefreshOverride: refreshLocalSource,
            databaseWorkspaceTabId: tabId,
          ),
    );
  }
}

String localDatabaseWorkspaceTitle(LocalChessSource? source, String path) {
  final node = source?.nodeForPath(path);
  final nodeName = node?.name.trim() ?? '';
  if (nodeName.isNotEmpty) return nodeName;
  final sourceLabel = source?.label.trim() ?? '';
  if (sourceLabel.isNotEmpty) return sourceLabel;
  final basename = p.basename(path).trim();
  return basename.isNotEmpty ? basename : 'Local database';
}

String localDatabaseWorkspacePath(LocalChessSource? source, String path) {
  final node = source?.nodeForPath(path);
  if (node != null) {
    final database = selectedLocalChessDatabaseFile(node);
    if (database != null) return database.path;
  }
  return path;
}

class _FolderDatabaseWorkspace extends HookConsumerWidget {
  const _FolderDatabaseWorkspace({required this.tabId, required this.args});

  final String tabId;
  final DatabaseWorkspaceArgs args;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searchController = useTextEditingController();
    final query = useState<String>('');
    final sort = useState(const _SortConfig(_SortKey.saved, _SortDir.desc));
    final selectedId = useState<String?>(null);
    final selectedIds = useState<Set<String>>(<String>{});
    final selectionAnchor = useState<int?>(null);
    final selectionExtent = useState<int?>(null);
    final refreshNonce = useState<int>(0);
    final cloudRefreshNonce = ref.watch(cloudLibraryRefreshNonceProvider);
    final plyIndex = useState<int>(0);
    final listScrollController = useScrollController();
    final shortcutsFocusNode = useFocusNode(
      debugLabel: 'database-workspace-folder-${args.folderId}',
    );

    final analysesAsync = useFuture(
      useMemoized(
        () =>
            args.isSubscribed
                ? ref
                    .read(libraryRepositoryProvider)
                    .getSharedFolderAnalysesPaginated(
                      folderId: args.folderId,
                      limit: 400,
                    )
                : ref
                    .read(libraryRepositoryProvider)
                    .getSavedAnalyses(folderId: args.folderId),
        [
          args.folderId,
          args.isSubscribed,
          refreshNonce.value,
          cloudRefreshNonce,
        ],
      ),
    );

    final all = analysesAsync.data ?? const <SavedAnalysis>[];
    final filtered = useMemoized<List<SavedAnalysis>>(() {
      final q = query.value.trim().toLowerCase();
      final base =
          q.isEmpty
              ? List<SavedAnalysis>.of(all)
              : all.where((a) {
                if (a.title.toLowerCase().contains(q)) return true;
                for (final entry in a.chessGame.metadata.entries) {
                  final v = entry.value;
                  if (v is String && v.toLowerCase().contains(q)) return true;
                }
                return false;
              }).toList();
      _sortAnalyses(base, sort.value);
      return base;
    }, [all, query.value, sort.value]);

    useEffect(() {
      if (filtered.isEmpty) {
        selectedId.value = null;
      } else if (selectedId.value == null ||
          !filtered.any((a) => a.id == selectedId.value)) {
        selectedId.value = filtered.first.id;
      }
      return null;
    }, [filtered]);

    useEffect(() {
      _requestDatabaseWorkspaceFocusAfterFrame(shortcutsFocusNode);
      return null;
    }, [args.folderId]);

    final selected = filtered.firstWhereOrNull((a) => a.id == selectedId.value);

    final selectedPlyCount = selected?.chessGame.mainline.length ?? 0;
    final visibleIds = filtered.map((row) => row.id).toList(growable: false);
    final clampedSelectedIds = LibraryMultiSelect.clampToRows(
      selectedIds.value,
      visibleIds,
    );

    // Previews open from the natural starting position. Left/right then
    // behaves like normal game playback: right advances from move zero.
    useEffect(() {
      plyIndex.value = 0;
      return null;
    }, [selectedId.value, selectedPlyCount]);

    bool setSelectedPly(int next) {
      final current = selected;
      final clamped = _clampLibraryPreviewPly(current?.chessGame, next);
      if (clamped == plyIndex.value) return true;
      plyIndex.value = clamped;
      _playLibraryPreviewSfxForPly(ref, current?.chessGame, clamped);
      _requestDatabaseWorkspaceFocus(shortcutsFocusNode);
      return true;
    }

    bool selectSavedIndex(int index) {
      if (filtered.isEmpty) return false;
      final nextIndex = index.clamp(0, filtered.length - 1).toInt();
      selectedId.value = filtered[nextIndex].id;
      selectionAnchor.value = nextIndex;
      selectionExtent.value = nextIndex;
      if (selectedIds.value.isNotEmpty) {
        selectedIds.value = <String>{};
      }
      _requestDatabaseWorkspaceFocus(shortcutsFocusNode);
      _scrollDatabaseWorkspaceListToIndex(
        listScrollController,
        nextIndex,
        _kDatabaseWorkspaceSavedRowExtent,
      );
      return true;
    }

    bool rangeSelectSavedIndex(int index) {
      final next = _rangeSelectLibraryRows(
        rowIds: visibleIds,
        selectedIds: selectedIds.value,
        anchor: selectionAnchor.value,
        index: index,
      );
      if (next == null) return false;
      selectedIds.value = next.selectedIds;
      selectionAnchor.value = next.anchor;
      selectionExtent.value = next.extent;
      selectedId.value = visibleIds[next.extent];
      _requestDatabaseWorkspaceFocus(shortcutsFocusNode);
      _scrollDatabaseWorkspaceListToIndex(
        listScrollController,
        next.extent,
        _kDatabaseWorkspaceSavedRowExtent,
      );
      return true;
    }

    bool extendSavedSelection(int delta) {
      final next = LibraryMultiSelect.nextExtent(
        rowIds: visibleIds,
        extent: selectionExtent.value ?? selectionAnchor.value,
        delta: delta,
      );
      return next == null ? false : rangeSelectSavedIndex(next);
    }

    bool moveSavedSelection(int delta) {
      if (filtered.isEmpty) return false;
      final currentIndex = filtered.indexWhere((a) => a.id == selectedId.value);
      return selectSavedIndex((currentIndex < 0 ? 0 : currentIndex) + delta);
    }

    bool stepSelectedPly(int delta) {
      final current = selected;
      if (current == null) return false;
      return setSelectedPly(plyIndex.value + delta);
    }

    void openSelected(SavedAnalysis analysis) {
      _openAnalysis(
        ref,
        analysis,
        databaseTitle: args.title,
        databaseAnalyses: all,
        initialFen:
            analysis.id == selected?.id
                ? _initialFenForPreviewPly(analysis.chessGame, plyIndex.value)
                : null,
      );
    }

    void copySelectedSaved() {
      final copyRows = _selectedSavedAnalysesForCopy(
        rows: filtered,
        selectedIds: clampedSelectedIds,
        selectedId: selectedId.value,
      );
      unawaited(copySavedAnalysesAsPgn(context: context, analyses: copyRows));
    }

    void pasteIntoWorkspaceFolder([
      ActiveDatabaseWorkspacePasteOwnership? ownership,
    ]) {
      final effectiveOwnership =
          ownership ??
          captureActiveDatabaseWorkspacePasteOwnership(ref: ref, tabId: tabId);
      if (effectiveOwnership == null) return;
      if (args.isSubscribed) {
        showDesktopToast(context, '"${args.title}" is read-only.', error: true);
        return;
      }
      unawaited(
        quickImportClipboardToFolder(
          context: context,
          ref: ref,
          folder: _workspaceFolderFromArgs(args),
          isCurrentOwner: () => effectiveOwnership.isCurrent,
        ).then((count) {
          if (count > 0) refreshNonce.value++;
        }),
      );
    }

    useActiveDatabaseWorkspacePasteDispatcher(
      context: context,
      ref: ref,
      tabId: tabId,
      onPaste: (ownership) => pasteIntoWorkspaceFolder(ownership),
    );

    return _databaseWorkspaceClipboardShortcuts(
      onCopy: copySelectedSaved,
      onPaste: args.isSubscribed ? null : pasteIntoWorkspaceFolder,
      child: Focus(
        focusNode: shortcutsFocusNode,
        canRequestFocus: true,
        onKeyEvent:
            (_, event) => _handleDatabaseWorkspaceTableKey(
              event,
              {
                LogicalKeyboardKey.arrowDown: () => moveSavedSelection(1),
                LogicalKeyboardKey.arrowUp: () => moveSavedSelection(-1),
                LogicalKeyboardKey.arrowLeft: () => stepSelectedPly(-1),
                LogicalKeyboardKey.arrowRight: () => stepSelectedPly(1),
                LogicalKeyboardKey.home: () => selectSavedIndex(0),
                LogicalKeyboardKey.end:
                    () => selectSavedIndex(filtered.length - 1),
                LogicalKeyboardKey.enter: () {
                  if (selected == null) return false;
                  openSelected(selected);
                  return true;
                },
                LogicalKeyboardKey.numpadEnter: () {
                  if (selected == null) return false;
                  openSelected(selected);
                  return true;
                },
              },
              shiftActions: {
                LogicalKeyboardKey.arrowUp: () => extendSavedSelection(-1),
                LogicalKeyboardKey.arrowDown: () => extendSavedSelection(1),
                LogicalKeyboardKey.arrowLeft: () => setSelectedPly(0),
                LogicalKeyboardKey.arrowRight:
                    () => setSelectedPly(selectedPlyCount),
              },
            ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DatabaseWorkspaceHeader(
              title: args.title,
              subtitle: '${all.length} ${all.length == 1 ? 'game' : 'games'}',
              badge: args.isSubscribed ? 'Subscribed database' : 'My database',
            ),
            const FDivider(),
            _DatabaseWorkspaceToolbar(
              controller: searchController,
              hintText: 'Search this database — players, events, openings, ECO',
              onSearchChanged: (v) => query.value = v,
              onSearchClear: () => query.value = '',
            ),
            const FDivider(),
            Expanded(
              child:
                  analysesAsync.connectionState != ConnectionState.done
                      ? const Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                          ),
                        ),
                      )
                      : filtered.isEmpty
                      ? _LibraryEmpty(
                        icon: Icons.search_off_rounded,
                        title:
                            query.value.trim().isEmpty
                                ? 'This database is empty'
                                : 'No games match "${query.value}"',
                        message: 'Try another term or clear the search.',
                      )
                      : _DatabaseSavedGamesTable(
                        rows: filtered,
                        sort: sort.value,
                        selectedId: selectedId.value,
                        selectedIds: clampedSelectedIds,
                        scrollController: listScrollController,
                        onSortChange: (next) => sort.value = next,
                        onRangeSelect: rangeSelectSavedIndex,
                        onSelect: (analysis) {
                          final index = filtered.indexWhere(
                            (row) => row.id == analysis.id,
                          );
                          if (index >= 0) selectSavedIndex(index);
                        },
                        onOpen: openSelected,
                      ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TwicDatabaseWorkspace extends HookConsumerWidget {
  const _TwicDatabaseWorkspace({required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searchController = useTextEditingController();
    final debounce = useRef<Timer?>(null);
    final scrollController = useScrollController();
    final selectedId = useState<String?>(null);
    final selectedIds = useState<Set<String>>(<String>{});
    final selectionAnchor = useState<int?>(null);
    final selectionExtent = useState<int?>(null);
    final plyIndex = useState<int>(0);
    final shortcutsFocusNode = useFocusNode(
      debugLabel: 'database-workspace-twic',
    );
    final searchQuery = useState<String>('');
    final filter = useState<GamebaseFilter>(GamebaseFilter());

    final gamesQuery = _TwicWorkspaceGamesQuery(
      searchQuery: searchQuery.value.trim(),
      filter: filter.value,
    );
    final paginationState = ref.watch(_twicWorkspaceGamesProvider(gamesQuery));
    final filterCount = filter.value.activeFilterCount;
    final rootTotalAsync = ref.watch(twicDatabaseTotalGamesProvider);

    useActiveDatabaseWorkspacePasteDispatcher(
      context: context,
      ref: ref,
      tabId: tabId,
      onPaste:
          (_) =>
              showDesktopToast(context, 'ChessEver is read-only.', error: true),
    );

    useEffect(() {
      return () => debounce.value?.cancel();
    }, const []);

    useEffect(() {
      void onScroll() {
        final pos = scrollController.position;
        if (pos.pixels >= pos.maxScrollExtent - 240) {
          final s = ref.read(_twicWorkspaceGamesProvider(gamesQuery));
          if (!s.isLoading && s.hasMore) {
            ref
                .read(_twicWorkspaceGamesProvider(gamesQuery).notifier)
                .loadNextPage();
          }
        }
      }

      scrollController.addListener(onScroll);
      return () => scrollController.removeListener(onScroll);
    }, [scrollController, gamesQuery]);

    final games = paginationState.games;
    useEffect(() {
      if (games.isEmpty) {
        selectedId.value = null;
      } else if (selectedId.value == null ||
          !games.any((g) => g.gameId == selectedId.value)) {
        selectedId.value = games.first.gameId;
      }
      return null;
    }, [games]);

    useEffect(() {
      _requestDatabaseWorkspaceFocusAfterFrame(shortcutsFocusNode);
      return null;
    }, const []);

    void onSearchChanged(String value) {
      debounce.value?.cancel();
      debounce.value = Timer(const Duration(milliseconds: 280), () {
        searchQuery.value = value.trim();
      });
    }

    Future<void> openFilters() async {
      final next = await showTwicFilterDialog(
        context: context,
        currentFilter: filter.value,
      );
      if (next != null) {
        filter.value = next;
      }
    }

    final selected = games.firstWhereOrNull(
      (g) => g.gameId == selectedId.value,
    );
    final selectedPreview = _watchTwicPreviewGame(ref, selected);
    final selectedPreviewGame = selectedPreview.game;
    final selectedPlyCount = selectedPreviewGame?.mainline.length ?? 0;
    final visibleIds = games.map((game) => game.gameId).toList(growable: false);
    final clampedSelectedIds = LibraryMultiSelect.clampToRows(
      selectedIds.value,
      visibleIds,
    );

    useEffect(() {
      plyIndex.value = 0;
      return null;
    }, [selectedId.value, selectedPlyCount]);

    bool setSelectedTwicPly(int next) {
      final clamped = _clampLibraryPreviewPly(selectedPreviewGame, next);
      if (clamped == plyIndex.value) return true;
      plyIndex.value = clamped;
      _playLibraryPreviewSfxForPly(ref, selectedPreviewGame, clamped);
      _requestDatabaseWorkspaceFocus(shortcutsFocusNode);
      return true;
    }

    bool selectTwicIndex(int index) {
      if (games.isEmpty) return false;
      final nextIndex = index.clamp(0, games.length - 1).toInt();
      selectedId.value = games[nextIndex].gameId;
      selectionAnchor.value = nextIndex;
      selectionExtent.value = nextIndex;
      if (selectedIds.value.isNotEmpty) {
        selectedIds.value = <String>{};
      }
      _requestDatabaseWorkspaceFocus(shortcutsFocusNode);
      _scrollDatabaseWorkspaceListToIndex(
        scrollController,
        nextIndex,
        _kDatabaseWorkspaceTwicRowExtent,
      );
      return true;
    }

    bool rangeSelectTwicIndex(int index) {
      final next = _rangeSelectLibraryRows(
        rowIds: visibleIds,
        selectedIds: selectedIds.value,
        anchor: selectionAnchor.value,
        index: index,
      );
      if (next == null) return false;
      selectedIds.value = next.selectedIds;
      selectionAnchor.value = next.anchor;
      selectionExtent.value = next.extent;
      selectedId.value = visibleIds[next.extent];
      _requestDatabaseWorkspaceFocus(shortcutsFocusNode);
      _scrollDatabaseWorkspaceListToIndex(
        scrollController,
        next.extent,
        _kDatabaseWorkspaceTwicRowExtent,
      );
      return true;
    }

    bool extendTwicSelection(int delta) {
      final next = LibraryMultiSelect.nextExtent(
        rowIds: visibleIds,
        extent: selectionExtent.value ?? selectionAnchor.value,
        delta: delta,
      );
      return next == null ? false : rangeSelectTwicIndex(next);
    }

    bool moveTwicSelection(int delta) {
      if (games.isEmpty) return false;
      final currentIndex = games.indexWhere(
        (g) => g.gameId == selectedId.value,
      );
      return selectTwicIndex((currentIndex < 0 ? 0 : currentIndex) + delta);
    }

    bool stepSelectedTwicPly(int delta) {
      final current = selected;
      if (current == null) return false;
      return setSelectedTwicPly(plyIndex.value + delta);
    }

    bool openSelectedTwic() {
      final current = selected;
      if (current == null) return false;
      openBoardGameTab(
        ref,
        _buildTwicBoardArgs(
          ref,
          current,
          initialFen: _initialFenForPreviewPly(
            selectedPreviewGame,
            plyIndex.value,
          ),
        ),
      );
      return true;
    }

    final totalCount = rootTotalAsync.valueOrNull;
    final subtitle =
        totalCount == null
            ? (paginationState.isLoading && games.isEmpty
                ? 'Loading games…'
                : 'System database')
            : '${formatCompactCount(totalCount)} games';

    void copySelectedTwic() {
      final copyGames = _selectedTwicGamesForCopy(
        games: games,
        selectedIds: clampedSelectedIds,
        selectedId: selectedId.value,
      );
      unawaited(
        copyDesktopGamesAsResolvedPgn(
          context: context,
          ref: ref,
          games: copyGames,
        ),
      );
    }

    return _databaseWorkspaceClipboardShortcuts(
      onCopy: copySelectedTwic,
      child: Focus(
        focusNode: shortcutsFocusNode,
        canRequestFocus: true,
        onKeyEvent:
            (_, event) => _handleDatabaseWorkspaceTableKey(
              event,
              {
                LogicalKeyboardKey.arrowDown: () => moveTwicSelection(1),
                LogicalKeyboardKey.arrowUp: () => moveTwicSelection(-1),
                LogicalKeyboardKey.arrowLeft: () => stepSelectedTwicPly(-1),
                LogicalKeyboardKey.arrowRight: () => stepSelectedTwicPly(1),
                LogicalKeyboardKey.home: () => selectTwicIndex(0),
                LogicalKeyboardKey.end: () => selectTwicIndex(games.length - 1),
                LogicalKeyboardKey.enter: openSelectedTwic,
                LogicalKeyboardKey.numpadEnter: openSelectedTwic,
              },
              shiftActions: {
                LogicalKeyboardKey.arrowUp: () => extendTwicSelection(-1),
                LogicalKeyboardKey.arrowDown: () => extendTwicSelection(1),
                LogicalKeyboardKey.arrowLeft: () => setSelectedTwicPly(0),
                LogicalKeyboardKey.arrowRight:
                    () => setSelectedTwicPly(selectedPlyCount),
              },
            ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DatabaseWorkspaceHeader(
              title: 'ChessEver',
              subtitle: subtitle,
              badge: 'System database',
            ),
            const FDivider(),
            _DatabaseWorkspaceToolbar(
              controller: searchController,
              hintText: 'Search this database — players, events, openings…',
              onSearchChanged: onSearchChanged,
              onSearchClear: () {
                debounce.value?.cancel();
                searchQuery.value = '';
              },
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DesktopTooltip(
                    message:
                        filterCount == 0
                            ? 'Filter this database'
                            : '$filterCount filter${filterCount == 1 ? '' : 's'} active',
                    child: FButton(
                      style:
                          filterCount == 0
                              ? FButtonStyle.outline()
                              : FButtonStyle.primary(),
                      onPress: openFilters,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.tune_rounded, size: 13),
                          SizedBox(width: 6),
                          Text('Filters'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const FDivider(),
            Expanded(
              child: _TwicGamesTable(
                state: paginationState,
                scrollController: scrollController,
                selectedGameId: selectedId.value,
                selectedGameIds: clampedSelectedIds,
                onRangeSelect: rangeSelectTwicIndex,
                onTapGame: (game) {
                  final index = games.indexWhere(
                    (row) => row.gameId == game.gameId,
                  );
                  if (index >= 0) selectTwicIndex(index);
                },
                onOpenGame:
                    (game) =>
                        openBoardGameTab(ref, _buildTwicBoardArgs(ref, game)),
                onContextMenuGame:
                    (game, position) => unawaited(
                      _showTwicGameContextMenu(
                        context: context,
                        ref: ref,
                        position: position,
                        game: game,
                      ),
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DatabaseWorkspaceHeader extends StatelessWidget {
  const _DatabaseWorkspaceHeader({
    required this.title,
    required this.subtitle,
    required this.badge,
  });

  final String title;
  final String subtitle;
  final String badge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 18, 14),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kPrimaryColor.withValues(alpha: 0.35)),
            ),
            child: const Icon(
              Icons.table_chart_outlined,
              color: kPrimaryColor,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
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
                      child: Text(
                        badge,
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(color: kLightGreyColor, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DatabaseWorkspaceToolbar extends StatelessWidget {
  const _DatabaseWorkspaceToolbar({
    required this.controller,
    required this.hintText,
    required this.onSearchChanged,
    required this.onSearchClear,
    this.trailing,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchClear;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 18, 10),
      child: Row(
        children: [
          Expanded(
            child: DesktopSearchField(
              controller: controller,
              hintText: hintText,
              onChanged: onSearchChanged,
              onClear: onSearchClear,
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
  }
}

/// Shared row decoration for every desktop library database table
/// (`_GamesTableRow`, `_DatabaseSavedGameRow`, `_TwicTableRow`).
///
/// A selected row gets a 3px [kPrimaryColor] left accent bar plus a tint;
/// unselected/hover rows carry the same-width transparent left border so the
/// row content never shifts horizontally when selection moves. This is the
/// visible "selected row" indicator for the library page tables.
// librarySelectedRowDecoration now lives in library_table_row_style.dart and is
// re-exported above so existing call-sites and tests keep resolving it here.

class _DatabaseSavedGamesTable extends HookWidget {
  const _DatabaseSavedGamesTable({
    required this.rows,
    required this.sort,
    required this.selectedId,
    this.selectedIds,
    required this.scrollController,
    required this.onSortChange,
    required this.onSelect,
    required this.onOpen,
    this.onRangeSelect,
  });

  final List<SavedAnalysis> rows;
  final _SortConfig sort;
  final String? selectedId;
  final Set<String>? selectedIds;
  final ScrollController scrollController;
  final ValueChanged<_SortConfig> onSortChange;
  final ValueChanged<SavedAnalysis> onSelect;
  final ValueChanged<SavedAnalysis> onOpen;
  final ValueChanged<int>? onRangeSelect;

  @override
  Widget build(BuildContext context) {
    final columnFlexes = useState(const _GamesTableColumnFlexes());
    final columnOrder = useState(_defaultGamesTableColumns);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 10, 20),
      child: Container(
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kDividerColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            _GamesTableHeader(
              sort: sort,
              onSortChange: onSortChange,
              columnFlexes: columnFlexes.value,
              columnOrder: columnOrder.value,
              onColumnFlexesChanged: (next) => columnFlexes.value = next,
              onColumnOrderChanged: (next) => columnOrder.value = next,
            ),
            const Divider(height: 1, color: kDividerColor),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                physics: const DesktopScrollPhysics(),
                padding: EdgeInsets.zero,
                itemExtent: _kDatabaseWorkspaceSavedRowExtent,
                itemCount: rows.length,
                itemBuilder:
                    (context, i) => _DatabaseSavedGameRow(
                      index: i + 1,
                      analysis: rows[i],
                      selected:
                          (selectedIds?.contains(rows[i].id) ?? false) ||
                          rows[i].id == selectedId,
                      columnFlexes: columnFlexes.value,
                      columnOrder: columnOrder.value,
                      onRangeSelect:
                          onRangeSelect == null
                              ? null
                              : () => onRangeSelect!(i),
                      onSelect: () => onSelect(rows[i]),
                      onOpen: () => onOpen(rows[i]),
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DatabaseSavedGameRow extends StatefulWidget {
  const _DatabaseSavedGameRow({
    required this.index,
    required this.analysis,
    required this.selected,
    this.columnFlexes = const _GamesTableColumnFlexes(),
    this.columnOrder = _defaultGamesTableColumns,
    this.onRangeSelect,
    required this.onSelect,
    required this.onOpen,
  });

  final int index;
  final SavedAnalysis analysis;
  final bool selected;
  final _GamesTableColumnFlexes columnFlexes;
  final List<_GamesTableColumn> columnOrder;
  final VoidCallback? onRangeSelect;
  final VoidCallback onSelect;
  final VoidCallback onOpen;

  @override
  State<_DatabaseSavedGameRow> createState() => _DatabaseSavedGameRowState();
}

class _DatabaseSavedGameRowState extends State<_DatabaseSavedGameRow>
    with DeferredPointerStateMixin<_DatabaseSavedGameRow> {
  bool _hovered = false;
  bool _suppressNextTap = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.analysis;
    final meta = a.chessGame.metadata;
    String s(String key) => (meta[key]?.toString() ?? '').trim();

    final whiteName = s('White').isNotEmpty ? s('White') : (a.whiteName ?? '');
    final blackName = s('Black').isNotEmpty ? s('Black') : (a.blackName ?? '');
    final whiteFed =
        s('WhiteFederation').isNotEmpty ? s('WhiteFederation') : s('WhiteFed');
    final blackFed =
        s('BlackFederation').isNotEmpty ? s('BlackFederation') : s('BlackFed');
    int? fideId(String key) {
      final value = int.tryParse(s(key)) ?? 0;
      return value > 0 ? value : null;
    }

    final whiteTitle = s('WhiteTitle');
    final blackTitle = s('BlackTitle');
    final whiteRating = s('WhiteElo');
    final blackRating = s('BlackElo');
    final whiteFideId = fideId('WhiteFideId');
    final blackFideId = fideId('BlackFideId');
    final event = desktopTableDisplayValue(s('Event'));
    final round = desktopTableDisplayValue(s('Round'));
    final eco = s('ECO');
    final result = s('Result');
    final saved = _formatSavedDate(a.updatedAt);
    final eventLine =
        round.isNotEmpty && round != '?'
            ? (event.isEmpty ? 'Round $round' : '$event · R$round')
            : event;

    Widget cell(_GamesTableColumn column) {
      return SizedBox(
        width: widget.columnFlexes.widthFor(column),
        child: switch (column) {
          _GamesTableColumn.number => Text(
            widget.index.toString(),
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          _GamesTableColumn.white => _PlayerCell(
            name: whiteName,
            federation: whiteFed,
            fideId: whiteFideId,
            title: whiteTitle,
          ),
          _GamesTableColumn.whiteElo => _RatingCell(rating: whiteRating),
          _GamesTableColumn.result => _ResultPill(result: result),
          _GamesTableColumn.black => _PlayerCell(
            name: blackName,
            federation: blackFed,
            fideId: blackFideId,
            title: blackTitle,
          ),
          _GamesTableColumn.blackElo => _RatingCell(rating: blackRating),
          _GamesTableColumn.event => Text(
            eventLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: kWhiteColor70, fontSize: 12),
          ),
          _GamesTableColumn.eco => _EcoCell(eco: eco),
          _GamesTableColumn.date => Text(
            _displayGameDate(s('Date')),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          _GamesTableColumn.saved => Text(
            saved,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        },
      );
    }

    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
        onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (event.buttons & kPrimaryMouseButton == 0) return;
            if (HardwareKeyboard.instance.isShiftPressed &&
                widget.onRangeSelect != null) {
              widget.onRangeSelect!();
              _suppressNextTap = true;
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_suppressNextTap) {
                _suppressNextTap = false;
                return;
              }
              widget.onSelect();
            },
            onDoubleTap: widget.onOpen,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              decoration: librarySelectedRowDecoration(
                selected: widget.selected,
                hovered: _hovered,
              ),
              padding: const EdgeInsets.fromLTRB(8, 10, 14, 10),
              child: Row(
                children: [
                  for (final column in widget.columnOrder) ...[
                    cell(column),
                    const SizedBox(width: 10),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

ChessGame _previewChessGameFromLocalGame(LocalChessGame localGame) {
  final parsed = _previewChessGameFromPgn(
    id: localGame.id,
    pgn: localGame.rawPgn,
    fallbackFen: localGame.game.startingFen,
    metadata: localGame.game.metadata,
  );
  return parsed ?? localGame.game;
}

ChessGame? _previewChessGameFromTourGame(GamesTourModel game) {
  return _previewChessGameFromPgn(
    id: game.gameId,
    pgn: game.pgn,
    fallbackFen: game.fen,
    metadata: {
      'White': game.whitePlayer.name,
      'Black': game.blackPlayer.name,
      'WhiteElo': game.whitePlayer.rating,
      'BlackElo': game.blackPlayer.rating,
      'WhiteTitle': game.whitePlayer.title,
      'BlackTitle': game.blackPlayer.title,
      'WhiteFederation': game.whitePlayer.federation,
      'BlackFederation': game.blackPlayer.federation,
      'Event': game.openingName ?? '',
      'ECO': game.eco ?? '',
      'Result': game.effectiveGameStatus.displayText,
    },
  );
}

String? _initialFenForPreviewPly(ChessGame? game, int ply) {
  if (game == null) return null;
  final mainline = game.mainline;
  if (mainline.isEmpty || ply <= 0) return game.startingFen;
  final index = (ply - 1).clamp(0, mainline.length - 1).toInt();
  return mainline[index].fen;
}

int _clampLibraryPreviewPly(ChessGame? game, int ply) {
  if (game == null || game.mainline.isEmpty) return 0;
  return ply.clamp(0, game.mainline.length).toInt();
}

void _playLibraryPreviewSfxForPly(WidgetRef ref, ChessGame? game, int ply) {
  if (game == null || ply <= 0) return;
  final index = ply - 1;
  if (index < 0 || index >= game.mainline.length) return;
  final settings = ref.read(boardSettingsProviderNew).valueOrNull;
  if (settings?.soundEnabled ?? true) {
    AudioPlayerService.instance.playSfxForSan(game.mainline[index].san);
  }
}

ChessGame? _previewChessGameFromPgn({
  required String id,
  required String? pgn,
  required String? fallbackFen,
  required Map<String, dynamic> metadata,
}) {
  final rawPgn = pgn?.trim();
  if (rawPgn != null && rawPgn.isNotEmpty) {
    try {
      final parsed = ChessGame.fromPgn(id, rawPgn);
      final fallback = _validPreviewFen(fallbackFen);
      if (parsed.mainline.isNotEmpty ||
          fallback == null ||
          fallback == parsed.startingFen) {
        return parsed;
      }
      return ChessGame(
        gameId: id,
        startingFen: fallback,
        metadata: parsed.metadata,
        mainline: const [],
      );
    } catch (_) {
      // Fall back to the advertised FEN below. Some Gamebase rows only carry
      // headers until the full PGN is fetched for the board tab.
    }
  }

  final fen = _validPreviewFen(fallbackFen);
  if (fen == null) return null;
  return ChessGame(
    gameId: id,
    startingFen: fen,
    metadata: metadata,
    mainline: const [],
  );
}

String? _validPreviewFen(String? fen) {
  final trimmed = fen?.trim();
  if (trimmed == null || trimmed.isEmpty || !_isPreviewFenValid(trimmed)) {
    return null;
  }
  return trimmed;
}

bool _isPreviewFenValid(String fen) {
  try {
    Setup.parseFen(fen);
    return true;
  } catch (_) {
    return false;
  }
}

class _SavedAnalysisPreviewPanel extends ConsumerWidget {
  const _SavedAnalysisPreviewPanel({
    required this.analysis,
    required this.onOpen,
    required this.onPlyChanged,
    this.plyIndex = 0,
  });

  final SavedAnalysis? analysis;
  final VoidCallback? onOpen;
  final ValueChanged<int> onPlyChanged;

  /// Ply offset into the mainline (0 = starting position, 1 = after first
  /// move, etc.). Driven by the parent's left/right arrow shortcuts.
  final int plyIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = analysis;
    if (a == null) return const _EmptyDatabasePreview();
    return _LibraryChessGamePreviewPanel(
      game: a.chessGame,
      plyIndex: plyIndex,
      title: a.title,
      onOpen: onOpen,
      onPlyChanged: onPlyChanged,
    );
  }
}

class _LocalPreviewPanel extends StatelessWidget {
  const _LocalPreviewPanel({
    required this.game,
    required this.previewGame,
    required this.plyIndex,
    required this.onPlyChanged,
    required this.onOpen,
  });

  final LocalChessGame? game;
  final ChessGame? previewGame;
  final int plyIndex;
  final ValueChanged<int> onPlyChanged;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final localGame = game;
    if (localGame == null) return const _EmptyDatabasePreview();
    return _LibraryChessGamePreviewPanel(
      game: previewGame ?? localGame.game,
      plyIndex: plyIndex,
      title: localGame.title,
      onOpen: onOpen,
      onPlyChanged: onPlyChanged,
    );
  }
}

class _TwicPreviewPanel extends StatelessWidget {
  const _TwicPreviewPanel({
    required this.game,
    required this.previewGame,
    required this.isResolvingNotation,
    required this.onOpen,
    required this.onPlyChanged,
    this.plyIndex = 0,
  });

  final GamesTourModel? game;
  final ChessGame? previewGame;
  final bool isResolvingNotation;
  final VoidCallback? onOpen;
  final ValueChanged<int> onPlyChanged;
  final int plyIndex;

  @override
  Widget build(BuildContext context) {
    final g = game;
    if (g == null) return const _EmptyDatabasePreview();
    if (previewGame == null) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: DesktopGameCard(
          layout: DesktopCardLayout.grid,
          data: GameCardData.fromGamesTourModel(g),
          onTap: onOpen ?? () {},
        ),
      );
    }
    return _LibraryChessGamePreviewPanel(
      game: previewGame!,
      plyIndex: plyIndex,
      title: '${g.whitePlayer.name} vs ${g.blackPlayer.name}',
      isResolvingNotation: isResolvingNotation,
      onOpen: onOpen,
      onPlyChanged: onPlyChanged,
    );
  }
}

class _LibraryChessGamePreviewPanel extends StatelessWidget {
  const _LibraryChessGamePreviewPanel({
    required this.game,
    required this.plyIndex,
    required this.title,
    required this.onOpen,
    required this.onPlyChanged,
    this.isResolvingNotation = false,
  });

  final ChessGame game;
  final int plyIndex;
  final String title;
  final VoidCallback? onOpen;
  final ValueChanged<int> onPlyChanged;
  final bool isResolvingNotation;

  @override
  Widget build(BuildContext context) {
    final mainline = game.mainline;
    final clampedPly =
        mainline.isEmpty ? 0 : plyIndex.clamp(0, mainline.length).toInt();
    final move = clampedPly == 0 ? null : mainline[clampedPly - 1];
    final fen = move?.fen ?? game.startingFen;
    return _LibraryBoardPreviewPanel(
      fen: fen,
      lastMoveUci: move?.uci,
      ply: clampedPly,
      totalPlies: mainline.length,
      lastSan: move?.san,
      title: title,
      onOpen: onOpen,
      game: game,
      moves: mainline,
      isResolvingNotation: isResolvingNotation,
      onPlyChanged: onPlyChanged,
    );
  }
}

/// Shared board + move readout used by the library table preview panels.
/// Renders a static chessground at [fen], highlights [lastMoveUci] and shows
/// the current ply / total beneath the board.
class _LibraryBoardPreviewPanel extends ConsumerStatefulWidget {
  const _LibraryBoardPreviewPanel({
    required this.fen,
    required this.lastMoveUci,
    required this.ply,
    required this.totalPlies,
    required this.lastSan,
    required this.title,
    required this.onOpen,
    required this.game,
    required this.moves,
    required this.isResolvingNotation,
    required this.onPlyChanged,
  });

  final String fen;
  final String? lastMoveUci;
  final int ply;
  final int totalPlies;
  final String? lastSan;
  final String title;
  final VoidCallback? onOpen;
  final ChessGame game;
  final List<ChessMove> moves;
  final bool isResolvingNotation;
  final ValueChanged<int> onPlyChanged;

  @override
  ConsumerState<_LibraryBoardPreviewPanel> createState() =>
      _LibraryBoardPreviewPanelState();
}

class _LibraryBoardPreviewPanelState
    extends ConsumerState<_LibraryBoardPreviewPanel> {
  @override
  Widget build(BuildContext context) {
    final settings =
        ref.watch(boardSettingsProviderNew).valueOrNull ??
        const BoardSettingsNew();
    final canGoBack = widget.ply > 0;
    final canGoForward = widget.ply < widget.totalPlies;
    final playerLine = _previewPlayerLine(
      widget.game,
      fallbackTitle: widget.title,
    );
    return Padding(
      padding: const EdgeInsets.all(14),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: widget.onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PreviewPlayersHeader(
              whiteName: playerLine.white,
              blackName: playerLine.black,
            ),
            const SizedBox(height: 4),
            _PreviewGameMeta(game: widget.game, fallbackTitle: widget.title),
            const SizedBox(height: 10),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final sideBySide = constraints.maxWidth >= 560;
                  final notation = _LibraryNotationPreview(
                    game: widget.game,
                    activePly: widget.ply,
                    isResolvingNotation: widget.isResolvingNotation,
                    layoutMode: NotationLayoutMode.inline,
                    useFigurine: settings.useFigurine,
                    pieceAssets: settings.pieceAssets,
                    onLayoutModeChanged: (_) {},
                    onPlyChanged: widget.onPlyChanged,
                    onFirst: () => widget.onPlyChanged(0),
                    onPrevious: () => widget.onPlyChanged(widget.ply - 1),
                    onNext: () => widget.onPlyChanged(widget.ply + 1),
                    onLast: () => widget.onPlyChanged(widget.totalPlies),
                    canGoBack: canGoBack,
                    canGoForward: canGoForward,
                  );
                  final board = _LibraryPreviewBoard(
                    fen: widget.fen,
                    lastMoveUci: widget.lastMoveUci,
                    settings: settings,
                  );
                  if (!sideBySide) {
                    final notationHeight =
                        constraints.maxHeight < 220
                            ? 96.0
                            : math.min(340.0, constraints.maxHeight * 0.50);
                    return Column(
                      children: [
                        Expanded(child: board),
                        const SizedBox(height: 10),
                        SizedBox(height: notationHeight, child: notation),
                      ],
                    );
                  }

                  final notationWidth = math.min(
                    520.0,
                    math.max(320.0, constraints.maxWidth * 0.52),
                  );
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: board),
                      const SizedBox(width: 10),
                      SizedBox(width: notationWidth, child: notation),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewPlayerLine {
  const _PreviewPlayerLine({required this.white, required this.black});

  final String white;
  final String black;
}

_PreviewPlayerLine _previewPlayerLine(
  ChessGame game, {
  required String fallbackTitle,
}) {
  final md = game.metadata;
  String s(String key) => (md[key]?.toString() ?? '').trim();
  return _previewPlayerLineFromValues(
    white: s('White'),
    black: s('Black'),
    fallbackTitle: fallbackTitle,
  );
}

_PreviewPlayerLine _previewPlayerLineFromValues({
  required String white,
  required String black,
  required String fallbackTitle,
}) {
  final visibleWhite = desktopTablePlayerValue(white);
  final visibleBlack = desktopTablePlayerValue(black);
  if (visibleWhite.isNotEmpty || visibleBlack.isNotEmpty) {
    return _PreviewPlayerLine(white: visibleWhite, black: visibleBlack);
  }
  final parts = fallbackTitle.split(
    RegExp(r'\s+v(?:s\.?|\.)\s+', caseSensitive: false),
  );
  if (parts.length >= 2) {
    return _PreviewPlayerLine(
      white: desktopTablePlayerValue(parts.first),
      black: desktopTablePlayerValue(parts[1]),
    );
  }
  return const _PreviewPlayerLine(white: '', black: '');
}

@visibleForTesting
({String white, String black}) debugLibraryPreviewPlayerNames({
  required String white,
  required String black,
  required String fallbackTitle,
}) {
  final line = _previewPlayerLineFromValues(
    white: white,
    black: black,
    fallbackTitle: fallbackTitle,
  );
  return (white: line.white, black: line.black);
}

class _PreviewPlayersHeader extends StatelessWidget {
  const _PreviewPlayersHeader({
    required this.whiteName,
    required this.blackName,
  });

  final String whiteName;
  final String blackName;

  @override
  Widget build(BuildContext context) {
    final white = desktopTablePlayerValue(whiteName);
    final black = desktopTablePlayerValue(blackName);
    if (white.isEmpty && black.isEmpty) return const SizedBox.shrink();
    if (white.isEmpty || black.isEmpty) {
      return Center(
        child: _PreviewPlayerName(
          name: white.isNotEmpty ? white : black,
          alignRight: false,
        ),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(child: _PreviewPlayerName(name: white, alignRight: true)),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            'vs',
            style: TextStyle(
              color: kLightGreyColor,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Flexible(child: _PreviewPlayerName(name: black, alignRight: false)),
      ],
    );
  }
}

String _previewMetadataTitle(String raw) {
  final value = desktopTableDisplayValue(raw);
  if (value.isEmpty) return '';
  final parts = value.split(
    RegExp(r'\s+v(?:s\.?|\.)\s+', caseSensitive: false),
  );
  if (parts.length >= 2 &&
      desktopTablePlayerValue(parts.first).isEmpty &&
      desktopTablePlayerValue(parts[1]).isEmpty) {
    return '';
  }
  return value;
}

String _previewMetadataLine({
  required String event,
  required String date,
  required String fallbackTitle,
}) {
  final visibleEvent = desktopTableDisplayValue(event);
  final title =
      visibleEvent.isEmpty
          ? _previewMetadataTitle(fallbackTitle)
          : visibleEvent;
  final visibleDate = _displayGameDate(date);
  return <String>[
    if (title.isNotEmpty) title,
    if (visibleDate.isNotEmpty) visibleDate,
  ].join('  ·  ');
}

@visibleForTesting
String debugLibraryPreviewMetadataLine({
  required String event,
  required String date,
  required String fallbackTitle,
}) => _previewMetadataLine(
  event: event,
  date: date,
  fallbackTitle: fallbackTitle,
);

class _PreviewGameMeta extends StatelessWidget {
  const _PreviewGameMeta({required this.game, required this.fallbackTitle});

  final ChessGame game;
  final String fallbackTitle;

  @override
  Widget build(BuildContext context) {
    final md = game.metadata;
    String s(String key) => (md[key]?.toString() ?? '').trim();
    final line = _previewMetadataLine(
      event: s('Event'),
      date: s('Date'),
      fallbackTitle: fallbackTitle,
    );
    if (line.isEmpty) return const SizedBox.shrink();
    return Text(
      line,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: const TextStyle(
        color: kWhiteColor70,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.05,
      ),
    );
  }
}

class _PreviewPlayerName extends StatelessWidget {
  const _PreviewPlayerName({required this.name, required this.alignRight});

  final String name;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: alignRight ? TextAlign.right : TextAlign.left,
      style: const TextStyle(
        color: kWhiteColor,
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _LibraryPreviewBoard extends StatelessWidget {
  const _LibraryPreviewBoard({
    required this.fen,
    required this.lastMoveUci,
    required this.settings,
  });

  final String fen;
  final String? lastMoveUci;
  final BoardSettingsNew settings;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(constraints.maxWidth, constraints.maxHeight);
        const orientation = Side.white;
        return Center(
          child: SizedBox.square(
            dimension: side,
            child: cg.StaticChessboard(
              key: ValueKey<String>(
                'library-preview-board:$fen:${lastMoveUci ?? ''}:$orientation',
              ),
              size: side,
              fen: fen,
              orientation: orientation,
              settings: cg.StaticChessboardSettings.fromBoardSettings(
                cg.ChessboardSettings(
                  enableCoordinates: false,
                  colorScheme: settings.colorScheme,
                  pieceAssets: settings.pieceAssets,
                ),
              ),
              shapes: const <cg.Shape>{},
              lastMove: _uciToLastMove(lastMoveUci ?? ''),
            ),
          ),
        );
      },
    );
  }
}

class _LibraryNotationPreview extends StatefulWidget {
  const _LibraryNotationPreview({
    required this.game,
    required this.activePly,
    required this.isResolvingNotation,
    required this.layoutMode,
    required this.useFigurine,
    required this.pieceAssets,
    required this.onLayoutModeChanged,
    required this.onPlyChanged,
    required this.onFirst,
    required this.onPrevious,
    required this.onNext,
    required this.onLast,
    required this.canGoBack,
    required this.canGoForward,
  });

  final ChessGame game;
  final int activePly;
  final bool isResolvingNotation;
  final NotationLayoutMode layoutMode;
  final bool useFigurine;
  final cg.PieceAssets? pieceAssets;
  final ValueChanged<NotationLayoutMode> onLayoutModeChanged;
  final ValueChanged<int> onPlyChanged;
  final VoidCallback onFirst;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onLast;
  final bool canGoBack;
  final bool canGoForward;

  @override
  State<_LibraryNotationPreview> createState() =>
      _LibraryNotationPreviewState();
}

class _LibraryNotationPreviewState extends State<_LibraryNotationPreview> {
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'library-notation');
  late final ValueNotifier<NotationLayoutMode> _layoutModeController =
      ValueNotifier<NotationLayoutMode>(widget.layoutMode)
        ..addListener(_onLayoutModeChanged);
  late final ValueNotifier<List<ChessMovePointer>> _visibleMoveOrderController =
      ValueNotifier<List<ChessMovePointer>>(const <ChessMovePointer>[]);

  @override
  void dispose() {
    _layoutModeController.removeListener(_onLayoutModeChanged);
    _layoutModeController.dispose();
    _visibleMoveOrderController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onLayoutModeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _LibraryNotationPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layoutMode != widget.layoutMode &&
        _layoutModeController.value != widget.layoutMode) {
      _layoutModeController.value = widget.layoutMode;
    }
  }

  ChessMovePointer get _activePointer {
    if (widget.activePly <= 0 || widget.game.mainline.isEmpty) {
      return const <int>[];
    }
    final index = (widget.activePly - 1).clamp(
      0,
      widget.game.mainline.length - 1,
    );
    return <int>[index.toInt()];
  }

  void _jumpToPointer(ChessMovePointer pointer) {
    if (pointer.isEmpty) {
      widget.onPlyChanged(0);
      return;
    }
    if (pointer.length == 1) {
      widget.onPlyChanged(pointer.first + 1);
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final shiftPressed = HardwareKeyboard.instance.isShiftPressed;
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (shiftPressed) {
        if (widget.canGoBack) widget.onFirst();
      } else if (widget.canGoBack) {
        widget.onPrevious();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (shiftPressed) {
        if (widget.canGoForward) widget.onLast();
      } else if (widget.canGoForward) {
        widget.onNext();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      if (widget.canGoBack) widget.onFirst();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      if (widget.canGoForward) widget.onLast();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      final next =
          _layoutModeController.value == NotationLayoutMode.ladder
              ? NotationLayoutMode.inline
              : NotationLayoutMode.ladder;
      _layoutModeController.value = next;
      widget.onLayoutModeChanged(next);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      final direction =
          key == LogicalKeyboardKey.arrowUp
              ? NotationVerticalDirection.up
              : NotationVerticalDirection.down;
      final target =
          _layoutModeController.value == NotationLayoutMode.inline
              ? notationVerticalPointer(
                game: widget.game,
                activePointer: _activePointer,
                direction: direction,
                visibleMoveOrder: _visibleMoveOrderController.value,
              )
              : notationLadderVerticalPointer(
                game: widget.game,
                activePointer: _activePointer,
                direction: direction,
              );
      if (target != null) _jumpToPointer(target);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Focus(
            focusNode: _focusNode,
            onKeyEvent: _handleKey,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _focusNode.requestFocus(),
              child: NotationLadderView(
                game: widget.game,
                activePointer: _activePointer,
                onJump: _jumpToPointer,
                scrollController: _scrollController,
                layoutModeController: _layoutModeController,
                visibleMoveOrderController: _visibleMoveOrderController,
                useFigurine: widget.useFigurine,
                pieceAssets: widget.pieceAssets,
                showHeader: false,
              ),
            ),
          ),
          if (widget.isResolvingNotation)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(
                minHeight: 1,
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation(kPrimaryColor),
              ),
            ),
          if (widget.isResolvingNotation && widget.game.mainline.isEmpty)
            Positioned.fill(
              child: ColoredBox(
                color: kBlack2Color.withValues(alpha: 0.72),
                child: const Center(
                  child: Padding(
                    padding: EdgeInsets.all(14),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.7,
                            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                          ),
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Loading notation...',
                          style: TextStyle(
                            color: kWhiteColor70,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Move? _uciToLastMove(String uci) {
  if (uci.length != 4 && uci.length != 5) return null;
  try {
    final from = Square.fromName(uci.substring(0, 2));
    final to = Square.fromName(uci.substring(2, 4));
    final promotion = uci.length == 5 ? Role.fromChar(uci[4]) : null;
    return NormalMove(from: from, to: to, promotion: promotion);
  } catch (_) {
    return null;
  }
}

class _EmptyDatabasePreview extends StatelessWidget {
  const _EmptyDatabasePreview();

  @override
  Widget build(BuildContext context) {
    return const _LibraryEmpty(
      icon: Icons.grid_4x4_outlined,
      title: 'Select a game',
      message: 'Preview its board and notation here.',
    );
  }
}

String _formatSavedDate(DateTime date) {
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '${date.year}-$m-$d';
}

@visibleForTesting
String localLibraryEntryStatusLine(LocalLibraryEntry entry, {int? count}) {
  final effectiveCount = count ?? entry.gameCount;
  final countLabel =
      effectiveCount == null
          ? 'Not indexed'
          : '${formatCompactCount(effectiveCount)} '
              '${effectiveCount == 1 ? 'game' : 'games'}';
  return '$countLabel - ${_formatSavedDate(entry.addedAt)}';
}

@visibleForTesting
bool libraryFolderHasChildren(List<LibraryFolder> folders, String folderId) {
  return folders.any((folder) => folder.parentId == folderId);
}

@visibleForTesting
List<LibraryFolder> libraryVisibleCloudFolders({
  required List<LibraryFolder> folders,
  required String? parentId,
  Set<String> hiddenIds = const <String>{},
  Set<String> pinnedIds = const <String>{},
}) {
  final visible = folders
      .where(
        (folder) =>
            folder.id != kTwicBookId &&
            (folder.parentId == parentId ||
                (parentId == null && pinnedIds.contains(folder.id))) &&
            !hiddenIds.contains(folder.id),
      )
      .toList(growable: false);
  final sorted = List<LibraryFolder>.of(visible);
  sorted.sort((a, b) {
    final byOrder = a.orderIndex.compareTo(b.orderIndex);
    if (byOrder != 0) return byOrder;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return sorted;
}

@visibleForTesting
List<LibraryFolder> libraryFolderPath(
  List<LibraryFolder> folders,
  String? folderId,
) {
  if (folderId == null) return const <LibraryFolder>[];
  final byId = {for (final folder in folders) folder.id: folder};
  final path = <LibraryFolder>[];
  final seen = <String>{};
  String? currentId = folderId;
  while (currentId != null && seen.add(currentId)) {
    final folder = byId[currentId];
    if (folder == null) break;
    path.insert(0, folder);
    currentId = folder.parentId;
  }
  return path;
}

@visibleForTesting
String libraryMyDatabasesBreadcrumbText({
  required List<LibraryFolder> folders,
  required String? currentFolderId,
  String? localGroupLabel,
}) {
  final localLabel = localGroupLabel?.trim();
  final segments = <String>['Library Home'];
  if (localLabel != null && localLabel.isNotEmpty) {
    segments.add(localLabel);
  } else {
    segments.addAll(
      libraryFolderPath(folders, currentFolderId).map((folder) => folder.name),
    );
  }
  return segments.join(' › ');
}

// =====================================================================
// Sorting helper
// =====================================================================

List<LibraryFolder> _hierarchical(List<LibraryFolder> folders) {
  final byParent = <String?, List<LibraryFolder>>{};
  for (final f in folders) {
    byParent.putIfAbsent(f.parentId, () => []).add(f);
  }
  final out = <LibraryFolder>[];
  void visit(String? parentId) {
    final children = byParent[parentId];
    if (children == null || children.isEmpty) return;
    children.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    for (final folder in children) {
      out.add(folder);
      visit(folder.id);
    }
  }

  visit(null);
  if (out.length < folders.length) {
    final ids = out.map((f) => f.id).toSet();
    for (final folder in folders) {
      if (!ids.contains(folder.id)) out.add(folder);
    }
  }
  return out;
}
