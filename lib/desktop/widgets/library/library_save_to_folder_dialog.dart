import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../../services/board_save_boundary.dart';
import '../../state/active_board_game.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/desktop/services/library_folder_create_guard.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_database_save_source.dart';
import 'package:chessever/desktop/services/library_save_destination_recency.dart';
import 'package:chessever/desktop/services/local_library_game_updater.dart';
import 'package:chessever/desktop/services/local_library_writer.dart';
import 'package:chessever/desktop/services/local_source_deletion.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/desktop/state/my_databases_focus.dart';
import 'package:chessever/desktop/widgets/library/library_save_section.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_tappable.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/library/library_folder_dialogs.dart';
import 'package:chessever/utils/save_to_library_guard.dart';
import 'package:chessever/repository/freemium/freemium_quota.dart';
import 'package:chessever/utils/freemium_quota_guard.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/library/providers/library_folders_provider.dart';
import 'package:chessever/theme/app_theme.dart';

/// Outcome reported back to the caller of [showLibrarySaveToFolderDialog].
class LibrarySaveOutcome {
  const LibrarySaveOutcome({
    required this.savedRows,
    required this.folderCount,
    this.localFilesWritten = 0,
    this.localFoldersUsed = 0,
    this.didUpdateOriginal = false,
    this.localUpdateTarget,
    this.cloudUpdateTarget,
    this.committedGame,
    this.newDatabaseNames = const <String>[],
  });

  /// Number of rows written to the cloud `saved_analyses` table.
  final int savedRows;

  /// Number of cloud folders that received at least one row.
  final int folderCount;

  /// Number of games written to disk across local destinations.
  final int localFilesWritten;

  /// Number of local destinations that received at least one game.
  final int localFoldersUsed;

  /// True when the caller updated the source library game rather than saving a
  /// new copy into another destination.
  final bool didUpdateOriginal;

  /// Newly appended local PGN record that this game can update on its next
  /// save. Null for cloud saves, folder exports, bulk saves, and ambiguous
  /// multi-destination saves.
  final LocalLibraryGameUpdateTarget? localUpdateTarget;

  /// Exact inserted row, only for one game / one cloud / no local destinations.
  final BoardTabLibrarySaveOrigin? cloudUpdateTarget;

  /// Exact single-game snapshot supplied to the successful writer, including
  /// metadata edited in this dialog. Never reconstructed after the await.
  final ChessGame? committedGame;

  /// Names of the cloud databases this save created, one per destination
  /// folder. Only a local-database save to the cloud creates databases, so the
  /// list is empty for every other flow.
  final List<String> newDatabaseNames;

  /// Total entries persisted across cloud + local destinations.
  int get totalEntries => savedRows + localFilesWritten;

  bool get didSave => didUpdateOriginal || totalEntries > 0;

  /// Toast-friendly summary, e.g. "Saved 3 entries to the cloud library" or
  /// "Saved 2 entries locally · 1 entry to the cloud library".
  String toToastMessage() {
    if (didUpdateOriginal) return 'Updated existing game';
    final parts = <String>[];
    if (savedRows > 0) {
      final cloudTarget =
          newDatabaseNames.isEmpty
              ? 'the cloud library'
              : newDatabaseNames.length == 1
              ? 'new database "${newDatabaseNames.single}"'
              : '${newDatabaseNames.length} new databases';
      parts.add(
        '$savedRows ${savedRows == 1 ? 'entry' : 'entries'} to $cloudTarget',
      );
    }
    if (localFilesWritten > 0) {
      final destinationHint =
          localFoldersUsed > 1
              ? ' across $localFoldersUsed local destinations'
              : '';
      parts.add(
        '$localFilesWritten ${localFilesWritten == 1 ? 'entry' : 'entries'} '
        'on this computer$destinationHint',
      );
    }
    if (parts.isEmpty) return 'Nothing saved.';
    return 'Saved ${parts.join(' · ')}';
  }
}

@visibleForTesting
LocalLibraryGameUpdateTarget? libraryLocalUpdateTargetForCompletedSave({
  required int gameCount,
  required int selectedCloudFolderCount,
  required int selectedLocalPathCount,
  required List<LocalLibraryWriteOutcome> outcomes,
}) {
  if (gameCount != 1 ||
      selectedCloudFolderCount != 0 ||
      selectedLocalPathCount != 1 ||
      outcomes.length != 1) {
    return null;
  }
  final targets = outcomes.single.updateTargets;
  return targets.length == 1 ? targets.single : null;
}

@visibleForTesting
BoardTabLibrarySaveOrigin? libraryCloudUpdateTargetForCompletedSave({
  required int gameCount,
  required int selectedCloudFolderCount,
  required int selectedLocalPathCount,
  required BoardTabLibrarySaveOrigin? insertedOrigin,
}) => gameCount == 1 && selectedCloudFolderCount == 1 &&
    selectedLocalPathCount == 0 ? insertedOrigin : null;

/// Ids of the destination databases a failed save must remove again.
///
/// A save creates its destination database(s) *before* the first game row, so a
/// failure that lands **zero** rows — the batch carrying an impossible date like
/// `2005.06.31` is rejected as a whole — would otherwise leave an empty
/// same-name database in the library that refuses every retry by name. Only the
/// nodes this very call created are returned, and only while nothing at all was
/// written: a save that already landed rows keeps them and does not retry
/// silently.
@visibleForTesting
List<String> libraryFailedSaveEmptyCloudDatabaseIds({
  required Iterable<String> createdNodeIds,
  required int savedRows,
  required int localFilesWritten,
}) {
  if (savedRows > 0 || localFilesWritten > 0) return const <String>[];
  return List<String>.unmodifiable(createdNodeIds);
}

/// Retain a durable outcome even if a route is forcibly removed while busy.
@visibleForTesting
Future<LibrarySaveOutcome?> waitForLibrarySaveOutcome(
  Future<LibrarySaveOutcome?> route,
  List<Future<void>> pendingWrites,
  LibrarySaveOutcome? Function() committedOutcome,
) async {
  final result = await waitForSaveDialogWrites(route, pendingWrites);
  return committedOutcome() ?? result;
}

class LibraryUpdateTarget {
  const LibraryUpdateTarget({
    required this.title,
    required this.subtitle,
    required this.onUpdate,
  });

  final String title;
  final String subtitle;
  final Future<void> Function(ChessGame game) onUpdate;
}

enum LibrarySaveDestinationMode { cloudAndLocal, cloudOnly, localOnly }

@visibleForTesting
bool librarySaveAllowsCloudDestinations(LibrarySaveDestinationMode mode) =>
    mode != LibrarySaveDestinationMode.localOnly;

@visibleForTesting
bool librarySaveAllowsLocalDestinations(LibrarySaveDestinationMode mode) =>
    mode != LibrarySaveDestinationMode.cloudOnly;

@visibleForTesting
String librarySaveDialogTitle(LibrarySaveDestinationMode mode) {
  return switch (mode) {
    LibrarySaveDestinationMode.cloudOnly => 'Save database to cloud',
    LibrarySaveDestinationMode.localOnly => 'Save to this computer',
    LibrarySaveDestinationMode.cloudAndLocal => 'Save to library',
  };
}

@visibleForTesting
List<LibraryFolder> librarySaveWritableCloudFolders({
  required List<LibraryFolder> folders,
  required LibrarySaveDestinationMode destinationMode,
  bool foldersOnly = false,
}) {
  if (!librarySaveAllowsCloudDestinations(destinationMode)) {
    return const <LibraryFolder>[];
  }
  // A local-database save creates a database inside the chosen container, so
  // only containers (folders) are offered as destinations — a database holds
  // games only and is never a valid place for a new database, and picking one
  // must not be read as "put these games in that database".
  final candidates =
      foldersOnly
          ? folders
                .where(
                  (folder) => !libraryCloudNodeIsDatabase(folder, folders),
                )
                .toList(growable: false)
          : folders;
  // The Likes collection is written only by the like toggle. Saving into it
  // here would create a like outside the Likes policy (flag, never name).
  return candidates
      .where((folder) => !folder.isSubscribed && !folder.isLikedGames)
      .toList(growable: false);
}

/// The destination containers a "save as a new cloud database" writes into,
/// one entry per distinct parent.
///
/// A selected folder is its own parent; a selected database node retargets to
/// the folder that holds it, because a database holds games only and the server
/// rejects child inserts under one that already has games. Selecting a folder
/// and its own database therefore resolves to the same parent and creates a
/// single database, never a duplicate.
@visibleForTesting
List<LibraryFolder?> libraryNewDatabaseParents({
  required List<LibraryFolder> selected,
  required List<LibraryFolder> allFolders,
}) {
  final parents = <String, LibraryFolder?>{};
  for (final folder in selected) {
    final target = libraryChildCreateTarget(
      current: folder,
      folders: allFolders,
      currentIsDatabase: libraryCloudNodeIsDatabase(folder, allFolders),
    );
    parents.putIfAbsent(target.parent?.id ?? '', () => target.parent);
  }
  return parents.values.toList(growable: false);
}

@visibleForTesting
LibraryFolder? librarySaveFolderById(
  List<LibraryFolder> folders,
  String? id,
) {
  if (id == null) return null;
  for (final folder in folders) {
    if (folder.id == id) return folder;
  }
  return null;
}

