import 'dart:async';
import 'dart:math' as math;

import 'package:chessground/chessground.dart' as cg;
import 'package:collection/collection.dart';
import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/providers/board_settings_provider_new.dart';

import 'package:chessever/desktop/services/desktop_game_library_saver.dart';
import 'package:chessever/desktop/services/desktop_share_actions.dart';
import 'package:chessever/desktop/services/board_tab_pgn_resolver.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/services/library_pgn_export.dart';
import 'package:chessever/desktop/services/library_quick_import.dart';
import 'package:chessever/desktop/services/local_chess_drop_zone.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/cloud_library_refresh.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/library_import_buffer.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/desktop/state/my_databases_focus.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/utils/library_multi_select.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/list_keyboard_scroll.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/game_tab_drag_payload.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/desktop/widgets/library/folder_drop_target.dart';
import 'package:chessever/desktop/widgets/library/library_actions_toolbar.dart';
import 'package:chessever/desktop/widgets/library/library_folder_context_menu.dart';
import 'package:chessever/desktop/widgets/library/library_folder_dialogs.dart';
import 'package:chessever/desktop/widgets/library/library_game_context_menu.dart';
import 'package:chessever/desktop/widgets/library/library_game_dialogs.dart';
import 'package:chessever/desktop/widgets/library/library_database_drag_payload.dart';
import 'package:chessever/desktop/widgets/library/local_chess_files_view.dart';
import 'package:chessever/desktop/widgets/library/library_pgn_preview_panel.dart';
import 'package:chessever/desktop/widgets/library/twic_filter_dialog.dart';
import 'package:chessever/desktop/widgets/motion_card.dart';
import 'package:chessever/desktop/widgets/new_tab_modifier.dart';
import 'package:chessever/desktop/widgets/resizable_split_view.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
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
import 'package:chessever/widgets/federation_flag.dart';

