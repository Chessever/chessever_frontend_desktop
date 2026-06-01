import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/desktop/services/local_library_writer.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/library/library_folder_dialogs.dart';
import 'package:chessever/utils/save_to_library_guard.dart';
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
  });

  /// Number of rows written to the cloud `saved_analyses` table.
  final int savedRows;

  /// Number of cloud folders that received at least one row.
  final int folderCount;

  /// Number of `.pgn` files written to disk across local folders.
  final int localFilesWritten;

  /// Number of local folders that received at least one file.
  final int localFoldersUsed;

  /// True when the caller updated the source library game rather than saving a
  /// new copy into another destination.
  final bool didUpdateOriginal;

  /// Total entries persisted across cloud + local destinations.
  int get totalEntries => savedRows + localFilesWritten;

  bool get didSave => didUpdateOriginal || totalEntries > 0;

  /// Toast-friendly summary, e.g. "Saved 3 entries to the cloud library" or
  /// "Saved 2 entries locally · 1 entry to the cloud library".
  String toToastMessage() {
    if (didUpdateOriginal) return 'Updated existing game';
    final parts = <String>[];
    if (savedRows > 0) {
      parts.add(
        '$savedRows ${savedRows == 1 ? 'entry' : 'entries'} to the '
        'cloud library',
      );
    }
    if (localFilesWritten > 0) {
      final folderHint =
          localFoldersUsed > 1 ? ' across $localFoldersUsed local folders' : '';
      parts.add(
        '$localFilesWritten ${localFilesWritten == 1 ? 'entry' : 'entries'} '
        'on this computer$folderHint',
      );
    }
    if (parts.isEmpty) return 'Nothing saved.';
    return 'Saved ${parts.join(' · ')}';
  }
}

class LibraryUpdateTarget {
  const LibraryUpdateTarget({
    required this.title,
    required this.subtitle,
    required this.onUpdate,
  });

  final String title;
  final String subtitle;
  final Future<void> Function() onUpdate;
}