/// Resolve existing user pin keys only, in their persisted order. Never infer
/// system/generated identity from a display name. Group pins are not databases.
@visibleForTesting
List<String> librarySavePinnedDestinationKeys({
  required List<String> orderedPinKeys,
  required List<LibraryFolder> folders,
  required List<LocalLibraryEntry> localEntries,
  required LibrarySaveDestinationMode destinationMode,
}) {
  final eligible = <String>{
    for (final folder in librarySaveWritableCloudFolders(
      folders: folders,
      destinationMode: destinationMode,
    ))
      if (folder.id != kTwicBookId &&
          folder.userId.isNotEmpty &&
          folder.icon != 'twic' &&
          folder.icon != 'folder_container')
        libraryCloudDatabasePinKey(folder.id),
    if (librarySaveAllowsLocalDestinations(destinationMode))
      for (final entry in localEntries)
        if (entry.playerWorkspaceSource == null &&
            playerWorkspaceIdFromLocalLibraryGroupId(entry.groupId) == null &&
            p.extension(entry.path).toLowerCase() == '.pgn')
          libraryLocalDatabasePinKey(entry.path),
  };
  return orderedPinKeys.where(eligible.remove).toList(growable: false);
}

/// Forui-styled "Save to folder(s)" dialog. Shows the user's writable
/// folders as multi-select rows, supports inline create, and writes the
/// supplied [games] into every selected folder as library entries via
/// `LibraryRepository.createSavedAnalysesBulk` (the same pipeline mobile
/// uses for clipboard / file imports).
///
/// A whole local database is handed over as a [gameSource] instead of a
/// materialized list, so the dialog writes one bounded batch at a time and a
/// 78 000-game database is never resident in memory.
///
/// Returns a [LibrarySaveOutcome] describing what was written, or `null`
/// if the user dismissed the dialog without saving.
Future<LibrarySaveOutcome?> showLibrarySaveToFolderDialog({
  required BuildContext context,
  required WidgetRef ref,
  List<ChessGame> games = const <ChessGame>[],
  LibrarySaveGameSource? gameSource,
  String? suggestedFolderId,
  String? sourceLabel,
  LibraryUpdateTarget? updateTarget,
  LibrarySaveDestinationMode destinationMode =
      LibrarySaveDestinationMode.cloudAndLocal,
  String? newDatabaseName,
}) async {
  final gameCount = gameSource?.totalCount ?? games.length;
  if (gameCount <= 0) return null;
  assert(
    gameSource == null || games.isEmpty,
    'A save takes either materialized `games` or a `gameSource`, not both.',
  );
  assert(
    gameSource == null ||
        destinationMode == LibrarySaveDestinationMode.cloudOnly,
    'A paged game source is a whole-database cloud save; it has no local '
    'destination to write to.',
  );
  // A dismissed route does not cancel a durable write. Keep the caller's save
  // boundary alive until every started operation has actually settled.
  final pendingWrites = <Future<void>>[];
  LibrarySaveOutcome? committedOutcome;
  final route = showGeneralDialog<LibrarySaveOutcome>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Save to folder',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder:
        (ctx, _, _) => _SaveToFolderDialog(
          ref: ref,
          games: games,
          gameSource: gameSource,
          sourceLabel: sourceLabel ?? 'imported',
          onWriteStarted: pendingWrites.add,
          onCommitted: (outcome) => committedOutcome = outcome,
          suggestedFolderId: suggestedFolderId,
          newDatabaseName: newDatabaseName,
          updateTarget: updateTarget,
          destinationMode: destinationMode,
        ),
    transitionBuilder: (ctx, anim, _, child) {
      final eased = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: eased,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.02),
            end: Offset.zero,
          ).animate(eased),
          child: child,
        ),
      );
    },
  );
  return waitForLibrarySaveOutcome(route, pendingWrites, () => committedOutcome);
}

class _SaveToFolderDialog extends ConsumerStatefulWidget {
  const _SaveToFolderDialog({
    required this.ref,
    required this.games,
    required this.sourceLabel,
    required this.suggestedFolderId,
    required this.newDatabaseName,
    required this.onWriteStarted,
    required this.onCommitted,
    required this.updateTarget,
    required this.destinationMode,
    this.gameSource,
  });

  final WidgetRef ref;
  final void Function(Future<void>) onWriteStarted;
  final void Function(LibrarySaveOutcome) onCommitted;
  final List<ChessGame> games;

  /// Paged whole-database source. When set, [games] is empty and every write
  /// pulls one bounded batch instead of a materialized list.
  final LibrarySaveGameSource? gameSource;
  final String sourceLabel;
  final String? suggestedFolderId;

  /// When set, this save creates a *new* cloud database with this name inside
  /// every chosen destination folder instead of writing into an existing node.
  final String? newDatabaseName;

  final LibraryUpdateTarget? updateTarget;
  final LibrarySaveDestinationMode destinationMode;

  @override
  ConsumerState<_SaveToFolderDialog> createState() =>
      _SaveToFolderDialogState();
}

class _SaveToFolderDialogState extends ConsumerState<_SaveToFolderDialog> {
  static const _recencyStore = LibrarySaveDestinationRecencyStore();

  final Set<String> _selected = <String>{};
  final Set<String> _selectedLocalPaths = <String>{};
  bool _isSaving = false;
  int _savedRows = 0;
  int _localWritten = 0;
  bool _isUpdatingOriginal = false;
  bool _isDeletingLocalDestination = false;

  /// Cloud databases this dialog's own save created, by id and by name.
  ///
  /// The destination database is inserted *before* the first game row and
  /// `user_folders` is streamed over realtime, so the node this save is
  /// filling reaches the live folder list while its rows are still
  /// streaming. Excluding it is what keeps the name hint below from
  /// reporting that save's own database as a pre-existing clash.
  final Set<String> _createdCloudNodeIds = <String>{};
  final Set<String> _createdCloudNodeNames = <String>{};

  /// Nodes this dialog created and then removed again: the empty destination
  /// database of a save that failed before a single row landed. The live folder
  /// list can still carry such a node for a moment after the delete, and it
  /// must not be read as a pre-existing name clash on a retry.
  final Set<String> _removedCloudNodeIds = <String>{};

  /// Destination databases this dialog created whose attempt has not written a
  /// row yet, keyed by the create parent (`''` = library top level).
  ///
  /// A failed attempt removes its node again (see
  /// [_removeEmptyCloudDatabasesFromFailedSave]); an entry survives only when
  /// that removal failed, and it is what lets the next attempt fill the same
  /// database instead of being refused by `UNIQUE (user_id, name)`.
  final List<_PendingCloudDatabase> _pendingCloudDatabases =
      <_PendingCloudDatabase>[];

  /// Ids of the cloud nodes this dialog created for its own saves, whether they
  /// are still there (a failed attempt's cleanup did not complete) or already
  /// removed again (the folder list lags behind the delete).
  Set<String> get _ownCloudNodeIds => <String>{
    ..._createdCloudNodeIds,
    ..._removedCloudNodeIds,
    for (final pending in _pendingCloudDatabases) pending.id,
  };

  /// Only allocated when [widget.newDatabaseName] is set: the name edited for
  /// the cloud database this save creates.
  TextEditingController? _newDatabaseNameCtrl;
  LibrarySaveDestinationRecency _destinationRecency =
      const LibrarySaveDestinationRecency();

  // Single-game metadata editor. Only allocated when [widget.games] holds
  // exactly one game, since editing 200 PGN headers from one form does not
  // make sense for bulk imports.
  late bool _showGameDetails;
  late final bool _supportsMetadataEdit;
  TextEditingController? _whiteSurnameCtrl;
  TextEditingController? _whiteFirstNameCtrl;
  TextEditingController? _blackSurnameCtrl;
  TextEditingController? _blackFirstNameCtrl;
  TextEditingController? _eventCtrl;
  TextEditingController? _ecoCtrl;
  TextEditingController? _whiteEloCtrl;
  TextEditingController? _blackEloCtrl;
  TextEditingController? _roundCtrl;
  TextEditingController? _subroundCtrl;
  TextEditingController? _yearCtrl;
  TextEditingController? _monthCtrl;
  TextEditingController? _dayCtrl;
  String _selectedResult = '*';

  @override
  void initState() {
    super.initState();
    if (widget.destinationMode != LibrarySaveDestinationMode.localOnly &&
        widget.suggestedFolderId != null) {
      _selected.add(widget.suggestedFolderId!);
    }
    if (widget.newDatabaseName != null) {
      _newDatabaseNameCtrl = TextEditingController(
        text: widget.newDatabaseName!.trim(),
      );
    }
    _supportsMetadataEdit = widget.games.length == 1;
    // Existing-library saves are usually quick "update this game" actions.
    // Keep metadata available, but collapsed until the user explicitly wants
    // to edit details before clicking Update existing game.
    _showGameDetails = widget.updateTarget == null;
    if (_supportsMetadataEdit) {
      _seedMetadataControllers(widget.games.first.metadata);
    }
    unawaited(_loadDestinationRecency());
  }

  Future<void> _loadDestinationRecency() async {
    final recency = await _recencyStore.load();
    if (!mounted) return;
    setState(() => _destinationRecency = recency);
  }