/// Desktop library: persistent two-pane layout (folder rail + content) with
/// the forui actions toolbar at the top.
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
    // The synthetic TWIC folder is always pinned at the top of the rail and
    // is not part of any user-owned/subscribed list — `allFolders` includes
    // it so dispatch and content lookups work uniformly.
    final allFolders = useMemoized(
      () => [kTwicFolder, ...ownedSorted, ...subscribedSorted],
      [ownedSorted, subscribedSorted],
    );

    final import = ref.watch(libraryImportBufferProvider);
    final localState = ref.watch(localChessLibraryProvider);
    final mainSplitController = useMemoized(ResizableSplitViewController.new);
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
      openDatabaseWorkspaceTab(
        ref,
        DatabaseWorkspaceArgs.local(
          localPath: path,
          title: localDatabaseWorkspaceTitle(source, path),
        ),
      );
    }

    void openCloudDatabase(LibraryFolder folder) {
      if (folder.id == kTwicBookId) {
        openDatabaseWorkspaceTab(ref, const DatabaseWorkspaceArgs.twic());
        return;
      }
      openDatabaseWorkspaceTab(
        ref,
        DatabaseWorkspaceArgs.folder(
          folderId: folder.id,
          title: folder.name,
          isSubscribed: folder.isSubscribed,
        ),
      );
    }

    Future<void> openLocalFiles() async {
      final opened =
          await ref.read(localChessLibraryProvider.notifier).pickFiles();
      if (!opened) return;
      final path = ref.read(localChessLibraryProvider).selectedPath;
      if (path != null) openLocalFullView(path);
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
      // Yield one microtask so a nested FolderDropTarget gets a chance to
      // synchronously call arbiter.claim() before we decide what to do.
      await Future<void>.delayed(Duration.zero);
      if (arbiter.consumeClaim()) return;

      // No inner target claimed the drop. If the user is currently looking
      // at a writable cloud folder (and not the local browser), treat the
      // drop as "import into that folder" — that's the goal of the
      // local→supabase quick-drop affordance. Otherwise fall back to the
      // legacy behavior of opening the files as a local browse session.
      final folderId = selectedFolderId.value;
      LibraryFolder? activeFolder;
      if (folderId != null) {
        for (final f in allFolders) {
          if (f.id == folderId) {
            activeFolder = f;
            break;
          }
        }
      }
      final canImportToActive =
          selectedLocalPath.value == null &&
          activeFolder != null &&
          isWritableLibraryFolder(activeFolder);
      if (canImportToActive) {
        if (!context.mounted) return;
        await quickImportPathsToFolder(
          context: context,
          ref: ref,
          folder: activeFolder,
          paths: paths,
        );
        return;
      }

      final opened = await ref
          .read(localChessLibraryProvider.notifier)
          .openPaths(paths, sourceLabel: 'Dropped local files');
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
                  label: 'Folders',
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
                    onOpen: (folder) => openCloudDatabase(folder),
                    onAction:
                        (folder, action) => _onFolderAction(
                          context: context,
                          ref: ref,
                          folder: folder,
                          action: action,
                          allFolders: allFolders,
                        ),
                    onCreateRoot:
                        () => _onCreateFolder(
                          context: context,
                          ref: ref,
                          folders: allFolders,
                          lockedParent: null,
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
                            selectedFolderId: selectedFolderId.value,
                            selectedLocalPath: selectedLocalPath.value,
                            onSelectFolder: (folder) {
                              selectedFolderId.value = folder.id;
                              selectedLocalPath.value = null;
                              localFullViewPath.value = null;
                            },
                            onOpenFolder: (folder) => openCloudDatabase(folder),
                            onSelectLocalPath: activateLocalPath,
                            onOpenLocalPath: openLocalFullView,
                            onOpenLocalFiles: openLocalFiles,
                            onDropDatabase: addDatabaseDragShortcut,
                            onNewFolder:
                                () => _onCreateFolder(
                                  context: context,
                                  ref: ref,
                                  folders: allFolders,
                                  lockedParent: null,
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
// Folder rail (sectioned: My folders / Subscribed)
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
    required this.onCreateRoot,
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
  final VoidCallback onCreateRoot;
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
          const Divider(height: 1, color: kDividerColor),
          _RailFooter(onCreate: onCreateRoot),
        ],
      ),
    );
  }

  Widget _body() {
    if (isLoading) return const _RailLoading();
    if (error != null) return _RailError(error: error!);
    return ListView(
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        if (ownedFolders.isNotEmpty) ...[
          _RailGroupHeader(label: 'My folders', count: ownedFolders.length),
          for (final folder in ownedFolders)
            _FolderRow(
              folder: folder,
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
              'Library',
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
  });
  final LibraryFolder folder;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_PinnedSystemFolderRow> createState() => _PinnedSystemFolderRowState();
}

class _PinnedSystemFolderRowState extends State<_PinnedSystemFolderRow> {
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
          onEnter: (_) => setState(() => _hovered = true),
          onExit:
              (_) => setState(() {
                _hovered = false;
                _pressed = false;
              }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
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
            'Create one below, or import a PGN to get started.',
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

class _RailFooter extends StatelessWidget {
  const _RailFooter({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: DesktopTooltip(
        message: 'Create a new folder',
        child: SizedBox(
          width: double.infinity,
          child: FButton(
            style: FButtonStyle.outline(),
            onPress: onCreate,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, size: 14),
                SizedBox(width: 6),
                Text('New folder'),
              ],
            ),
          ),
        ),
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

class _RailError extends StatelessWidget {
  const _RailError({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: Text(
        'Could not load folders.\nSign in to sync.\n\n$error',
        style: const TextStyle(color: kLightGreyColor, fontSize: 11),
      ),
    );
  }
}

class _FolderRow extends ConsumerStatefulWidget {
  const _FolderRow({
    required this.folder,
    required this.selected,
    required this.onTap,
    required this.onOpen,
    required this.onAction,
  });

  final LibraryFolder folder;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onOpen;
  final ValueChanged<LibraryFolderAction> onAction;

  @override
  ConsumerState<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends ConsumerState<_FolderRow> {
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
            ? kPrimaryColor.withValues(alpha: 0.10)
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
        canCreateSubfolder: !isChild && !widget.folder.isSubscribed,
        hasGames: true, // count is unknown at rail level; menu still useful.
        onAction: widget.onAction,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 1, 8, 1),
          child: ClickCursor(
            child: MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit:
                  (_) => setState(() {
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
                  onTapDown: (_) => setState(() => _pressed = true),
                  onTapUp: (_) => setState(() => _pressed = false),
                  onTapCancel: () => setState(() => _pressed = false),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: EdgeInsets.fromLTRB(isChild ? 22 : 12, 8, 10, 8),
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
                      motion:
                          _pressed ? DesktopMotion.tap : DesktopMotion.hover,
                      builder:
                          (context, x, child) => Transform.translate(
                            offset: Offset(x, 0),
                            child: child,
                          ),
                      child: Row(
                        children: [
                          Icon(
                            widget.folder.isSubscribed
                                ? Icons.cloud_done_outlined
                                : (isChild
                                    ? Icons.folder_outlined
                                    : Icons.folder_rounded),
                            size: 14,
                            color: fg,
                          ),
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
                          if (widget.folder.isSubscribed)
                            const DesktopTooltip(
                              message: 'Subscribed (read-only)',
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
      title = 'TWIC',
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

enum _LibraryDatabaseKind { cloud, local }

enum _DatabaseBoardAction { addToMyDatabase, preview, open, remove }

class _MyDatabasesHomeView extends HookConsumerWidget {
  const _MyDatabasesHomeView({
    required this.folders,
    required this.selectedFolderId,
    required this.selectedLocalPath,
    required this.onSelectFolder,
    required this.onOpenFolder,
    required this.onSelectLocalPath,
    required this.onOpenLocalPath,
    required this.onOpenLocalFiles,
    required this.onDropDatabase,
    required this.onNewFolder,
  });

  final List<LibraryFolder> folders;
  final String? selectedFolderId;
  final String? selectedLocalPath;
  final ValueChanged<LibraryFolder> onSelectFolder;
  final ValueChanged<LibraryFolder> onOpenFolder;
  final ValueChanged<String> onSelectLocalPath;
  final ValueChanged<String> onOpenLocalPath;
  final VoidCallback onOpenLocalFiles;
  final Future<void> Function(LibraryDatabaseDragPayload payload)
  onDropDatabase;
  final VoidCallback onNewFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MyDatabasesHeader(
          onNewFolder: onNewFolder,
          onOpenLocalFiles: onOpenLocalFiles,
        ),
        const FDivider(),
        Expanded(
          child: ResizableSplitView(
            axis: Axis.vertical,
            storageKey: 'library_pane.my_databases.home_split',
            children: [
              SplitChild(
                minSize: 132,
                maxSize: 320,
                initialWeight: 0.30,
                label: 'My Databases',
                child: _MyDatabasesBoard(
                  folders: folders,
                  localSource: localSource,
                  selectedFolderId: selectedFolderId,
                  selectedLocalPath: selectedLocalPath,
                  onSelectFolder: onSelectFolder,
                  onOpenFolder: onOpenFolder,
                  onSelectLocalPath: onSelectLocalPath,
                  onOpenLocalPath: onOpenLocalPath,
                  onDropDatabase: onDropDatabase,
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
                    onOpen:
                        selectedLocalPath == null
                            ? null
                            : () => onOpenLocalPath(selectedLocalPath!),
                  ),
                  _LibraryDatabaseKind.cloud => _CloudDatabaseMiniPreview(
                    folder: selectedFolder,
                    onOpenFolder: onOpenFolder,
                  ),
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MyDatabasesHeader extends StatelessWidget {
  const _MyDatabasesHeader({
    required this.onNewFolder,
    required this.onOpenLocalFiles,
  });

  final VoidCallback onNewFolder;
  final VoidCallback onOpenLocalFiles;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 14),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: kPrimaryColor.withValues(alpha: 0.34)),
            ),
            child: const Icon(
              Icons.storage_rounded,
              color: kPrimaryColor,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text(
                  'My Databases',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          LibraryActionsToolbar(onNewFolder: onNewFolder),
        ],
      ),
    );
  }
}

class _MyDatabasesBoard extends HookConsumerWidget {
  const _MyDatabasesBoard({
    required this.folders,
    required this.localSource,
    required this.selectedFolderId,
    required this.selectedLocalPath,
    required this.onSelectFolder,
    required this.onOpenFolder,
    required this.onSelectLocalPath,
    required this.onOpenLocalPath,
    required this.onDropDatabase,
  });

  final List<LibraryFolder> folders;
  final LocalChessSource? localSource;
  final String? selectedFolderId;
  final String? selectedLocalPath;
  final ValueChanged<LibraryFolder> onSelectFolder;
  final ValueChanged<LibraryFolder> onOpenFolder;
  final ValueChanged<String> onSelectLocalPath;
  final ValueChanged<String> onOpenLocalPath;
  final Future<void> Function(LibraryDatabaseDragPayload payload)
  onDropDatabase;

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
    final hiddenCloudFolderIds =
        ref.watch(myDatabasesFocusProvider).hiddenCloudFolderIds;
    final localEntries = ref.watch(localLibraryRegistryProvider).entries;

    int? localGameCount(LocalLibraryEntry entry) {
      final source = localSource;
      if (source == null || !source.paths.contains(entry.path)) return null;
      if (source.paths.length == 1) return source.root.gameCount;
      final node = source.root.find(entry.path);
      return switch (node) {
        LocalChessFolderNode(:final gameCount) => gameCount,
        LocalChessFileNode(:final games) => games.length,
        _ => null,
      };
    }

    final items = <_DatabaseBoardItem>[
      for (final folder in <LibraryFolder>[
        kTwicFolder,
        ...folders.where(
          (f) => f.id != kTwicBookId && !hiddenCloudFolderIds.contains(f.id),
        ),
      ])
        _DatabaseBoardItem.cloud(folder: folder, count: counts[folder.id]),
      for (final entry in localEntries)
        _DatabaseBoardItem.local(entry: entry, count: localGameCount(entry)),
    ];
    items.sort((a, b) {
      final byCount = (b.count ?? 0).compareTo(a.count ?? 0);
      if (byCount != 0) return byCount;
      if (a.isTwic) return -1;
      if (b.isTwic) return 1;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

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

    Future<void> removeLocalEntry(LocalLibraryEntry entry) async {
      await ref
          .read(localLibraryRegistryProvider.notifier)
          .unregister(entry.path);
      final activeSource = ref.read(localChessLibraryProvider).source;
      if (activeSource != null && activeSource.paths.contains(entry.path)) {
        ref.read(localChessLibraryProvider.notifier).clear();
      }
    }

    Future<void> showLocalContextMenu(
      LocalLibraryEntry entry,
      Offset position,
    ) async {
      final picked = await showDesktopContextMenu<_DatabaseBoardAction>(
        context: context,
        position: position,
        width: 230,
        entries: const [
          DesktopContextMenuItem(
            value: _DatabaseBoardAction.preview,
            icon: Icons.table_rows_outlined,
            label: 'Preview database',
          ),
          DesktopContextMenuItem(
            value: _DatabaseBoardAction.open,
            icon: Icons.open_in_new_rounded,
            label: 'Open full database',
          ),
          DesktopContextMenuDivider(),
          DesktopContextMenuItem(
            value: _DatabaseBoardAction.remove,
            icon: Icons.delete_outline_rounded,
            label: 'Remove from My Databases',
            destructive: true,
          ),
        ],
      );
      if (picked == null || !context.mounted) return;
      switch (picked) {
        case _DatabaseBoardAction.addToMyDatabase:
          return;
        case _DatabaseBoardAction.preview:
          await previewLocalEntry(entry);
        case _DatabaseBoardAction.open:
          await openLocalEntry(entry);
        case _DatabaseBoardAction.remove:
          await removeLocalEntry(entry);
      }
    }

    Future<void> removeCloudFolderFromBoard(LibraryFolder folder) async {
      if (folder.id == kTwicBookId) return;
      await ref
          .read(myDatabasesFocusProvider.notifier)
          .hideCloudFolder(folder.id);
      if (selectedFolderId == folder.id && selectedLocalPath == null) {
        onSelectFolder(kTwicFolder);
      }
    }

    Future<void> showCloudContextMenu(
      LibraryFolder folder,
      Offset position,
    ) async {
      if (folder.id == kTwicBookId) return;
      final canImport = isWritableLibraryFolder(folder);
      final picked = await showDesktopContextMenu<_DatabaseBoardAction>(
        context: context,
        position: position,
        width: 230,
        entries: [
          if (canImport) ...[
            const DesktopContextMenuItem(
              value: _DatabaseBoardAction.addToMyDatabase,
              icon: Icons.add_circle_outline_rounded,
              label: 'Add to My Database...',
            ),
            const DesktopContextMenuDivider(),
          ],
          const DesktopContextMenuItem(
            value: _DatabaseBoardAction.preview,
            icon: Icons.table_rows_outlined,
            label: 'Preview database',
          ),
          const DesktopContextMenuItem(
            value: _DatabaseBoardAction.open,
            icon: Icons.open_in_new_rounded,
            label: 'Open full database',
          ),
          if (canImport) ...[
            const DesktopContextMenuDivider(),
            const DesktopContextMenuItem(
              value: _DatabaseBoardAction.remove,
              icon: Icons.delete_outline_rounded,
              label: 'Remove from My Databases',
              destructive: true,
            ),
          ],
        ],
      );
      if (picked == null || !context.mounted) return;
      switch (picked) {
        case _DatabaseBoardAction.addToMyDatabase:
          await _pickAndImportFilesToFolder(
            context: context,
            ref: ref,
            folder: folder,
          );
        case _DatabaseBoardAction.preview:
          onSelectFolder(folder);
        case _DatabaseBoardAction.open:
          onOpenFolder(folder);
        case _DatabaseBoardAction.remove:
          await removeCloudFolderFromBoard(folder);
      }
    }

    Widget buildBoardTile(_DatabaseBoardItem item) {
      final folder = item.folder;
      final entry = item.entry;
      final tile = _DatabaseBoardTile(
        title: item.title,
        icon: item.icon,
        selected:
            folder != null
                ? folder.id == selectedFolderId && selectedLocalPath == null
                : selectedLocalPath == entry!.path ||
                    (localSource?.paths.contains(entry.path) == true &&
                        selectedLocalPath == localSource?.root.path),
        onSelect:
            folder != null
                ? () => onSelectFolder(folder)
                : () => unawaited(previewLocalEntry(entry!)),
        onOpen:
            folder != null
                ? () => onOpenFolder(folder)
                : () => unawaited(openLocalEntry(entry!)),
        onContextMenu:
            folder != null
                ? (folder.id == kTwicBookId
                    ? null
                    : (position) =>
                        unawaited(showCloudContextMenu(folder, position)))
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
          child: ListView(
            physics: const DesktopScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [for (final item in items) buildBoardTile(item)],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DatabaseBoardItem {
  const _DatabaseBoardItem.cloud({required this.folder, required this.count})
    : entry = null;

  const _DatabaseBoardItem.local({required this.entry, required this.count})
    : folder = null;

  final LibraryFolder? folder;
  final LocalLibraryEntry? entry;
  final int? count;

  bool get isTwic => folder?.id == kTwicBookId;

  String get title => folder?.name ?? entry!.displayName;

  IconData get icon {
    final f = folder;
    if (f == null) return Icons.account_tree_outlined;
    if (f.id == kTwicBookId) return Icons.public_rounded;
    if (f.isSubscribed) return Icons.cloud_done_outlined;
    return Icons.folder_rounded;
  }
}

class _DatabaseBoardTile extends StatefulWidget {
  const _DatabaseBoardTile({
    required this.title,
    required this.icon,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
    this.onContextMenu,
  });

  final String title;
  final IconData icon;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onOpen;
  final ValueChanged<Offset>? onContextMenu;

  @override
  State<_DatabaseBoardTile> createState() => _DatabaseBoardTileState();
}

class _DatabaseBoardTileState extends State<_DatabaseBoardTile> {
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
    final borderColor =
        widget.selected
            ? kPrimaryColor.withValues(alpha: 0.75)
            : _hovered
            ? kPrimaryColor.withValues(alpha: 0.32)
            : kDividerColor;
    return SizedBox(
      width: 164,
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
        child: ClickCursor(
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color:
                        widget.selected
                            ? kPrimaryColor.withValues(alpha: 0.12)
                            : (_hovered ? kBlack3Color : kBlack2Color),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: borderColor),
                    // Selection keeps a persistent shadow; hover/press shadow
                    // is owned by the [MotionCard] dock above.
                    boxShadow:
                        widget.selected
                            ? [
                              BoxShadow(
                                color: kPrimaryColor.withValues(alpha: 0.18),
                                blurRadius: 18,
                                offset: const Offset(0, 6),
                              ),
                            ]
                            : null,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          widget.icon,
                          color: kPrimaryColor,
                          size: 17,
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
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
    );
  }
}

class _CloudDatabaseMiniPreview extends HookConsumerWidget {
  const _CloudDatabaseMiniPreview({
    required this.folder,
    required this.onOpenFolder,
  });

  final LibraryFolder? folder;
  final ValueChanged<LibraryFolder> onOpenFolder;

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
      return _TwicDatabaseMiniPreview(onOpen: () => onOpenFolder(activeFolder));
    }
    final shortcutsFocusNode = useFocusNode(
      debugLabel: 'library-mini-saved-${activeFolder.id}',
    );
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
          onOpen: () => onOpenFolder(activeFolder),
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
  const _TwicDatabaseMiniPreview({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scrollController = useScrollController();
    final selectedId = useState<String?>(null);
    final selectedIds = useState<Set<String>>(<String>{});
    final selectionAnchor = useState<int?>(null);
    final selectionExtent = useState<int?>(null);
    final plyIndex = useState<int>(0);
    final shortcutsFocusNode = useFocusNode(debugLabel: 'library-mini-twic');
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
          title: 'TWIC',
          subtitle:
              totalAsync.valueOrNull == null
                  ? 'System database · mini preview'
                  : '${formatCompactCount(totalAsync.valueOrNull!)} games · mini preview',
          onOpen: onOpen,
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
    required this.onOpen,
  });

  final LocalChessSource? source;
  final LocalChessNode? selectedNode;
  final String? selectedPath;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final node = selectedNode;
    final scrollController = useScrollController();
    final selectedIndex = useState<int>(0);
    final selectedIds = useState<Set<String>>(<String>{});
    final selectionAnchor = useState<int?>(null);
    final selectionExtent = useState<int?>(null);
    final plyIndex = useState<int>(0);
    final shortcutsFocusNode = useFocusNode(debugLabel: 'library-mini-local');

    if (source == null || node == null || selectedPath == null) {
      return const _LibraryEmpty(
        icon: Icons.add_to_drive_outlined,
        title: 'Add a local database',
        message:
            'Open a local folder or files above, then click a tile to preview it.',
      );
    }
    final games = switch (node) {
      LocalChessFolderNode() =>
        selectedLocalChessDatabaseFile(node)?.games ?? node.gamesInSubtree,
      LocalChessFileNode(:final games) => games,
      _ => const <LocalChessGame>[],
    };
    final visibleGames = games.take(80).toList();
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
      [selectedPath, selectedGame?.id, selectedGame?.rawPgn],
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
        databaseTitle: node.name.isEmpty ? source!.label : node.name,
        databaseGames: games,
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
          title: node.name.isEmpty ? source!.label : node.name,
          subtitle:
              '${localChessEntryCountLabel(games.length)} · local mini preview',
          onOpen: onOpen,
          child:
              selectedGame == null
                  ? const _LibraryEmpty(
                    icon: Icons.description_outlined,
                    title: 'No parsed games here',
                    message:
                        'Open the local database view to browse folders/files.',
                  )
                  : Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 10, 20),
                          child: ListView.builder(
                            controller: scrollController,
                            physics: const DesktopScrollPhysics(),
                            padding: EdgeInsets.zero,
                            itemExtent: _kLocalMiniPreviewRowExtent,
                            itemCount: visibleGames.length,
                            itemBuilder: (context, index) {
                              final game = visibleGames[index];
                              final meta = game.game.metadata;
                              final selected =
                                  clampedSelectedIds.contains(game.id) ||
                                  (clampedSelectedIds.isEmpty &&
                                      index == safeIndex);
                              return ClickCursor(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap:
                                      () =>
                                          HardwareKeyboard
                                                  .instance
                                                  .isShiftPressed
                                              ? rangeSelectLocalIndex(index)
                                              : selectLocalIndex(index),
                                  onDoubleTap:
                                      () => _openLocalPreviewGame(
                                        ref,
                                        game,
                                        databaseTitle:
                                            node.name.isEmpty
                                                ? source!.label
                                                : node.name,
                                        databaseGames: games,
                                      ),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 9,
                                    ),
                                    decoration: BoxDecoration(
                                      color:
                                          selected
                                              ? kPrimaryColor.withValues(
                                                alpha: 0.20,
                                              )
                                              : kBlack2Color,
                                      border: const Border(
                                        bottom: BorderSide(
                                          color: kDividerColor,
                                          width: 1,
                                        ),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 36,
                                          child: Text(
                                            '${index + 1}',
                                            style: const TextStyle(
                                              color: kLightGreyColor,
                                              fontSize: 11,
                                              fontFeatures: [
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            game.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: kWhiteColor,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Text(
                                          (meta['Result'] ?? '*').toString(),
                                          style: const TextStyle(
                                            color: kWhiteColor70,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        SizedBox(
                                          width: 44,
                                          child: _EcoCell(
                                            eco: (meta['ECO'] ?? '').toString(),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 5,
                        child: _LocalPreviewPanel(
                          game: selectedGame,
                          plyIndex: plyIndex.value,
                          onPlyChanged: setSelectedLocalPly,
                          onOpen:
                              () => _openLocalPreviewGame(
                                ref,
                                selectedGame,
                                databaseTitle:
                                    node.name.isEmpty
                                        ? source!.label
                                        : node.name,
                                databaseGames: games,
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
      ),
    );
  }
}

class _MiniDatabasePreviewFrame extends StatelessWidget {
  const _MiniDatabasePreviewFrame({
    required this.title,
    required this.subtitle,
    required this.onOpen,
    required this.child,
  });

  final String title;
  final String subtitle;
  final VoidCallback? onOpen;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 18, 8),
          child: Row(
            children: [
              const Icon(
                Icons.preview_outlined,
                color: kPrimaryColor,
                size: 16,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kLightGreyColor,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (onOpen != null)
                const DesktopTooltip(
                  message: 'Double-click or press Enter to open this database',
                  child: Icon(
                    Icons.keyboard_return_rounded,
                    size: 16,
                    color: kLightGreyColor,
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1, color: kDividerColor),
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

    return Container(
      color: kBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FolderHeader(
            folder: activeFolder,
            count: analysesAsync.data?.length,
            isLoading: analysesAsync.connectionState != ConnectionState.done,
            canCreateSubfolder:
                activeFolder.parentId == null && !activeFolder.isSubscribed,
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
          const FDivider(),
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
                  onGameAction: (analysis, action) {
                    if (action == LibraryGameAction.copyPgn &&
                        selectedIds.value.contains(analysis.id) &&
                        selectedAnalyses.length > 1) {
                      unawaited(
                        copySavedAnalysesAsPgn(
                          context: context,
                          analyses: selectedAnalyses,
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
class _LibraryBodyShortcuts extends HookConsumerWidget {
  const _LibraryBodyShortcuts({
    required this.folder,
    required this.copyScope,
    required this.onExtendSelectionUp,
    required this.onExtendSelectionDown,
    required this.child,
  });

  final LibraryFolder folder;
  final List<SavedAnalysis> copyScope;
  final VoidCallback onExtendSelectionUp;
  final VoidCallback onExtendSelectionDown;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focusNode = useFocusNode(debugLabel: 'library_body_${folder.id}');
    // Re-claim focus when the user switches between folders so the next
    // Ctrl+V/Ctrl+C lands without having to click the empty listview first.
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (focusNode.canRequestFocus) focusNode.requestFocus();
      });
      return null;
    }, [folder.id]);

    final canImport = isWritableLibraryFolder(folder);

    void handlePaste() {
      if (!canImport) {
        showDesktopToast(
          context,
          '"${folder.name}" is read-only.',
          error: true,
        );
        return;
      }
      unawaited(
        quickImportClipboardToFolder(
          context: context,
          ref: ref,
          folder: folder,
        ),
      );
    }

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
            const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
                handlePaste,
            const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                handlePaste,
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
            ? 'Loading games…'
            : (count == null
                ? 'Unknown game count'
                : '${count!} ${count == 1 ? 'game' : 'games'}'));
    final icon =
        iconOverride ??
        (folder.isSubscribed
            ? Icons.cloud_done_outlined
            : Icons.folder_rounded);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kPrimaryColor.withValues(alpha: 0.32)),
            ),
            child: Icon(icon, size: 18, color: kPrimaryColor),
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
                        folder.name,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 10),
                      badge!,
                    ] else if (folder.isSubscribed) ...[
                      const SizedBox(width: 10),
                      const _ReadOnlyBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
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
          LibraryActionsToolbar(
            suggestedFolderId:
                (folder.isSubscribed || folder.id == kTwicBookId)
                    ? null
                    : folder.id,
            onNewFolder: onNewFolder,
          ),
          if (showOverflow && onAction != null) ...[
            const SizedBox(width: 8),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: kDividerColor),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline_rounded, size: 10, color: kLightGreyColor),
          SizedBox(width: 5),
          Text(
            'Subscribed',
            style: TextStyle(
              color: kLightGreyColor,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
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

class _OverflowMenuButtonState extends State<_OverflowMenuButton> {
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
      canCreateSubfolder: widget.canCreateSubfolder,
      hasGames: widget.hasGames,
      onAction: widget.onAction,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: 'More actions',
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 10),
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
          const SizedBox(width: 12),
          _ViewModeToggle(value: viewMode, onChanged: onViewModeChanged),
          const SizedBox(width: 12),
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
                  Icon(Icons.save_alt_rounded, size: 13),
                  SizedBox(width: 6),
                  Text('Export'),
                ],
              ),
            ),
          ),
        ],
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
      height: 36,
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
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

class _ViewModeButtonState extends State<_ViewModeButton> {
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
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 34,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(widget.icon, size: 14, color: fg),
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
          canDelete: !folder.isSubscribed,
          selectedIds: selectedIds,
          onPrimeSelectionAnchor: onPrimeSelectionAnchor,
          onRangeSelect: onRangeSelect,
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
          canDelete: !folder.isSubscribed,
          selectedIds: selectedIds,
          onPrimeSelectionAnchor: onPrimeSelectionAnchor,
          onRangeSelect: onRangeSelect,
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
          canDelete: !folder.isSubscribed,
          selectedIds: selectedIds,
          onPrimeSelectionAnchor: onPrimeSelectionAnchor,
          onRangeSelect: onRangeSelect,
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
          canDelete: !folder.isSubscribed,
          selectedIds: selectedIds,
          onPrimeSelectionAnchor: onPrimeSelectionAnchor,
          onRangeSelect: onRangeSelect,
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
  final void Function(SavedAnalysis analysis, LibraryGameAction action)
  onAction;

  @override
  Widget build(BuildContext context) {
    final scrollController = useScrollController();
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
            _GamesTableHeader(sort: sort, onSortChange: onSortChange),
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
                        onPrimeSelectionAnchor:
                            (_) => onPrimeSelectionAnchor(i),
                        onRangeSelect: (_) => onRangeSelect(i),
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

// Shared column flex/widths so header and rows always align. When tweaking
// columns, update both lists in lockstep — flex widgets calculated by Row
// are sensitive to tiny mismatches.
const _kColNumber = 42.0;
const _kColW = 5; // White player flex
const _kColElo = 56.0;
const _kColResult = 56.0;
const _kColB = 5; // Black player flex
const _kColEvent = 4; // Event flex
const _kColEco = 62.0;
const _kColDate = 88.0;
const _kColSaved = 78.0;

class _GamesTableHeader extends StatelessWidget {
  const _GamesTableHeader({required this.sort, required this.onSortChange});

  final _SortConfig sort;
  final ValueChanged<_SortConfig> onSortChange;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: kBlack3Color.withValues(alpha: 0.4),
      child: Row(
        children: [
          SizedBox(
            width: _kColNumber,
            child: _HeaderCell(
              label: '#',
              key_: _SortKey.number,
              sort: sort,
              onSortChange: onSortChange,
              alignEnd: true,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: _kColW,
            child: _HeaderCell(
              label: 'White',
              key_: _SortKey.white,
              sort: sort,
              onSortChange: onSortChange,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _kColElo,
            child: _HeaderCell(
              label: 'Elo W',
              key_: _SortKey.whiteElo,
              sort: sort,
              onSortChange: onSortChange,
              alignEnd: true,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _kColResult,
            child: _HeaderCell(
              label: 'Result',
              key_: _SortKey.result,
              sort: sort,
              onSortChange: onSortChange,
              alignEnd: true,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: _kColB,
            child: _HeaderCell(
              label: 'Black',
              key_: _SortKey.black,
              sort: sort,
              onSortChange: onSortChange,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _kColElo,
            child: _HeaderCell(
              label: 'Elo B',
              key_: _SortKey.blackElo,
              sort: sort,
              onSortChange: onSortChange,
              alignEnd: true,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: _kColEvent,
            child: _HeaderCell(
              label: 'Event',
              key_: _SortKey.event,
              sort: sort,
              onSortChange: onSortChange,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _kColEco,
            child: _HeaderCell(
              label: 'ECO',
              key_: _SortKey.eco,
              sort: sort,
              onSortChange: onSortChange,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _kColDate,
            child: _HeaderCell(
              label: 'Date',
              key_: _SortKey.date,
              sort: sort,
              onSortChange: onSortChange,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _kColSaved,
            child: _HeaderCell(
              label: 'Saved',
              key_: _SortKey.saved,
              sort: sort,
              onSortChange: onSortChange,
              alignEnd: true,
            ),
          ),
        ],
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

class _HeaderCellState extends State<_HeaderCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.sort.key == widget.key_;
    final color =
        active ? kPrimaryColor : (_hovered ? kWhiteColor : kLightGreyColor);
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
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
    required this.onPrimeSelectionAnchor,
    required this.onRangeSelect,
    required this.onAction,
  });

  final int index;
  final SavedAnalysis analysis;
  final VoidCallback onOpen;
  final bool canDelete;
  final Set<String> selectedIds;
  final ValueChanged<int> onPrimeSelectionAnchor;
  final ValueChanged<int> onRangeSelect;
  final ValueChanged<LibraryGameAction> onAction;

  @override
  State<_GamesTableRow> createState() => _GamesTableRowState();
}

class _GamesTableRowState extends State<_GamesTableRow> {
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
    final whiteTitle = s('WhiteTitle');
    final blackTitle = s('BlackTitle');
    final whiteRating = s('WhiteElo');
    final blackRating = s('BlackElo');
    final event = s('Event');
    final round = s('Round');
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

    return LibraryGameContextMenu(
      analysis: a,
      canDelete: widget.canDelete,
      useLongPress: false,
      onAction: widget.onAction,
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
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
                  color:
                      _selected
                          ? kPrimaryColor.withValues(alpha: 0.18)
                          : (_hovered
                              ? kBlack3Color.withValues(alpha: 0.55)
                              : null),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: _kColNumber,
                        child: Text(
                          widget.index.toString(),
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: kLightGreyColor,
                            fontSize: 11,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: _kColW,
                        child: _PlayerCell(
                          name: whiteName,
                          federation: whiteFed,
                          title: whiteTitle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: _kColElo,
                        child: _RatingCell(rating: whiteRating),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: _kColResult,
                        child: _ResultPill(result: result),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: _kColB,
                        child: _PlayerCell(
                          name: blackName,
                          federation: blackFed,
                          title: blackTitle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: _kColElo,
                        child: _RatingCell(rating: blackRating),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: _kColEvent,
                        child: Text(
                          eventLine.isEmpty ? '—' : eventLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(width: _kColEco, child: _EcoCell(eco: eco)),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: _kColDate,
                        child: Text(
                          _displayGameDate(s('Date')),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 11,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: _kColSaved,
                        child: Text(
                          _relativeTime(a.updatedAt),
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
        ),
      ),
    );
  }
}

class _PlayerCell extends StatelessWidget {
  const _PlayerCell({
    required this.name,
    required this.federation,
    required this.title,
    this.rating = '',
  });

  final String name;
  final String federation;
  final String title;
  final String rating;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        FederationFlag(
          federation: federation.isEmpty ? null : federation,
          width: 18,
          height: 13,
          borderRadius: BorderRadius.circular(2),
        ),
        const SizedBox(width: 8),
        if (title.isNotEmpty) ...[
          Text(
            title,
            style: const TextStyle(
              color: kLightYellowColor,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 5),
        ],
        Expanded(
          child: Text(
            name.isEmpty ? '—' : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (rating.trim().isNotEmpty) ...[
          const SizedBox(width: 6),
          Text(
            rating.trim(),
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

class _RatingCell extends StatelessWidget {
  const _RatingCell({required this.rating});

  final String rating;

  @override
  Widget build(BuildContext context) {
    return Text(
      rating.trim().isEmpty ? '—' : rating.trim(),
      textAlign: TextAlign.right,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: kWhiteColor70,
        fontSize: 11,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _EcoCell extends StatelessWidget {
  const _EcoCell({required this.eco});

  final String eco;

  @override
  Widget build(BuildContext context) {
    final value = eco.trim();
    if (value.isEmpty) {
      return const Text(
        '—',
        style: TextStyle(color: kLightGreyColor, fontSize: 11),
      );
    }
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: kDividerColor),
      ),
      child: Text(
        value,
        style: const TextStyle(
          color: kWhiteColor,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ResultPill extends StatelessWidget {
  const _ResultPill({required this.result});
  final String result;

  @override
  Widget build(BuildContext context) {
    final r = result.trim();
    final (label, color) = switch (r) {
      '1-0' => ('1 – 0', kWhiteColor),
      '0-1' => ('0 – 1', kWhiteColor),
      '1/2-1/2' || '½-½' => ('½ – ½', kWhiteColor70),
      '*' => ('•', kGreenColor),
      _ => ('—', kLightGreyColor),
    };
    return Center(
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

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
  final value = raw.trim();
  if (value.isEmpty || value == '?') return '—';
  final parts = value.split('.');
  if (parts.length == 3) {
    final year = parts[0];
    final month = parts[1];
    final day = parts[2];
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

void _openLocalPreviewGame(
  WidgetRef ref,
  LocalChessGame localGame, {
  required String databaseTitle,
  required List<LocalChessGame> databaseGames,
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
      for (final game in databaseGames) _summaryFromLocalPreviewGame(game),
    ],
    gameListSelectedId: localGame.id,
    librarySaveOrigin: BoardTabLibrarySaveOrigin.localPgnFile(
      sourcePath: localGame.sourcePath,
      sourceIndex: localGame.indexInFile,
      sourceFileGameCount: localGame.fileGameCount,
      title: localGame.title,
    ),
  );
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
  );
  if (draft == null) return;
  try {
    await ref
        .read(libraryRepositoryProvider)
        .createFolder(name: draft.name, parentId: draft.parentId);
    ref.invalidate(libraryFoldersStreamProvider);
    ref.invalidate(subscribedBooksProvider);
    if (!context.mounted) return;
    _toast(context, 'Folder "${draft.name}" created');
  } catch (e, st) {
    ErrorReporter.report(e, stackTrace: st, tag: 'library.create_folder');
    if (!context.mounted) return;
    _toast(context, 'Failed to create folder. Please try again.', error: true);
  }
}

Future<void> _pickAndImportFilesToFolder({
  required BuildContext context,
  required WidgetRef ref,
  required LibraryFolder folder,
}) async {
  if (!isWritableLibraryFolder(folder)) {
    _toast(context, '"${folder.name}" is read-only.', error: true);
    return;
  }
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Add to My Database',
    type: FileType.custom,
    allowedExtensions: localChessPickerExtensions,
    allowMultiple: true,
    withData: false,
    lockParentWindow: true,
  );
  if (result == null || result.files.isEmpty) return;
  final paths = result.files
      .map((file) => file.path)
      .whereType<String>()
      .where((path) => path.isNotEmpty)
      .toList(growable: false);
  if (paths.isEmpty) return;
  if (!context.mounted) return;
  await quickImportPathsToFolder(
    context: context,
    ref: ref,
    folder: folder,
    paths: paths,
  );
}

Future<void> _onFolderAction({
  required BuildContext context,
  required WidgetRef ref,
  required LibraryFolder folder,
  required LibraryFolderAction action,
  required List<LibraryFolder> allFolders,
}) async {
  switch (action) {
    case LibraryFolderAction.addToMyDatabase:
      await _pickAndImportFilesToFolder(
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
    case LibraryFolderAction.newSubfolder:
      await _onCreateFolder(
        context: context,
        ref: ref,
        folders: allFolders,
        lockedParent: folder,
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
    _toast(context, 'Folder "${folder.name}" deleted');
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

  final dialogFuture = showDialog<void>(
    context: context,
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
                : 'Searchable master archive')
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
          const FDivider(),
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
  final summaries = ref
      .read(gamebaseDatabaseGamesPaginatedProvider)
      .games
      .map(TournamentGameSummary.fromGamesTourModel)
      .toList(growable: false);
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
    databaseTitle: 'TWIC',
    databaseGames: summaries,
    databaseGamesContinuation: const BoardTabGamesContinuation.twicDatabase(),
    gameListSelectedId: game.gameId,
  );
}

enum _TwicGameContextAction {
  open,
  openNewTab,
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
        sourceLabel: 'TWIC',
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: kPrimaryColor.withValues(alpha: 0.40)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline_rounded, size: 10, color: kPrimaryColor),
          SizedBox(width: 5),
          Text(
            'System database',
            style: TextStyle(
              color: kPrimaryColor,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 10),
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
          const SizedBox(width: 12),
          _ViewModeToggle(value: viewMode, onChanged: onViewModeChanged),
          const SizedBox(width: 12),
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
                  const Icon(Icons.tune_rounded, size: 13),
                  const SizedBox(width: 6),
                  const Text('Filters'),
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
            const SizedBox(width: 8),
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
            label: aggregate.event,
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

class _TwicChipState extends State<_TwicChip> {
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
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
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
                  aggregate.event,
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
                          selectedGameIds?.contains(game.gameId) ??
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

const double _kTwicColDate = 88.0;

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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: kBlack3Color.withValues(alpha: 0.4),
      child: Row(
        children: [
          Expanded(flex: _kColW, child: label('White')),
          const SizedBox(width: 12),
          SizedBox(width: _kColResult, child: Center(child: label('Result'))),
          const SizedBox(width: 12),
          Expanded(flex: _kColB, child: label('Black')),
          const SizedBox(width: 12),
          Expanded(flex: _kColEvent, child: label('Event')),
          const SizedBox(width: 12),
          SizedBox(width: _kColEco, child: label('ECO')),
          const SizedBox(width: 12),
          SizedBox(
            width: _kTwicColDate,
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

class _TwicTableRowState extends State<_TwicTableRow> {
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
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
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
              decoration: BoxDecoration(
                color:
                    widget.selected
                        ? kPrimaryColor.withValues(alpha: 0.20)
                        : (_hovered
                            ? kBlack3Color.withValues(alpha: 0.55)
                            : null),
                border: const Border(
                  bottom: BorderSide(color: kDividerColor, width: 1),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    flex: _kColW,
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
                  const SizedBox(width: 12),
                  SizedBox(
                    width: _kColResult,
                    child: _ResultPill(result: result),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: _kColB,
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
                  const SizedBox(width: 12),
                  Expanded(
                    flex: _kColEvent,
                    child: Text(
                      game.tourId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kWhiteColor, fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: _kColEco,
                    child:
                        eco.isEmpty
                            ? const Text(
                              '—',
                              style: TextStyle(
                                color: kLightGreyColor,
                                fontSize: 11,
                              ),
                            )
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
                  const SizedBox(width: 12),
                  SizedBox(
                    width: _kTwicColDate,
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
  if (date == null) return '—';
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
          DatabaseWorkspaceSource.twic => const _TwicDatabaseWorkspace(),
          DatabaseWorkspaceSource.folder => _FolderDatabaseWorkspace(
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
const double _kLocalMiniPreviewRowExtent = 40.0;

typedef _DatabaseWorkspaceKeyAction = bool Function();

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

class _LocalDatabaseWorkspace extends ConsumerWidget {
  const _LocalDatabaseWorkspace({required this.tabId, required this.args});

  final String tabId;
  final DatabaseWorkspaceArgs args;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localPath = args.localPath;
    if (localPath == null || localPath.isEmpty) {
      return const _LibraryEmpty(
        icon: Icons.table_chart_outlined,
        title: 'Local database not available',
        message: 'Open the local database again from the Library home.',
      );
    }

    void selectPath(String path) {
      ref.read(localChessLibraryProvider.notifier).selectPath(path);
      final state = ref.read(localChessLibraryProvider);
      final title = localDatabaseWorkspaceTitle(state.source, path);
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

    return LocalChessFilesView(
      selectedPath: localPath,
      onSelectPath: selectPath,
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

class _FolderDatabaseWorkspace extends HookConsumerWidget {
  const _FolderDatabaseWorkspace({required this.args});

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

    void pasteIntoWorkspaceFolder() {
      if (args.isSubscribed) {
        showDesktopToast(context, '"${args.title}" is read-only.', error: true);
        return;
      }
      unawaited(
        quickImportClipboardToFolder(
          context: context,
          ref: ref,
          folder: _workspaceFolderFromArgs(args),
        ).then((count) {
          if (count > 0) refreshNonce.value++;
        }),
      );
    }

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
  const _TwicDatabaseWorkspace();

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
              title: 'TWIC',
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
            _GamesTableHeader(sort: sort, onSortChange: onSortChange),
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
                          selectedIds?.contains(rows[i].id) ??
                          rows[i].id == selectedId,
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
    this.onRangeSelect,
    required this.onSelect,
    required this.onOpen,
  });

  final int index;
  final SavedAnalysis analysis;
  final bool selected;
  final VoidCallback? onRangeSelect;
  final VoidCallback onSelect;
  final VoidCallback onOpen;

  @override
  State<_DatabaseSavedGameRow> createState() => _DatabaseSavedGameRowState();
}

class _DatabaseSavedGameRowState extends State<_DatabaseSavedGameRow> {
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
    final whiteTitle = s('WhiteTitle');
    final blackTitle = s('BlackTitle');
    final whiteRating = s('WhiteElo');
    final blackRating = s('BlackElo');
    final event = s('Event');
    final round = s('Round');
    final eco = s('ECO');
    final result = s('Result');
    final saved = _formatSavedDate(a.updatedAt);
    final eventLine =
        round.isNotEmpty && round != '?'
            ? (event.isEmpty ? 'Round $round' : '$event · R$round')
            : event;

    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
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
              decoration: BoxDecoration(
                color:
                    widget.selected
                        ? kPrimaryColor.withValues(alpha: 0.20)
                        : (_hovered
                            ? kBlack3Color.withValues(alpha: 0.55)
                            : null),
                border: const Border(
                  bottom: BorderSide(color: kDividerColor, width: 1),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: _kColNumber,
                    child: Text(
                      widget.index.toString(),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: kLightGreyColor,
                        fontSize: 11,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: _kColW,
                    child: _PlayerCell(
                      name: whiteName,
                      federation: whiteFed,
                      title: whiteTitle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: _kColElo,
                    child: _RatingCell(rating: whiteRating),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: _kColResult,
                    child: _ResultPill(result: result),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: _kColB,
                    child: _PlayerCell(
                      name: blackName,
                      federation: blackFed,
                      title: blackTitle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: _kColElo,
                    child: _RatingCell(rating: blackRating),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: _kColEvent,
                    child: Text(
                      eventLine.isEmpty ? '—' : eventLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(width: _kColEco, child: _EcoCell(eco: eco)),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: _kColDate,
                    child: Text(
                      _displayGameDate(s('Date')),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 11,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: _kColSaved,
                    child: Text(
                      saved,
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
    required this.plyIndex,
    required this.onPlyChanged,
    required this.onOpen,
  });

  final LocalChessGame? game;
  final int plyIndex;
  final ValueChanged<int> onPlyChanged;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final localGame = game;
    if (localGame == null) return const _EmptyDatabasePreview();
    return _LibraryChessGamePreviewPanel(
      game: _previewChessGameFromLocalGame(localGame),
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
  bool _flipped = false;

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
                    isFlipped: _flipped,
                    onFlip: () => setState(() => _flipped = !_flipped),
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
  final white = s('White');
  final black = s('Black');
  if (white.isNotEmpty || black.isNotEmpty) {
    return _PreviewPlayerLine(
      white: white.isEmpty ? 'White' : white,
      black: black.isEmpty ? 'Black' : black,
    );
  }
  final parts = fallbackTitle.split(
    RegExp(r'\s+v(?:s\.?|\.)\s+', caseSensitive: false),
  );
  if (parts.length >= 2) {
    return _PreviewPlayerLine(
      white: parts.first.trim(),
      black: parts[1].trim(),
    );
  }
  return const _PreviewPlayerLine(white: 'White', black: 'Black');
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(child: _PreviewPlayerName(name: whiteName, alignRight: true)),
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
        Flexible(child: _PreviewPlayerName(name: blackName, alignRight: false)),
      ],
    );
  }
}

class _PreviewGameMeta extends StatelessWidget {
  const _PreviewGameMeta({required this.game, required this.fallbackTitle});

  final ChessGame game;
  final String fallbackTitle;

  @override
  Widget build(BuildContext context) {
    final md = game.metadata;
    String s(String key) => (md[key]?.toString() ?? '').trim();
    final event = s('Event').isEmpty ? fallbackTitle.trim() : s('Event');
    final date = _displayGameDate(s('Date'));
    final pieces = <String>[if (event.isNotEmpty) event, if (date != '—') date];
    if (pieces.isEmpty) return const SizedBox.shrink();
    return Text(
      pieces.join('  ·  '),
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
    required this.isFlipped,
    required this.onFlip,
  });

  final String fen;
  final String? lastMoveUci;
  final BoardSettingsNew settings;
  final bool isFlipped;
  final VoidCallback onFlip;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(constraints.maxWidth, constraints.maxHeight);
        final orientation = isFlipped ? Side.black : Side.white;
        return Center(
          child: SizedBox.square(
            dimension: side,
            child: Stack(
              children: [
                cg.Chessboard.fixed(
                  key: ValueKey<String>(
                    'library-preview-board:$fen:${lastMoveUci ?? ''}:$orientation',
                  ),
                  size: side,
                  fen: fen,
                  orientation: orientation,
                  settings: cg.ChessboardSettings(
                    enableCoordinates: false,
                    colorScheme: settings.colorScheme,
                    pieceAssets: settings.pieceAssets,
                  ),
                  shapes: const ISet<cg.Shape>.empty(),
                  lastMove: _uciToLastMove(lastMoveUci ?? ''),
                ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: DesktopTooltip(
                    message: isFlipped ? 'Show White side' : 'Show Black side',
                    child: ClickCursor(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onFlip,
                        child: Container(
                          width: 28,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: kBlack2Color.withValues(alpha: 0.86),
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                              color: kWhiteColor.withValues(alpha: 0.18),
                            ),
                          ),
                          child: Icon(
                            Icons.flip_camera_android_rounded,
                            size: 15,
                            color: isFlipped ? kPrimaryColor : kWhiteColor70,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
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