/// Forui-styled "Save to folder(s)" dialog. Shows the user's writable
/// folders as multi-select rows, supports inline create, and writes the
/// supplied [games] into every selected folder as library entries via
/// `LibraryRepository.createSavedAnalysesBulk` (the same pipeline mobile
/// uses for clipboard / file imports).
///
/// Returns a [LibrarySaveOutcome] describing what was written, or `null`
/// if the user dismissed the dialog without saving.
Future<LibrarySaveOutcome?> showLibrarySaveToFolderDialog({
  required BuildContext context,
  required WidgetRef ref,
  required List<ChessGame> games,
  String? suggestedFolderId,
  String? sourceLabel,
  LibraryUpdateTarget? updateTarget,
}) {
  if (games.isEmpty) {
    return Future.value(null);
  }
  return showGeneralDialog<LibrarySaveOutcome>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Save to folder',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder:
        (ctx, _, _) => _SaveToFolderDialog(
          ref: ref,
          games: games,
          sourceLabel: sourceLabel ?? 'imported',
          suggestedFolderId: suggestedFolderId,
          updateTarget: updateTarget,
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
}

class _SaveToFolderDialog extends ConsumerStatefulWidget {
  const _SaveToFolderDialog({
    required this.ref,
    required this.games,
    required this.sourceLabel,
    required this.suggestedFolderId,
    required this.updateTarget,
  });

  final WidgetRef ref;
  final List<ChessGame> games;
  final String sourceLabel;
  final String? suggestedFolderId;
  final LibraryUpdateTarget? updateTarget;

  @override
  ConsumerState<_SaveToFolderDialog> createState() =>
      _SaveToFolderDialogState();
}

class _SaveToFolderDialogState extends ConsumerState<_SaveToFolderDialog> {
  final Set<String> _selected = <String>{};
  final Set<String> _selectedLocalPaths = <String>{};
  bool _isSaving = false;
  int _savedRows = 0;
  int _localWritten = 0;
  bool _isUpdatingOriginal = false;

  // Single-game metadata editor. Only allocated when [widget.games] holds
  // exactly one game, since editing 200 PGN headers from one form does not
  // make sense for bulk imports.
  bool _showGameDetails = true;
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
    if (widget.suggestedFolderId != null) {
      _selected.add(widget.suggestedFolderId!);
    }
    _supportsMetadataEdit = widget.games.length == 1;
    if (_supportsMetadataEdit) {
      _seedMetadataControllers(widget.games.first.metadata);
    }
  }

  void _seedMetadataControllers(Map<String, dynamic> metadata) {
    final whiteParts = splitPlayerName(metadata['White']?.toString());
    final blackParts = splitPlayerName(metadata['Black']?.toString());
    _whiteSurnameCtrl = TextEditingController(text: whiteParts.surname);
    _whiteFirstNameCtrl = TextEditingController(text: whiteParts.firstName);
    _blackSurnameCtrl = TextEditingController(text: blackParts.surname);
    _blackFirstNameCtrl = TextEditingController(text: blackParts.firstName);
    _eventCtrl = TextEditingController(text: metadata['Event']?.toString() ?? '');
    _ecoCtrl = TextEditingController(text: metadata['ECO']?.toString() ?? '');
    _whiteEloCtrl = TextEditingController(
      text: metadata['WhiteElo']?.toString() ?? '',
    );
    _blackEloCtrl = TextEditingController(
      text: metadata['BlackElo']?.toString() ?? '',
    );
    _roundCtrl = TextEditingController(text: metadata['Round']?.toString() ?? '');
    _subroundCtrl = TextEditingController(
      text: metadata['Subround']?.toString() ?? '',
    );
    final dateParts = (metadata['Date']?.toString() ?? '').split('.');
    _yearCtrl = TextEditingController(
      text: (dateParts.isNotEmpty && dateParts[0] != '????') ? dateParts[0] : '',
    );
    _monthCtrl = TextEditingController(
      text: (dateParts.length > 1 && dateParts[1] != '??') ? dateParts[1] : '',
    );
    _dayCtrl = TextEditingController(
      text: (dateParts.length > 2 && dateParts[2] != '??') ? dateParts[2] : '',
    );
    final resultRaw = metadata['Result']?.toString().trim() ?? '';
    _selectedResult = kSupportedPgnResults.contains(resultRaw) ? resultRaw : '*';
  }

  @override
  void dispose() {
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

  Future<void> _onAddLocalFolder() async {
    if (_isSaving) return;
    final directory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose local folder',
      lockParentWindow: true,
    );
    if (directory == null || directory.isEmpty || !mounted) return;
    final registry = ref.read(localLibraryRegistryProvider.notifier);
    final registeredPath = await registry.register(directory);
    if (!mounted) return;
    setState(() {
      _selectedLocalPaths.add(_normalizeLocalPath(registeredPath));
    });
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
    try {
      final repo = ref.read(libraryRepositoryProvider);
      final created = await repo.createFolder(
        name: draft.name,
        parentId: draft.parentId,
      );
      ref.invalidate(libraryFoldersStreamProvider);
      ref.invalidate(subscribedBooksProvider);
      if (!mounted) return;
      setState(() => _selected.add(created.id));
    } catch (e) {
      if (!mounted) return;
      _showToast('Failed to create folder: $e', error: true);
    }
  }

  Future<void> _onUpdateOriginal() async {
    final target = widget.updateTarget;
    if (_isSaving || _isUpdatingOriginal || target == null) return;
    setState(() => _isUpdatingOriginal = true);
    try {
      await target.onUpdate();
      if (!mounted) return;
      Navigator.of(context).pop(
        const LibrarySaveOutcome(
          savedRows: 0,
          folderCount: 0,
          didUpdateOriginal: true,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showToast('Update failed: $e', error: true);
      setState(() => _isUpdatingOriginal = false);
    }
  }

  Future<void> _onSave(
    List<LibraryFolder> selectedFolders,
    List<String> selectedLocalPaths,
  ) async {
    if (_isSaving) return;
    if (selectedFolders.isEmpty && selectedLocalPaths.isEmpty) return;

    final effectiveGames = _gamesForSave();

    // The free-tier cap only applies to cloud rows. Local writes hit disk
    // and never touch the saved_analyses table, so they are exempt.
    final cloudRows = effectiveGames.length * selectedFolders.length;
    if (cloudRows > 0) {
      final allowed = await canSaveMoreGames(context, gamesToAdd: cloudRows);
      if (!allowed || !mounted) return;
    }

    setState(() {
      _isSaving = true;
      _savedRows = 0;
      _localWritten = 0;
    });
    try {
      // Cloud writes first so a disk failure later can be reported with the
      // cloud progress already on screen.
      if (selectedFolders.isNotEmpty) {
        final repo = ref.read(libraryRepositoryProvider);
        final userId = repo.supabase.auth.currentUser?.id;
        if (userId == null) {
          throw Exception(
            'You need to be signed in to save games to the cloud.',
          );
        }

        final now = DateTime.now();
        const chunkSize = 250;
        final rows = <SavedAnalysis>[];
        for (final game in effectiveGames) {
          for (final folder in selectedFolders) {
            rows.add(
              SavedAnalysis(
                id: '',
                userId: userId,
                folderId: folder.id,
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
            );
          }
        }

        for (var i = 0; i < rows.length; i += chunkSize) {
          final end = math.min(i + chunkSize, rows.length);
          final chunk = rows.sublist(i, end);
          await repo.createSavedAnalysesBulk(chunk);
          if (!mounted) return;
          setState(() => _savedRows += chunk.length);
        }

        ref.invalidate(libraryFoldersStreamProvider);
        ref.invalidate(subscribedBooksProvider);
      }

      var localFoldersUsed = 0;
      final localErrors = <String>[];
      if (selectedLocalPaths.isNotEmpty) {
        for (final path in selectedLocalPaths) {
          final writer = LocalLibraryWriter(folderPath: path);
          final outcome = await writer.writeGames(effectiveGames);
          if (!mounted) return;
          if (outcome.written > 0) {
            localFoldersUsed++;
            setState(() => _localWritten += outcome.written);
          }
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

      Navigator.of(context).pop(
        LibrarySaveOutcome(
          savedRows: _savedRows,
          folderCount: selectedFolders.length,
          localFilesWritten: _localWritten,
          localFoldersUsed: localFoldersUsed,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showToast('Save failed: $e', error: true);
      setState(() => _isSaving = false);
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
    final writable = folders
        .where((f) => !f.isSubscribed)
        .toList(growable: false);
    final ordered = _hierarchical(writable);
    final selectedFolders = ordered
        .where((f) => _selected.contains(f.id))
        .toList(growable: false);

    final localEntries = ref.watch(localLibraryRegistryProvider).entries;
    final selectedLocalPaths = localEntries
        .map((e) => e.path)
        .where(
          (path) => _selectedLocalPaths.contains(_normalizeLocalPath(path)),
        )
        .toList(growable: false);

    final cloudRowsTarget = widget.games.length * selectedFolders.length;
    final localFilesTarget = widget.games.length * selectedLocalPaths.length;
    final totalTarget = cloudRowsTarget + localFilesTarget;
    final totalDone = _savedRows + _localWritten;

    final destinationCount = selectedFolders.length + selectedLocalPaths.length;
    final saveLabel =
        _isSaving
            ? 'Saving'
            : destinationCount == 0
            ? 'Pick a destination'
            : 'Save to $destinationCount destination'
                '${destinationCount == 1 ? '' : 's'}';
    final updateTarget = widget.updateTarget;

    return FTheme(
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
                  if (!_isSaving && !_isUpdatingOriginal) {
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
                    title: 'Save to library',
                    subtitle:
                        '${widget.games.length} '
                        '${librarySaveEntryLabel(widget.games.length)} from '
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
                            onCreate: () => _onCreateFolder(writable),
                            onAddLocal:
                                (_isSaving || _isUpdatingOriginal)
                                    ? null
                                    : _onAddLocalFolder,
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
                              if (updateTarget != null) ...[
                                _UpdateOriginalTile(
                                  target: updateTarget,
                                  busy: _isUpdatingOriginal,
                                  disabled: _isSaving,
                                  onTap: _onUpdateOriginal,
                                ),
                                const SizedBox(height: 12),
                              ],
                              if (_supportsMetadataEdit) ...[
                                _buildGameDetailsSection(),
                                const SizedBox(height: 14),
                              ],
                              if (writable.isNotEmpty) ...[
                                const _SectionHeader(
                                  icon: Icons.cloud_outlined,
                                  label: 'CLOUD LIBRARY',
                                ),
                                ...ordered.map(
                                  (folder) => _FolderRow(
                                    folder: folder,
                                    selected: _selected.contains(folder.id),
                                    disabled: _isSaving || _isUpdatingOriginal,
                                    onToggle: () {
                                      setState(() {
                                        if (_selected.contains(folder.id)) {
                                          _selected.remove(folder.id);
                                        } else {
                                          _selected.add(folder.id);
                                        }
                                      });
                                    },
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],
                              _SectionHeader(
                                icon:
                                    Platform.isMacOS
                                        ? Icons.computer_outlined
                                        : Icons.storage_outlined,
                                label:
                                    Platform.isMacOS
                                        ? 'ON THIS MAC'
                                        : 'ON THIS PC',
                              ),
                              ...localEntries.map((entry) {
                                final key = _normalizeLocalPath(entry.path);
                                return _LocalFolderRow(
                                  entry: entry,
                                  selected: _selectedLocalPaths.contains(key),
                                  disabled: _isSaving || _isUpdatingOriginal,
                                  onToggle: () {
                                    setState(() {
                                      if (_selectedLocalPaths.contains(key)) {
                                        _selectedLocalPaths.remove(key);
                                      } else {
                                        _selectedLocalPaths.add(key);
                                      }
                                    });
                                  },
                                  onForget:
                                      (_isSaving || _isUpdatingOriginal)
                                          ? null
                                          : () async {
                                            await ref
                                                .read(
                                                  localLibraryRegistryProvider
                                                      .notifier,
                                                )
                                                .unregister(entry.path);
                                            if (!mounted) return;
                                            setState(() {
                                              _selectedLocalPaths.remove(key);
                                            });
                                          },
                                );
                              }),
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: _AddLocalFolderTile(
                                  onTap:
                                      (_isSaving || _isUpdatingOriginal)
                                          ? null
                                          : _onAddLocalFolder,
                                ),
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
                            child: Text(
                              'Could not load folders: $e',
                              style: const TextStyle(
                                color: kRedColor,
                                fontSize: 12,
                              ),
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
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        DesktopDialogButton(
                          label: 'New folder',
                          icon: Icons.create_new_folder_outlined,
                          onPress:
                              (_isSaving || _isUpdatingOriginal)
                                  ? null
                                  : () => _onCreateFolder(writable),
                        ),
                        Row(
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
                                  (_isSaving ||
                                          _isUpdatingOriginal ||
                                          destinationCount == 0)
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
          _GameDetailsHeader(
            expanded: _showGameDetails,
            onToggle: _isSaving
                ? null
                : () => setState(() => _showGameDetails = !_showGameDetails),
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
                    enabled: !_isSaving,
                  ),
                  const SizedBox(height: 12),
                  _PlayerNameRow(
                    label: 'Black',
                    surnameCtrl: _blackSurnameCtrl!,
                    firstNameCtrl: _blackFirstNameCtrl!,
                    enabled: !_isSaving,
                  ),
                  const SizedBox(height: 12),
                  _FieldLabel(label: 'Tournament'),
                  const SizedBox(height: 6),
                  FTextField(
                    controller: _eventCtrl,
                    enabled: !_isSaving,
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
                              enabled: !_isSaving,
                              hint: 'e.g. C50',
                              textCapitalization:
                                  TextCapitalization.characters,
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
                              enabled: !_isSaving,
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
                              enabled: !_isSaving,
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
                              enabled: !_isSaving,
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
                              enabled: !_isSaving,
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
                              enabled: !_isSaving,
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
                    enabled: !_isSaving,
                    onToday: _isSaving ? null : _fillTodayDate,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Sort folders so each child appears directly after its parent. Falls
  /// back to insertion order when a parent isn't present (e.g. orphan).
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
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: enabled ? onTap : null,
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
                        busy
                            ? 'Updating existing game…'
                            : 'Update existing game',
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
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.onCreate, required this.onAddLocal});
  final VoidCallback onCreate;
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
          const Text(
            'No destinations yet. Save to the cloud library, or pick a '
            'folder on this computer to keep games locally.',
            style: TextStyle(color: kWhiteColor70, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              DesktopDialogButton(
                label: 'Cloud folder',
                icon: Icons.cloud_outlined,
                tone: DesktopDialogButtonTone.primary,
                onPress: onCreate,
              ),
              const SizedBox(width: 10),
              DesktopDialogButton(
                label: 'Local folder',
                icon: Icons.folder_open_outlined,
                onPress: onAddLocal,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
      child: Row(
        children: [
          Icon(icon, size: 12, color: kLightGreyColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
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

class _AddLocalFolderTileState extends State<_AddLocalFolderTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final fg = enabled ? kWhiteColor70 : kLightGreyColor.withValues(alpha: 0.5);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ClickCursor(
        child: MouseRegion(
          onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
          onExit: enabled ? (_) => setState(() => _hovered = false) : null,
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
                  Icon(Icons.folder_open_outlined, color: fg, size: 16),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Choose a folder on this computer…',
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

class _LocalFolderRowState extends State<_LocalFolderRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
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
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.disabled ? null : widget.onToggle,
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
                    Icons.folder_special_outlined,
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
                      tooltip: 'Forget this folder',
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
  merged['Result'] =
      kSupportedPgnResults.contains(result) ? result : '*';
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

class _GameDetailsHeader extends StatelessWidget {
  const _GameDetailsHeader({required this.expanded, required this.onToggle});
  final bool expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Row(
            children: [
              const Icon(
                Icons.edit_note_rounded,
                size: 16,
                color: kLightGreyColor,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'GAME DETAILS',
                  style: TextStyle(
                    color: kLightGreyColor,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              Text(
                expanded ? 'Hide' : 'Edit',
                style: const TextStyle(
                  color: kPrimaryColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                color: kPrimaryColor,
                size: 18,
              ),
            ],
          ),
        ),
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

class _FolderRowState extends State<_FolderRow> {
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
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.disabled ? null : widget.onToggle,
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