  void _seedMetadataControllers(Map<String, dynamic> metadata) {
    final whiteParts = splitPlayerName(metadata['White']?.toString());
    final blackParts = splitPlayerName(metadata['Black']?.toString());
    _whiteSurnameCtrl = TextEditingController(text: whiteParts.surname);
    _whiteFirstNameCtrl = TextEditingController(text: whiteParts.firstName);
    _blackSurnameCtrl = TextEditingController(text: blackParts.surname);
    _blackFirstNameCtrl = TextEditingController(text: blackParts.firstName);
    _eventCtrl = TextEditingController(
      text: libraryGameDetailInputValue(metadata['Event']),
    );
    _ecoCtrl = TextEditingController(
      text: libraryGameDetailInputValue(metadata['ECO']),
    );
    _whiteEloCtrl = TextEditingController(
      text: libraryGameDetailInputValue(metadata['WhiteElo']),
    );
    _blackEloCtrl = TextEditingController(
      text: libraryGameDetailInputValue(metadata['BlackElo']),
    );
    _roundCtrl = TextEditingController(
      text: libraryGameDetailInputValue(metadata['Round']),
    );
    _subroundCtrl = TextEditingController(
      text: libraryGameDetailInputValue(metadata['Subround']),
    );
    final dateParts = (metadata['Date']?.toString() ?? '').split('.');
    _yearCtrl = TextEditingController(
      text:
          (dateParts.isNotEmpty && dateParts[0] != '????') ? dateParts[0] : '',
    );
    _monthCtrl = TextEditingController(
      text: (dateParts.length > 1 && dateParts[1] != '??') ? dateParts[1] : '',
    );
    _dayCtrl = TextEditingController(
      text: (dateParts.length > 2 && dateParts[2] != '??') ? dateParts[2] : '',
    );
    final resultRaw = metadata['Result']?.toString().trim() ?? '';
    _selectedResult =
        kSupportedPgnResults.contains(resultRaw) ? resultRaw : '*';
  }

  @override
  void dispose() {
    _newDatabaseNameCtrl?.dispose();
    _whiteSurnameCtrl?.dispose();
    _whiteFirstNameCtrl?.dispose();
    _blackSurnameCtrl?.dispose();
    _blackFirstNameCtrl?.dispose();
    _eventCtrl?.dispose();
    _ecoCtrl?.dispose();
    _whiteEloCtrl?.dispose();
    _blackEloCtrl?.dispose();
    _roundCtrl?.dispose();
    _subroundCtrl?.dispose();
    _yearCtrl?.dispose();
    _monthCtrl?.dispose();
    _dayCtrl?.dispose();
    super.dispose();
  }

  /// Games this save covers.
  ///
  /// A paged whole-database source reports its own total, so the header, the
  /// destination row and the progress bar all describe the whole database
  /// rather than the page that happened to be loaded.
  int get _gameCount => librarySaveDialogGameCount(
    materializedCount: widget.games.length,
    sourceTotal: widget.gameSource?.totalCount,
  );

  List<ChessGame> _gamesForSave() {
    if (!_supportsMetadataEdit) return widget.games;
    final source = widget.games.first;
    final merged = buildEditedMetadata(
      original: source.metadata,
      whiteSurname: _whiteSurnameCtrl!.text,
      whiteFirstName: _whiteFirstNameCtrl!.text,
      blackSurname: _blackSurnameCtrl!.text,
      blackFirstName: _blackFirstNameCtrl!.text,
      event: _eventCtrl!.text,
      eco: _ecoCtrl!.text,
      whiteElo: _whiteEloCtrl!.text,
      blackElo: _blackEloCtrl!.text,
      round: _roundCtrl!.text,
      subround: _subroundCtrl!.text,
      result: _selectedResult,
      year: _yearCtrl!.text,
      month: _monthCtrl!.text,
      day: _dayCtrl!.text,
    );
    return [source.copyWith(metadata: merged)];
  }

  void _fillTodayDate() {
    final now = DateTime.now();
    setState(() {
      _yearCtrl!.text = now.year.toString();
      _monthCtrl!.text = now.month.toString().padLeft(2, '0');
      _dayCtrl!.text = now.day.toString().padLeft(2, '0');
    });
  }

  String _normalizeLocalPath(String path) {
    final normalized = p.normalize(path.trim());
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  Future<void> _onAddLocalPgnFile() async {
    if (_isSaving) return;
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose PGN file',
      type: FileType.custom,
      allowedExtensions: const ['pgn'],
      allowMultiple: false,
      withData: false,
      lockParentWindow: true,
    );
    final files = result?.files ?? const <PlatformFile>[];
    final filePath = files.isEmpty ? null : files.first.path;
    if (filePath == null || filePath.isEmpty || !mounted) return;
    final registry = ref.read(localLibraryRegistryProvider.notifier);
    final registeredPath = await registry.register(filePath);
    if (!mounted) return;
    setState(() {
      _selectedLocalPaths.add(_normalizeLocalPath(registeredPath));
    });
  }

  Future<void> _deleteLocalDestination(LocalLibraryEntry entry) async {
    if (_isSaving || _isUpdatingOriginal || _isDeletingLocalDestination) {
      return;
    }
    final key = _normalizeLocalPath(entry.path);
    setState(() => _isDeletingLocalDestination = true);
    try {
      final sourceDeleted = await deleteLocalSourcePath(entry.path);
      ref
          .read(localChessDatabaseRepositoryProvider)
          .scheduleCachedSourceDelete(sourcePath: entry.path);
      await ref
          .read(localLibraryRegistryProvider.notifier)
          .unregister(entry.path);
      final activeSource = ref.read(localChessLibraryProvider).source;
      if (activeSource != null && activeSource.paths.contains(entry.path)) {
        ref.read(localChessLibraryProvider.notifier).clear();
      }
      if (!mounted) return;
      setState(() {
        _selectedLocalPaths.remove(key);
      });
      _showToast(
        sourceDeleted
            ? 'Local database deleted from this computer.'
            : 'Local database removed. Source files were already gone.',
      );
    } catch (e) {
      if (!mounted) return;
      _showToast(
        'Could not delete local database from this computer: $e',
        error: true,
      );
    } finally {
      if (mounted) {
        setState(() => _isDeletingLocalDestination = false);
      }
    }
  }

  Future<void> _onCreateFolder(List<LibraryFolder> writableFolders) async {
    if (_isSaving || _isUpdatingOriginal) return;
    final draft = await showLibraryCreateFolderDialog(
      context,
      availableParents: writableFolders
          .where((f) => f.parentId == null)
          .toList(growable: false),
    );
    if (draft == null) return;
    final isDatabase = draft.kind == LibraryFolderCreateKind.database;
    final allFolders =
        ref.read(libraryFoldersStreamProvider).valueOrNull ??
        const <LibraryFolder>[];
    final parent = librarySaveFolderById(allFolders, draft.parentId);
    // `user_folders` carries UNIQUE(user_id, name) for the whole account, not
    // per folder. Catch the conflict here so the user gets an actionable message
    // instead of a 23505 mapped to `Duplicate entry`.
    if (libraryCloudNodeNamed(draft.name, allFolders) != null) {
      _showToast(libraryDuplicateCloudNodeMessage(draft.name), error: true);
      return;
    }
    // Folders are unlimited; only a new database asks for a slot.
    if (isDatabase) {
      if (!mounted) return;
      final quota = await requestFreemiumQuota(
        context,
        FreemiumQuotaKind.ownedDatabases,
      );
      if (!mounted) return;
      if (!quota.isAllowed) {
        _showToast(freemiumQuotaBlockedMessage(quota), error: true);
        return;
      }
    }
    try {
      final repo = ref.read(libraryRepositoryProvider);
      final created = await repo.createFolder(
        name: draft.name,
        parentId: draft.parentId,
        icon: isDatabase ? 'database' : 'folder_container',
        nodeType: isDatabase ? 'database' : 'folder',
      );
      ref.invalidate(libraryFoldersStreamProvider);
      ref.invalidate(subscribedBooksProvider);
      if (!mounted) return;
      setState(() => _selected.add(created.id));
    } catch (e) {
      if (!mounted) return;
      final rejection = freemiumQuotaRejection(
        e,
        fallbackKind: FreemiumQuotaKind.ownedDatabases,
      );
      // A rejected container insert is an expected server-side guard (a legacy
      // node the server still treats as a database, or an account-wide duplicate
      // name), so it is said in words rather than dumped as a raw database
      // error.
      final containerRejection = libraryCreateFolderRejectionMessage(
        e,
        name: draft.name,
        parentName: parent?.name,
      );
      _showToast(
        rejection != null
            ? freemiumQuotaBlockedMessage(rejection)
            : containerRejection ??
                  'Failed to create folder. Please try again.',
        error: true,
      );
    }
  }

  Future<void> _onUpdateOriginal() {
    final operation = _updateOriginal();
    widget.onWriteStarted(operation);
    return operation;
  }

  Future<void> _updateOriginal() async {
    final target = widget.updateTarget;
    if (_isSaving || _isUpdatingOriginal || target == null) return;
    setState(() => _isUpdatingOriginal = true);
    try {
      final committedGame = _gamesForSave().first;
      await target.onUpdate(committedGame);
      final outcome = LibrarySaveOutcome(
        committedGame: committedGame,
        savedRows: 0,
        folderCount: 0,
        didUpdateOriginal: true,
      );
      widget.onCommitted(outcome);
      if (!mounted) return;
      Navigator.of(context).pop(outcome);
    } catch (e) {
      if (!mounted) return;
      _showToast('Update failed: $e', error: true);
      setState(() => _isUpdatingOriginal = false);
    }
  }

  Future<void> _onSave(
    List<LibraryFolder> selectedFolders,
    List<String> selectedLocalPaths,
  ) {
    final operation = _save(selectedFolders, selectedLocalPaths);
    widget.onWriteStarted(operation);
    return operation;
  }

  /// Games for this save, one bounded batch at a time.
  ///
  /// A whole local database arrives as [widget.gameSource] and is pulled page
  /// by page, so peak memory stays at one batch instead of the database. Every
  /// other flow hands over an already materialized list and is yielded as a
  /// single batch, exactly as before.
  Stream<List<ChessGame>> _gameBatches(List<ChessGame> materialized) async* {
    final source = widget.gameSource;
    if (source == null) {
      if (materialized.isNotEmpty) yield materialized;
      return;
    }
    while (true) {
      final batch = await source.nextBatch();
      if (batch.isEmpty) return;
      yield batch;
    }
  }

  /// The destination database this dialog already created for [parentKey] under
  /// [name] and whose attempt has not landed a row, or `null`.
  _PendingCloudDatabase? _pendingCloudDatabaseFor(String parentKey, String name) {
    for (final pending in _pendingCloudDatabases) {
      if (pending.parentKey == parentKey && pending.name == name) {
        return pending;
      }
    }
    return null;
  }

  /// Removes the destination databases a just-failed save created when it wrote
  /// nothing at all.
  ///
  /// The destination database is created before the first game row, so a
  /// failure that lands no row — for example a batch the server rejects as a
  /// whole — would otherwise leave an empty same-name database behind that
  /// refuses every retry. Only nodes this very attempt created are passed in,
  /// and only while nothing was written anywhere. Returns the names that could
  /// not be removed: those databases stay usable, and the next attempt fills
  /// them instead of creating a second node.
  Future<List<String>> _removeEmptyCloudDatabasesFromFailedSave(
    List<String> createdNodeIds,
    LibraryRepository repo,
  ) async {
    final ids = libraryFailedSaveEmptyCloudDatabaseIds(
      createdNodeIds: createdNodeIds,
      savedRows: _savedRows,
      localFilesWritten: _localWritten,
    );
    if (ids.isEmpty) return const <String>[];
    final kept = <String>[];
    var removedAny = false;
    for (final id in ids) {
      final index = _pendingCloudDatabases.indexWhere(
        (pending) => pending.id == id,
      );
      final name = index < 0 ? '' : _pendingCloudDatabases[index].name;
      try {
        await repo.deleteFolder(id);
        removedAny = true;
        _removedCloudNodeIds.add(id);
        if (index >= 0) _pendingCloudDatabases.removeAt(index);
      } catch (_) {
        // A node that cannot be removed is not a dead end: keeping its entry is
        // what makes the next attempt fill it instead of creating a duplicate.
        if (name.isNotEmpty) kept.add(name);
      }
    }
    if (removedAny && mounted) {
      ref.invalidate(libraryFoldersStreamProvider);
      ref.invalidate(subscribedBooksProvider);
    }
    return kept;
  }

  /// Writes one batch of games into every folder in [folderIds], 250-row
  /// request chunks at a time, reporting progress after each chunk.
  ///
  /// Returns the number of rows written. Peak memory stays at the batch size,
  /// which is what lets a whole 78 000-game database be saved without ever
  /// being resident in memory.
  Future<int> _writeGamesBatch({
    required LibraryRepository repo,
    required String userId,
    required List<ChessGame> batch,
    required List<String> folderIds,
    required DateTime now,
    required void Function() onProgress,
  }) async {
    const chunkSize = 250;
    var written = 0;
    final rows = <SavedAnalysis>[
      for (final game in batch)
        for (final folderId in folderIds)
          SavedAnalysis(
            id: '',
            userId: userId,
            folderId: folderId,
            title: _titleFor(game),
            chessGame: game,
            analysisState: const {},
            variationComments: const {},
            lastViewedPosition: -1,
            tags: const [],
            isFavorite: false,
            createdAt: now,
            updatedAt: now,
          ),
    ];
    for (var i = 0; i < rows.length; i += chunkSize) {
      final end = math.min(i + chunkSize, rows.length);
      final chunk = rows.sublist(i, end);
      await repo.createSavedAnalysesBulk(chunk);
      written += chunk.length;
      _savedRows += chunk.length;
      onProgress();
      if (!mounted) return written;
      setState(() {});
    }
    return written;
  }

  Future<void> _save(
    List<LibraryFolder> selectedFolders,
    List<String> selectedLocalPaths,
  ) async {
    if (_isSaving || _isUpdatingOriginal) return;
    if (selectedFolders.isEmpty && selectedLocalPaths.isEmpty) return;

    final effectiveGames = _gamesForSave();
    final gameCount = _gameCount;
    final usesGameSource = widget.gameSource != null;
    if (usesGameSource && selectedLocalPaths.isNotEmpty) {
      // A paged source is a whole-database cloud save: it has no local
      // destination, and materializing it just to write PGN copies would
      // defeat the bounded-memory contract it exists for.
      _showToast(
        'Saving a whole local database only supports cloud destinations. '
        'Pick a folder instead.',
        error: true,
      );
      return;
    }
    var localFoldersUsed = 0;
    var cloudFoldersUsed = 0;
    final localWriteOutcomes = <LocalLibraryWriteOutcome>[];
    BoardTabLibrarySaveOrigin? insertedCloudOrigin;
    final newCloudDatabaseNames = <String>[];
    // Destination databases this attempt created. A failure that wrote no row
    // at all must remove them again (see the catch below): an empty same-name
    // database refuses every retry.
    final createdCloudDatabaseIds = <String>[];
    // Captured for the whole operation so the failed-save cleanup can still run
    // after the dialog was dismissed mid-save, when `ref` is no longer usable.
    final repo = ref.read(libraryRepositoryProvider);
    LibrarySaveOutcome? committedOutcome;
    void retainCommittedOutcome() {
      if (_savedRows == 0 && _localWritten == 0) return;
      committedOutcome = LibrarySaveOutcome(
        committedGame: effectiveGames.length == 1 ? effectiveGames.single : null,
        savedRows: _savedRows,
        folderCount: cloudFoldersUsed,
        localFilesWritten: _localWritten,
        localFoldersUsed: localFoldersUsed,
        cloudUpdateTarget: libraryCloudUpdateTargetForCompletedSave(
          gameCount: gameCount,
          selectedCloudFolderCount: selectedFolders.length,
          selectedLocalPathCount: selectedLocalPaths.length,
          insertedOrigin: insertedCloudOrigin,
        ),
        localUpdateTarget: libraryLocalUpdateTargetForCompletedSave(
          gameCount: gameCount,
          selectedCloudFolderCount: selectedFolders.length,
          selectedLocalPathCount: selectedLocalPaths.length,
          outcomes: localWriteOutcomes,
        ),
        newDatabaseNames: List<String>.unmodifiable(newCloudDatabaseNames),
      );
      widget.onCommitted(committedOutcome!);
    }

    setState(() {
      _isSaving = true;
      _savedRows = 0;
      _localWritten = 0;
    });
    try {
      // Claim the dialog before this first await so Save and Update cannot
      // overlap during the cloud permission check. Local saves are exempt.
      // Every destination copy counts: N games into M databases is N x M, and
      // a whole-database save asks for the database's real row count.
      final cloudRows = librarySaveEntryTarget(
        gameCount: gameCount,
        destinationCount: selectedFolders.length,
      );
      if (cloudRows > 0) {
        final quota = await requestSaveGamesQuota(
          context,
          gamesToAdd: cloudRows,
        );
        if (!mounted) return;
        if (!quota.isAllowed) {
          _showToast(freemiumQuotaBlockedMessage(quota), error: true);
          setState(() => _isSaving = false);
          return;
        }
      }
      // Cloud writes first so a disk failure later can be reported with the
      // cloud progress already on screen.
      if (selectedFolders.isNotEmpty) {
        final userId = repo.supabase.auth.currentUser?.id;
        if (userId == null) {
          throw Exception(
            'You need to be signed in to save games to the cloud.',
          );
        }

        final now = DateTime.now();
        final nameCtrl = _newDatabaseNameCtrl;

        if (nameCtrl != null) {
          final allFolders =
              ref.read(libraryFoldersStreamProvider).valueOrNull ??
              const <LibraryFolder>[];
          final newName = nameCtrl.text.trim();
          if (newName.isEmpty) {
            _showToast('Name the new cloud database first.', error: true);
            setState(() => _isSaving = false);
            return;
          }
          // Account-wide UNIQUE(user_id, name): refuse before the request so the
          // user gets the actionable message instead of a duplicate rejection.
          // A node this dialog created itself is never that clash: the attempt
          // either removed it again or keeps it for the retry to fill.
          if (!librarySaveToleratesOwnCloudName(
            clash: libraryCloudNodeNamed(newName, allFolders),
            ownNodeIds: _ownCloudNodeIds,
          )) {
            _showToast(libraryDuplicateCloudNodeMessage(newName), error: true);
            setState(() => _isSaving = false);
            return;
          }
          final parents = libraryNewDatabaseParents(
            selected: selectedFolders,
            allFolders: allFolders,
          );
          // One new database per destination folder is a new database slot.
          final ownedQuota = await requestFreemiumQuota(
            context,
            FreemiumQuotaKind.ownedDatabases,
            additions: parents.length,
          );
          if (!mounted) return;
          if (!ownedQuota.isAllowed) {
            _showToast(
              freemiumQuotaBlockedMessage(ownedQuota),
              error: true,
            );
            setState(() => _isSaving = false);
            return;
          }
          // Create every destination database before writing a single game:
          // the source is enumerated exactly once and each batch streams into
          // all of them, so N folders no longer multiply the row set in memory
          // and a rejected container insert cannot leave a half-filled copy.
          final createdFolderIds = <String>[];
          for (final parent in parents) {
            final parentKey = parent?.id ?? '';
            final pending = _pendingCloudDatabaseFor(parentKey, newName);
            if (pending != null) {
              // A previous attempt in this dialog created this destination,
              // never wrote a row into it and could not remove it again. Fill
              // that database instead of creating a second node under the same
              // account-wide name, which the server would refuse: the user just
              // presses Save again.
              createdFolderIds.add(pending.id);
              newCloudDatabaseNames.add(pending.name);
              continue;
            }
            // Create first, write second: no game row is ever inserted into a
            // pre-existing node, so a local database cannot land in an unrelated
            // cloud database (a `folder` write is redirected server-side into a
            // child database of its own choosing).
            final created = await repo.createFolder(
              name: newName,
              parentId: parent?.id,
              icon: 'database',
              nodeType: kLibraryNodeTypeDatabase,
            );
            // Remember the identity this save created: its own database is
            // not a name clash for itself once the folders stream
            // publishes it mid-write.
            _createdCloudNodeIds.add(created.id);
            _createdCloudNodeNames.add(created.name.trim());
            _pendingCloudDatabases.add(
              _PendingCloudDatabase(
                parentKey: parentKey,
                id: created.id,
                name: created.name.trim(),
              ),
            );
            createdCloudDatabaseIds.add(created.id);
            newCloudDatabaseNames.add(created.name);
            createdFolderIds.add(created.id);
          }
          // Whole-database save: one bounded batch per page of the local
          // database, hydrated off the UI isolate, written and forgotten.
          await for (final batch in _gameBatches(effectiveGames)) {
            await _writeGamesBatch(
              repo: repo,
              userId: userId,
              batch: batch,
              folderIds: createdFolderIds,
              now: now,
              onProgress: retainCommittedOutcome,
            );
            cloudFoldersUsed = newCloudDatabaseNames.length;
            if (!mounted) return;
          }
        } else {
          if (!usesGameSource &&
              effectiveGames.length == 1 &&
              selectedFolders.length == 1 &&
              selectedLocalPaths.isEmpty) {
            final inserted = await repo.createSavedAnalysis(
              SavedAnalysis(
                id: '',
                userId: userId,
                folderId: selectedFolders.single.id,
                title: _titleFor(effectiveGames.single),
                chessGame: effectiveGames.single,
                analysisState: const {},
                variationComments: const {},
                lastViewedPosition: -1,
                tags: const [],
                isFavorite: false,
                createdAt: now,
                updatedAt: now,
              ),
            );
            insertedCloudOrigin = BoardTabLibrarySaveOrigin.cloudSavedAnalysis(
              analysisId: inserted.id,
              title: inserted.title,
            );
            _savedRows = 1;
            cloudFoldersUsed = 1;
            retainCommittedOutcome();
            if (!mounted) return;
            setState(() {});
          } else {
            final folderIds = selectedFolders
                .map((folder) => folder.id)
                .toList(growable: false);
            final writtenFolderIds = <String>{};
            await for (final batch in _gameBatches(effectiveGames)) {
              final written = await _writeGamesBatch(
                repo: repo,
                userId: userId,
                batch: batch,
                folderIds: folderIds,
                now: now,
                onProgress: retainCommittedOutcome,
              );
              if (written > 0) writtenFolderIds.addAll(folderIds);
              cloudFoldersUsed = writtenFolderIds.length;
              if (!mounted) return;
            }
          }
        }

        ref.invalidate(libraryFoldersStreamProvider);
        ref.invalidate(subscribedBooksProvider);
      }

      final localErrors = <String>[];
      if (selectedLocalPaths.isNotEmpty) {
        for (final path in selectedLocalPaths) {
          final writer = LocalLibraryWriter(folderPath: path);
          final outcome = await writer.writeGames(effectiveGames);
          localWriteOutcomes.add(outcome);
          if (outcome.written > 0) {
            localFoldersUsed++;
            _localWritten += outcome.written;
          }
          retainCommittedOutcome();
          if (!mounted) return;
          setState(() {});
          if (outcome.hasError) {
            localErrors.add('${p.basename(path)}: ${outcome.errorMessage}');
          }
        }

        // If the active browser source covers any of the folders we wrote
        // into, refresh the scan so the new games show up immediately.
        final libraryState = ref.read(localChessLibraryProvider);
        final activePaths = libraryState.source?.paths ?? const <String>[];
        final activeKeys = activePaths.map(_normalizeLocalPath).toSet();
        final overlaps = selectedLocalPaths.any(
          (path) => activeKeys.contains(_normalizeLocalPath(path)),
        );
        if (overlaps) {
          // Fire-and-forget — the dialog should not block on a rescan that
          // can be slow on huge databases.
          unawaited(ref.read(localChessLibraryProvider.notifier).refresh());
        }
      }

      if (!mounted) return;

      if (_savedRows == 0 && _localWritten == 0) {
        final detail =
            localErrors.isEmpty
                ? 'Nothing was saved.'
                : 'Nothing was saved: ${localErrors.join('; ')}';
        _showToast(detail, error: true);
        setState(() => _isSaving = false);
        return;
      }

      if (localErrors.isNotEmpty) {
        _showToast(
          'Some local writes failed: ${localErrors.join('; ')}',
          error: true,
        );
      }

      await persistLibrarySaveRecencyBestEffort(
        () => _recencyStore.recordSuccessfulSave(
          cloudFolderIds:
              _savedRows > 0
                  ? selectedFolders.map((folder) => folder.id).toList()
                  : const <String>[],
          localPathKeys: localWriteOutcomes
              .where((outcome) => outcome.written > 0)
              .map((outcome) => _normalizeLocalPath(outcome.folderPath))
              .toList(growable: false),
        ),
      );
      if (!mounted) return;

      Navigator.of(context).pop(committedOutcome);
    } catch (e) {
      // A failure before the first row leaves the destination database this
      // attempt created behind as an empty same-name node that refuses every
      // retry. Remove it again before reporting, even if the dialog was
      // dismissed mid-save: `repo` is captured and this is not UI work.
      final keptNames = await _removeEmptyCloudDatabasesFromFailedSave(
        createdCloudDatabaseIds,
        repo,
      );
      if (!mounted) return;
      // A write that lost the race for the last slot is a quota answer, not a
      // failure: name the allowance instead of dumping the database error.
      final rejection = freemiumQuotaRejection(
        e,
        fallbackKind: FreemiumQuotaKind.savedGames,
      );
      final detail =
          rejection != null ? freemiumQuotaBlockedMessage(rejection) : '$e';
      final keptNote =
          keptNames.isEmpty
              ? ''
              : ' The empty database '
                    '${keptNames.map((name) => '"$name"').join(', ')} '
                    'could not be removed and will be reused by the next save.';
      if (committedOutcome != null) {
        // A retry here would duplicate already committed destinations.
        _showToast(
          'Some entries were saved before an error: $detail',
          error: true,
        );
        Navigator.of(context).pop(committedOutcome);
      } else {
        _showToast(
          rejection != null ? detail : 'Save failed: $detail$keptNote',
          error: true,
        );
        setState(() => _isSaving = false);
      }
    } finally {
      // The paged source owns whatever backs it (for example a raw-PGN catalog
      // handle). Hand it back however the save ended, including a mid-save
      // dismissal of the dialog.
      widget.gameSource?.release();
    }
  }

  String _progressLabel({
    required int cloudDone,
    required int cloudTotal,
    required int localDone,
    required int localTotal,
  }) {
    final parts = <String>[];
    if (cloudTotal > 0) {
      parts.add('Cloud $cloudDone / $cloudTotal');
    }
    if (localTotal > 0) {
      parts.add('Local $localDone / $localTotal');
    }
    if (parts.isEmpty) return 'Saving…';
    return parts.join(' · ');
  }

  String _titleFor(ChessGame game) {
    final white = (game.metadata['White']?.toString().trim() ?? '');
    final black = (game.metadata['Black']?.toString().trim() ?? '');
    final w = white.isEmpty ? 'White' : white;
    final b = black.isEmpty ? 'Black' : black;
    return '$w vs $b';
  }

  void _showToast(String message, {bool error = false}) {
    showDesktopToast(context, message, error: error);
  }

  @override
  Widget build(BuildContext context) {
    final foldersAsync = ref.watch(libraryFoldersStreamProvider);
    final folders = foldersAsync.valueOrNull ?? const <LibraryFolder>[];
    final writable = librarySaveWritableCloudFolders(
      folders: folders,
      destinationMode: widget.destinationMode,
      foldersOnly: widget.newDatabaseName != null,
    );
    final ordered = orderLibrarySaveCloudFolders(
      folders: writable,
      recentFolderIds: _destinationRecency.cloudFolderIds,
    );
    final selectedFolders = ordered
        .where((f) => _selected.contains(f.id))
        .toList(growable: false);

    final unsortedLocalEntries =
        librarySaveAllowsLocalDestinations(widget.destinationMode)
            ? ref.watch(localLibraryRegistryProvider).entries
            : const <LocalLibraryEntry>[];
    final localEntries =
        orderLibrarySaveDestinationsByRecent<LocalLibraryEntry>(
          values: unsortedLocalEntries,
          recentKeys: _destinationRecency.localPathKeys,
          keyOf: (entry) => _normalizeLocalPath(entry.path),
        );
    final selectedLocalPaths = localEntries
        .map((e) => e.path)
        .where(
          (path) => _selectedLocalPaths.contains(_normalizeLocalPath(path)),
        )
        .toList(growable: false);

    final pinnedKeys = librarySavePinnedDestinationKeys(
      orderedPinKeys:
          ref.watch(myDatabasesFocusProvider).orderedPinnedDatabaseKeys,
      folders: writable,
      localEntries: localEntries,
      destinationMode: widget.destinationMode,
    );
    final cloudByPin = {
      for (final folder in writable) libraryCloudDatabasePinKey(folder.id): folder,
    };
    final localByPin = {
      for (final entry in localEntries) libraryLocalDatabasePinKey(entry.path): entry,
    };
    final selectedPinKeys = {
      ...selectedFolders.map((folder) => libraryCloudDatabasePinKey(folder.id)),
      ...selectedLocalPaths.map(libraryLocalDatabasePinKey),
    };

    final cloudRowsTarget = librarySaveEntryTarget(
      gameCount: _gameCount,
      destinationCount: selectedFolders.length,
    );
    final localFilesTarget = librarySaveEntryTarget(
      gameCount: _gameCount,
      destinationCount: selectedLocalPaths.length,
    );
    final totalTarget = cloudRowsTarget + localFilesTarget;
    final totalDone = _savedRows + _localWritten;

    final destinationCount = selectedFolders.length + selectedLocalPaths.length;
    final saveLabel =
        _isDeletingLocalDestination
            ? 'Deleting'
            : _isSaving
            ? 'Saving'
            : destinationCount == 0
            ? 'Pick a destination'
            : 'Save to $destinationCount destination'
                '${destinationCount == 1 ? '' : 's'}';
    final updateTarget = widget.updateTarget;
    final busy =
        _isSaving || _isUpdatingOriginal || _isDeletingLocalDestination;

    final content = FTheme(
      data: FThemes.zinc.dark,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
          child: Container(
            decoration: BoxDecoration(
              color: kBlack2Color,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kDividerColor),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 28,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Focus(
              autofocus: true,
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                if (event.logicalKey == LogicalKeyboardKey.escape) {
                  if (!busy) {
                    Navigator.of(context).maybePop();
                  }
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(
                    title: librarySaveDialogTitle(widget.destinationMode),
                    subtitle:
                        '$_gameCount '
                        '${librarySaveEntryLabel(_gameCount)} from '
                        '${widget.sourceLabel}',
                  ),
                  const FDivider(),
                  Flexible(
                    child: foldersAsync.when(
                      data: (_) {
                        final bothEmpty =
                            writable.isEmpty && localEntries.isEmpty;
                        if (bothEmpty && updateTarget == null) {
                          return _EmptyHint(
                            onCreate:
                                widget.destinationMode ==
                                        LibrarySaveDestinationMode.localOnly
                                    ? null
                                    : () => _onCreateFolder(writable),
                            onAddLocal:
                                (busy ||
                                        !librarySaveAllowsLocalDestinations(
                                          widget.destinationMode,
                                        ))
                                    ? null
                                    : _onAddLocalPgnFile,
                          );
                        }
                        return SingleChildScrollView(
                          physics: const DesktopScrollPhysics(),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_supportsMetadataEdit) ...[
                                _buildGameDetailsSection(),
                                const SizedBox(height: 14),
                              ],
                              if (updateTarget != null) ...[
                                _UpdateOriginalTile(
                                  target: updateTarget,
                                  busy: _isUpdatingOriginal,
                                  disabled:
                                      _isSaving || _isDeletingLocalDestination,
                                  onTap: _onUpdateOriginal,
                                ),
                                const SizedBox(height: 12),
                              ],
                              if (_newDatabaseNameCtrl != null) ...[
                                _buildNewDatabaseSection(
                                  allFolders: folders,
                                  selectedFolders: selectedFolders,
                                ),
                                const SizedBox(height: 8),
                              ],
                              if (pinnedKeys.isNotEmpty) ...[
                                LibrarySaveSection(
                                  key: const ValueKey('save-pinned'),
                                  icon: Icons.push_pin_outlined,
                                  label: 'PINNED',
                                  enabled: !busy,
                                  selectedCount: pinnedKeys
                                      .where(selectedPinKeys.contains)
                                      .length,
                                  children: [
                                    for (final key in pinnedKeys)
                                      if (cloudByPin[key] case final folder?)
                                        _cloudDestinationRow(folder, busy)
                                      else if (localByPin[key] case final entry?)
                                        _localDestinationRow(entry, busy),
                                  ],
                                ),
                                const SizedBox(height: 8),
                              ],
                              if (writable.isNotEmpty) ...[
                                LibrarySaveSection(
                                  key: const ValueKey('save-cloud'),
                                  icon: Icons.cloud_outlined,
                                  label:
                                      widget.newDatabaseName == null
                                          ? 'CLOUD LIBRARY'
                                          : 'DESTINATION FOLDER',
                                  enabled: !busy,
                                  selectedCount: selectedFolders.length,
                                  children: [
                                    for (final folder in ordered)
                                      _cloudDestinationRow(folder, busy),
                                  ],
                                ),
                                const SizedBox(height: 8),
                              ],
                              if (librarySaveAllowsLocalDestinations(
                                widget.destinationMode,
                              ))
                                LibrarySaveSection(
                                  key: const ValueKey('save-local'),
                                  icon: Platform.isMacOS
                                      ? Icons.computer_outlined
                                      : Icons.storage_outlined,
                                  label:
                                      Platform.isMacOS
                                          ? 'ON THIS MAC'
                                          : 'ON THIS PC',
                                  enabled: !busy,
                                  selectedCount: selectedLocalPaths.length,
                                  children: [
                                    for (final entry in localEntries)
                                      _localDestinationRow(entry, busy),
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: _AddLocalFolderTile(
                                        onTap: busy ? null : _onAddLocalPgnFile,
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        );
                      },
                      loading:
                          () => const Padding(
                            padding: EdgeInsets.all(40),
                            child: Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation(
                                    kPrimaryColor,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      error:
                          (e, _) => Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Could not load folders.',
                                  style: TextStyle(
                                    color: kRedColor,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                DesktopDialogButton(
                                  label: 'Retry',
                                  onPress:
                                      () => ref.invalidate(
                                        libraryFoldersStreamProvider,
                                      ),
                                ),
                              ],
                            ),
                          ),
                    ),
                  ),
                  if (_isSaving) ...[
                    const FDivider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value:
                                  totalTarget == 0
                                      ? null
                                      : (totalDone / totalTarget).clamp(
                                        0.0,
                                        1.0,
                                      ),
                              minHeight: 6,
                              color: kPrimaryColor,
                              backgroundColor: kWhiteColor.withValues(
                                alpha: 0.06,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _progressLabel(
                              cloudDone: _savedRows,
                              cloudTotal: cloudRowsTarget,
                              localDone: _localWritten,
                              localTotal: localFilesTarget,
                            ),
                            style: const TextStyle(
                              color: kLightGreyColor,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const FDivider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    // Natural button widths first; only a genuinely narrow
                    // dialog or large text scale stacks the action row.
                    child: OverflowBar(
                      alignment: MainAxisAlignment.spaceBetween,
                      overflowAlignment: OverflowBarAlignment.end,
                      spacing: 8,
                      overflowSpacing: 8,
                      children: [
                        if (widget.destinationMode !=
                            LibrarySaveDestinationMode.localOnly)
                          DesktopDialogButton(
                            label: 'New folder',
                            icon: Icons.create_new_folder_outlined,
                            onPress:
                                (_isSaving || _isUpdatingOriginal)
                                    ? null
                                    : () => _onCreateFolder(writable),
                          )
                        else
                          const SizedBox.shrink(),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DesktopDialogButton(
                              label: 'Cancel',
                              onPress:
                                  (_isSaving || _isUpdatingOriginal)
                                      ? null
                                      : () => Navigator.of(context).maybePop(),
                            ),
                            const SizedBox(width: 8),
                            DesktopDialogButton(
                              label: saveLabel,
                              tone: DesktopDialogButtonTone.primary,
                              prefix:
                                  _isSaving
                                      ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor: AlwaysStoppedAnimation(
                                            kWhiteColor,
                                          ),
                                        ),
                                      )
                                      : null,
                              onPress:
                                  (busy || destinationCount == 0)
                                      ? null
                                      : () => _onSave(
                                        selectedFolders,
                                        selectedLocalPaths,
                                      ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // Match the disabled Cancel/Escape paths for barrier/back dismissal too.
    return PopScope<LibrarySaveOutcome>(canPop: !busy, child: content);
  }

  // Pinned rows are aliases: both presentations toggle the same ID/path sets.
  // Save payloads above are derived only from the underlying destination lists.
  Widget _cloudDestinationRow(LibraryFolder folder, bool busy) => _FolderRow(
    folder: folder,
    selected: _selected.contains(folder.id),
    disabled: busy,
    onToggle: () => setState(() {
      if (!_selected.add(folder.id)) _selected.remove(folder.id);
    }),
  );

  Widget _localDestinationRow(LocalLibraryEntry entry, bool busy) {
    final key = _normalizeLocalPath(entry.path);
    return _LocalFolderRow(
      entry: entry,
      selected: _selectedLocalPaths.contains(key),
      disabled: busy,
      onToggle: () => setState(() {
        if (!_selectedLocalPaths.add(key)) _selectedLocalPaths.remove(key);
      }),
      onForget: busy ? null : () => unawaited(_deleteLocalDestination(entry)),
    );
  }

  /// Name block for a local database being saved to the cloud as a *new* cloud
  /// database.
  ///
  /// The name is pre-filled from the local file and stays editable, because
  /// `user_folders` is `UNIQUE (user_id, name)` for the whole account: a
  /// conflict has to be visible *before* Save is pressed instead of surfacing
  /// as a database rejection afterwards. The hint line names the folder the
  /// database will actually be created in, so a destination that retargets is
  /// never silent.
  ///
  /// That makes the hint a *pre-save* signal: while the save runs, its own
  /// destination database is already in the folder stream, so the conflict
  /// is evaluated against the nodes that predate the save and is suppressed
  /// for the whole write (see [libraryNewCloudDatabaseNameConflict]).
  Widget _buildNewDatabaseSection({
    required List<LibraryFolder> allFolders,
    required List<LibraryFolder> selectedFolders,
  }) {
    final ctrl = _newDatabaseNameCtrl!;
    final typed = ctrl.text.trim();
    // A conflict is a node that already existed when Save was pressed. The
    // database this save created itself is never one, and a save that is
    // running has already had its name accepted, so the hint stays quiet
    // until the write finishes.
    final conflict =
        libraryNewCloudDatabaseNameConflict(
          typed,
          allFolders,
          createdIds: _createdCloudNodeIds,
          createdNames: _createdCloudNodeNames,
          saveInFlight: _isSaving,
        ) !=
        null;
    final destinations = <String>{
      for (final parent in libraryNewDatabaseParents(
        selected: selectedFolders,
        allFolders: allFolders,
      ))
        parent?.name ?? 'Library Home',
    };
    final hint =
        typed.isEmpty
            ? 'Name the new cloud database.'
            : conflict
            ? libraryDuplicateCloudNodeMessage(typed)
            : switch (destinations.length) {
              0 => 'Created inside the folder you pick.',
              1 => 'Created inside "${destinations.single}".',
              _ => 'Created inside ${destinations.length} folders.',
            };
    final hintIsProblem = typed.isEmpty || conflict;

    return Container(
      decoration: BoxDecoration(
        color: kBlack3Color.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LibrarySaveSectionHeader(
            label: 'NEW DATABASE',
            icon: Icons.storage_rounded,
            expanded: true,
            onToggle: null,
            trailing:
                '$_gameCount '
                '${librarySaveEntryLabel(_gameCount)}',
          ),
          const FDivider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _FieldLabel(label: 'Database name'),
                const SizedBox(height: 6),
                FTextField(
                  controller: ctrl,
                  enabled:
                      !_isSaving &&
                      !_isUpdatingOriginal &&
                      !_isDeletingLocalDestination,
                  hint: 'Database name',
                  onChange: (_) => setState(() {}),
                ),
                const SizedBox(height: 6),
                Text(
                  hint,
                  style: TextStyle(
                    color: hintIsProblem ? kRedColor : kLightGreyColor,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGameDetailsSection() {
    return Container(
      decoration: BoxDecoration(
        color: kBlack3Color.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LibrarySaveSectionHeader(
            label: 'GAME DETAILS',
            icon: Icons.edit_note_rounded,
            trailing: _showGameDetails ? 'Hide' : 'Edit',
            expanded: _showGameDetails,
            onToggle:
                (_isSaving || _isUpdatingOriginal)
                    ? null
                    : () =>
                        setState(() => _showGameDetails = !_showGameDetails),
          ),
          if (_showGameDetails) ...[
            const FDivider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PlayerNameRow(
                    label: 'White',
                    surnameCtrl: _whiteSurnameCtrl!,
                    firstNameCtrl: _whiteFirstNameCtrl!,
                    enabled: !_isSaving && !_isUpdatingOriginal,
                  ),
                  const SizedBox(height: 12),
                  _PlayerNameRow(
                    label: 'Black',
                    surnameCtrl: _blackSurnameCtrl!,
                    firstNameCtrl: _blackFirstNameCtrl!,
                    enabled: !_isSaving && !_isUpdatingOriginal,
                  ),
                  const SizedBox(height: 12),
                  _FieldLabel(label: 'Tournament'),
                  const SizedBox(height: 6),
                  FTextField(
                    controller: _eventCtrl,
                    enabled: !_isSaving && !_isUpdatingOriginal,
                    hint: 'Event name',
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _FieldLabel(label: 'ECO'),
                            const SizedBox(height: 6),
                            FTextField(
                              controller: _ecoCtrl,
                              enabled: !_isSaving && !_isUpdatingOriginal,
                              hint: 'e.g. C50',
                              textCapitalization: TextCapitalization.characters,
                              inputFormatters: [
                                LengthLimitingTextInputFormatter(6),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _FieldLabel(label: 'Result'),
                            const SizedBox(height: 6),
                            FSelect<String>(
                              hint: 'Result',
                              initialValue: _selectedResult,
                              enabled: !_isSaving && !_isUpdatingOriginal,
                              onChange: (v) {
                                if (v == null) return;
                                setState(() => _selectedResult = v);
                              },
                              items: {
                                for (final r in kSupportedPgnResults) r: r,
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _FieldLabel(label: 'White Elo'),
                            const SizedBox(height: 6),
                            FTextField(
                              controller: _whiteEloCtrl,
                              enabled: !_isSaving && !_isUpdatingOriginal,
                              hint: '0–4000',
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(4),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _FieldLabel(label: 'Black Elo'),
                            const SizedBox(height: 6),
                            FTextField(
                              controller: _blackEloCtrl,
                              enabled: !_isSaving && !_isUpdatingOriginal,
                              hint: '0–4000',
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(4),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _FieldLabel(label: 'Round'),
                            const SizedBox(height: 6),
                            FTextField(
                              controller: _roundCtrl,
                              enabled: !_isSaving && !_isUpdatingOriginal,
                              hint: 'e.g. 5',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _FieldLabel(label: 'Subround'),
                            const SizedBox(height: 6),
                            FTextField(
                              controller: _subroundCtrl,
                              enabled: !_isSaving && !_isUpdatingOriginal,
                              hint: 'e.g. 1.2',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _DateRow(
                    yearCtrl: _yearCtrl!,
                    monthCtrl: _monthCtrl!,
                    dayCtrl: _dayCtrl!,
                    enabled: !_isSaving && !_isUpdatingOriginal,
                    onToday:
                        (_isSaving || _isUpdatingOriginal)
                            ? null
                            : _fillTodayDate,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(color: kLightGreyColor, fontSize: 12),
                ),
              ],
            ),
          ),
          DesktopDialogIconButton(
            icon: Icons.close_rounded,
            tooltip: 'Close',
            onPress: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}

class _UpdateOriginalTile extends StatelessWidget {
  const _UpdateOriginalTile({
    required this.target,
    required this.busy,
    required this.disabled,
    required this.onTap,
  });

  final LibraryUpdateTarget target;
  final bool busy;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = !busy && !disabled;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.12),
        border: Border.all(color: kPrimaryColor.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DesktopTappable(
        onPress: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        hoverColor: kWhiteColor.withValues(alpha: 0.04),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                  ),
                )
              else
                const Icon(
                  Icons.save_as_outlined,
                  size: 18,
                  color: kPrimaryColor,
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      busy ? 'Updating existing game…' : 'Update existing game',
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${target.title} · ${target.subtitle}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kLightGreyColor,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded, color: kLightGreyColor),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.onCreate, required this.onAddLocal});
  final VoidCallback? onCreate;
  final VoidCallback? onAddLocal;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.folder_off_outlined,
            size: 28,
            color: kLightGreyColor,
          ),
          const SizedBox(height: 12),
          Text(
            switch ((onCreate != null, onAddLocal != null)) {
              (true, true) =>
                'No destinations yet. Save to the cloud library, or pick a '
                    'PGN file on this computer to keep games locally.',
              (true, false) =>
                'No cloud folders yet. Create a cloud folder to save this '
                    'database to your cloud library.',
              (false, true) =>
                'No local destinations yet. Pick a PGN file on this '
                    'computer to keep games locally.',
              (false, false) => 'No destinations available yet.',
            },
            style: const TextStyle(color: kWhiteColor70, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (onCreate != null) ...[
                DesktopDialogButton(
                  label: 'Cloud folder',
                  icon: Icons.cloud_outlined,
                  tone: DesktopDialogButtonTone.primary,
                  onPress: onCreate,
                ),
                const SizedBox(width: 10),
              ],
              if (onAddLocal != null)
                DesktopDialogButton(
                  label: 'PGN file',
                  icon: Icons.description_outlined,
                  onPress: onAddLocal,
                ),
            ],
          ),
        ],
      ),
    );
  }
}



class _AddLocalFolderTile extends StatefulWidget {
  const _AddLocalFolderTile({required this.onTap});

  final VoidCallback? onTap;

  @override
  State<_AddLocalFolderTile> createState() => _AddLocalFolderTileState();
}

class _AddLocalFolderTileState extends State<_AddLocalFolderTile>
    with DeferredPointerStateMixin<_AddLocalFolderTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final fg = enabled ? kWhiteColor70 : kLightGreyColor.withValues(alpha: 0.5);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ClickCursor(
        child: MouseRegion(
          onEnter:
              enabled
                  ? (_) => setStateAfterPointerEvent(() => _hovered = true)
                  : null,
          onExit:
              enabled
                  ? (_) => setStateAfterPointerEvent(() => _hovered = false)
                  : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(
                color: _hovered ? kBlack3Color : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: kDividerColor.withValues(alpha: 0.7),
                  style: BorderStyle.solid,
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.add_rounded, color: fg, size: 16),
                  const SizedBox(width: 8),
                  Icon(Icons.description_outlined, color: fg, size: 16),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Choose a PGN file on this computer…',
                      style: TextStyle(
                        color: fg,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
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

class _LocalFolderRow extends StatefulWidget {
  const _LocalFolderRow({
    required this.entry,
    required this.selected,
    required this.disabled,
    required this.onToggle,
    required this.onForget,
  });

  final LocalLibraryEntry entry;
  final bool selected;
  final bool disabled;
  final VoidCallback onToggle;
  final VoidCallback? onForget;

  @override
  State<_LocalFolderRow> createState() => _LocalFolderRowState();
}

class _LocalFolderRowState extends State<_LocalFolderRow>
    with DeferredPointerStateMixin<_LocalFolderRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final fg =
        widget.disabled ? kLightGreyColor.withValues(alpha: 0.5) : kWhiteColor;
    final bg =
        widget.selected
            ? kPrimaryColor.withValues(alpha: 0.10)
            : (_hovered ? kBlack3Color : Colors.transparent);
    final isPgnFile = p.extension(widget.entry.path).toLowerCase() == '.pgn';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
          onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
          child: DesktopTappable(
            onPress: widget.disabled ? null : widget.onToggle,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      widget.selected
                          ? kPrimaryColor.withValues(alpha: 0.45)
                          : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    widget.selected
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    color: widget.selected ? kPrimaryColor : kLightGreyColor,
                    size: 16,
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    isPgnFile
                        ? Icons.description_outlined
                        : Icons.folder_special_outlined,
                    size: 16,
                    color: kWhiteColor70,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.entry.displayName,
                          style: TextStyle(
                            color: fg,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.entry.path,
                          style: const TextStyle(
                            color: kLightGreyColor,
                            fontSize: 10.5,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (widget.onForget != null)
                    DesktopDialogIconButton(
                      icon: Icons.close_rounded,
                      tooltip: 'Delete local database',
                      onPress: widget.onForget,
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

@visibleForTesting
String librarySaveEntryLabel(int count) => count == 1 ? 'entry' : 'entries';

/// Entries a save writes for [gameCount] games and [destinationCount]
/// destinations.
///
/// A whole-database save passes the database's own row count, so the progress
/// bar and the cloud quota request describe every game that will be uploaded
/// instead of the table page that happened to be loaded.
@visibleForTesting
int librarySaveEntryTarget({
  required int gameCount,
  required int destinationCount,
}) {
  if (gameCount <= 0 || destinationCount <= 0) return 0;
  return gameCount * destinationCount;
}

/// Games a dialog instance covers.
///
/// A paged [LibrarySaveGameSource] supplies its own total and arrives with an
/// empty materialized list, so `games.isEmpty` must never be read as "nothing
/// to save" for a whole-database save.
@visibleForTesting
int librarySaveDialogGameCount({
  required int materializedCount,
  required int? sourceTotal,
}) => sourceTotal ?? materializedCount;

/// PGN-recognized result codes, in the order shown in the dropdown.
/// `*` (ongoing) is the safe default for partially-edited games.
const List<String> kSupportedPgnResults = <String>[
  '1-0',
  '0-1',
  '1/2-1/2',
  '+:-',
  '-:+',
  '=:=',
  '0-0',
  '*',
];

/// Pair of name parts split from a single PGN player header.
class PlayerNameParts {
  const PlayerNameParts({required this.surname, required this.firstName});
  final String surname;
  final String firstName;
}

/// Converts PGN-required unknown markers into quiet empty form values.
///
/// The writer still restores standards-compliant unknown headers on save;
/// users should not have to delete parser placeholders before entering real
/// game details.
@visibleForTesting
String libraryGameDetailInputValue(Object? raw) {
  final value = raw?.toString().trim() ?? '';
  if (value.isEmpty || RegExp(r'^\?+$').hasMatch(value)) return '';
  return value;
}

/// PGN headers store player names as "Surname, FirstName". The form splits
/// them into two inputs so users do not have to remember the comma rule.
@visibleForTesting
PlayerNameParts splitPlayerName(String? raw) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty || trimmed == '?') {
    return const PlayerNameParts(surname: '', firstName: '');
  }
  final commaIndex = trimmed.indexOf(',');
  if (commaIndex < 0) {
    return PlayerNameParts(surname: trimmed, firstName: '');
  }
  return PlayerNameParts(
    surname: trimmed.substring(0, commaIndex).trim(),
    firstName: trimmed.substring(commaIndex + 1).trim(),
  );
}

/// Inverse of [splitPlayerName]. Returns `?` when both halves are empty so
/// the PGN exporter doesn't emit an empty header.
@visibleForTesting
String joinPlayerName(String surname, String firstName) {
  final s = surname.trim();
  final f = firstName.trim();
  if (s.isEmpty && f.isEmpty) return '?';
  if (f.isEmpty) return s;
  if (s.isEmpty) return f;
  return '$s, $f';
}

/// Serializes year/month/day inputs to the PGN date format `YYYY.MM.DD`,
/// using `????`/`??` for missing components per the spec. Empty year yields
/// the fully-unknown date `????.??.??`.
@visibleForTesting
String buildPgnDate({
  required String year,
  required String month,
  required String day,
}) {
  final y = year.trim();
  if (y.isEmpty) return '????.??.??';
  final m = month.trim();
  final d = day.trim();
  final mm = m.isEmpty ? '??' : m.padLeft(2, '0');
  final dd = d.isEmpty ? '??' : d.padLeft(2, '0');
  return '$y.$mm.$dd';
}

/// Folds form values into the original PGN metadata map. Trimmed inputs
/// fall back to `?` for required headers (White/Black/Event) so the
/// resulting game stays a valid PGN record after export.
@visibleForTesting
Map<String, dynamic> buildEditedMetadata({
  required Map<String, dynamic> original,
  required String whiteSurname,
  required String whiteFirstName,
  required String blackSurname,
  required String blackFirstName,
  required String event,
  required String eco,
  required String whiteElo,
  required String blackElo,
  required String round,
  required String subround,
  required String result,
  required String year,
  required String month,
  required String day,
}) {
  final merged = Map<String, dynamic>.from(original);
  merged['White'] = joinPlayerName(whiteSurname, whiteFirstName);
  merged['Black'] = joinPlayerName(blackSurname, blackFirstName);
  final trimmedEvent = event.trim();
  merged['Event'] = trimmedEvent.isEmpty ? '?' : trimmedEvent;
  merged['ECO'] = eco.trim();
  merged['WhiteElo'] = whiteElo.trim();
  merged['BlackElo'] = blackElo.trim();
  final trimmedRound = round.trim();
  merged['Round'] = trimmedRound.isEmpty ? '?' : trimmedRound;
  merged['Subround'] = subround.trim();
  merged['Result'] = kSupportedPgnResults.contains(result) ? result : '*';
  merged['Date'] = buildPgnDate(year: year, month: month, day: day);
  return merged;
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: kLightGreyColor,
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    );
  }
}



class _PlayerNameRow extends StatelessWidget {
  const _PlayerNameRow({
    required this.label,
    required this.surnameCtrl,
    required this.firstNameCtrl,
    required this.enabled,
  });

  final String label;
  final TextEditingController surnameCtrl;
  final TextEditingController firstNameCtrl;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FieldLabel(label: label),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: FTextField(
                controller: surnameCtrl,
                enabled: enabled,
                hint: 'Surname',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FTextField(
                controller: firstNameCtrl,
                enabled: enabled,
                hint: 'First name',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.yearCtrl,
    required this.monthCtrl,
    required this.dayCtrl,
    required this.enabled,
    required this.onToday,
  });

  final TextEditingController yearCtrl;
  final TextEditingController monthCtrl;
  final TextEditingController dayCtrl;
  final bool enabled;
  final VoidCallback? onToday;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _FieldLabel(label: 'Date (YYYY.MM.DD)'),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              flex: 3,
              child: FTextField(
                controller: yearCtrl,
                enabled: enabled,
                hint: 'YYYY',
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 2,
              child: FTextField(
                controller: monthCtrl,
                enabled: enabled,
                hint: 'MM',
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(2),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 2,
              child: FTextField(
                controller: dayCtrl,
                enabled: enabled,
                hint: 'DD',
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(2),
                ],
              ),
            ),
            const SizedBox(width: 8),
            DesktopDialogButton(
              label: 'Today',
              tone: DesktopDialogButtonTone.ghost,
              onPress: onToday,
            ),
          ],
        ),
      ],
    );
  }
}

class _FolderRow extends StatefulWidget {
  const _FolderRow({
    required this.folder,
    required this.selected,
    required this.disabled,
    required this.onToggle,
  });

  final LibraryFolder folder;
  final bool selected;
  final bool disabled;
  final VoidCallback onToggle;

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow>
    with DeferredPointerStateMixin<_FolderRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final indent = widget.folder.parentId == null ? 0.0 : 18.0;
    final fg =
        widget.disabled ? kLightGreyColor.withValues(alpha: 0.5) : kWhiteColor;
    final bg =
        widget.selected
            ? kPrimaryColor.withValues(alpha: 0.10)
            : (_hovered ? kBlack3Color : Colors.transparent);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
          onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
          child: DesktopTappable(
            onPress: widget.disabled ? null : widget.onToggle,
            child: Container(
              padding: EdgeInsets.fromLTRB(10 + indent, 8, 10, 8),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      widget.selected
                          ? kPrimaryColor.withValues(alpha: 0.45)
                          : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    widget.selected
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    color: widget.selected ? kPrimaryColor : kLightGreyColor,
                    size: 16,
                  ),
                  const SizedBox(width: 10),
                  if (widget.folder.parentId != null)
                    const Icon(
                      Icons.subdirectory_arrow_right_rounded,
                      size: 14,
                      color: kLightGreyColor,
                    ),
                  if (widget.folder.parentId != null) const SizedBox(width: 4),
                  Icon(
                    widget.folder.parentId == null
                        ? Icons.folder_rounded
                        : Icons.folder_outlined,
                    size: 16,
                    color: kWhiteColor70,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.folder.name,
                      style: TextStyle(
                        color: fg,
                        fontSize: 13,
                        fontWeight:
                            widget.folder.parentId == null
                                ? FontWeight.w600
                                : FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
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

/// One destination database this dialog created for a save that has not written
/// a row yet, remembered so a retry can reuse it instead of creating a
/// duplicate same-name node.
class _PendingCloudDatabase {
  const _PendingCloudDatabase({
    required this.parentKey,
    required this.id,
    required this.name,
  });

  /// Canonical key of the create parent (`''` = library top level), the same
  /// key `libraryNewDatabaseParents` groups by.
  final String parentKey;

  /// `user_folders` row id of the created database.
  final String id;

  /// Trimmed name it was created with.
  final String name;
}
