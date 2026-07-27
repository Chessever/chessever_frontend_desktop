import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/desktop/services/local_chess_diagnostics.dart';
import 'package:chessever/desktop/services/local_chess_file_access.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';

const Object _localChessUnset = Object();
const Duration _treeProgressMinInterval = Duration(milliseconds: 120);
const double _treeProgressMinFractionDelta = 0.01;
const int _immediatePgnCatalogGameLimit = 200000;

typedef LocalChessPathsScanner =
    Future<LocalChessSource> Function(
      List<String> paths, {
      String? sourceLabel,
      int maxDecodedBytes,
      int maxGames,
      bool buildOpeningTree,
      void Function(LocalChessScanProgress progress)? onProgress,
    });

typedef LocalChessFileNodeScanner =
    Future<LocalChessFileNode> Function({
      required String path,
      required String rootPath,
      int maxDecodedBytes,
      int maxGames,
      bool buildOpeningTree,
      void Function(LocalChessScanProgress progress)? onProgress,
    });

typedef LocalChessPgnCatalogScanner =
    Future<LocalChessSource> Function(
      String path, {
      String? sourceLabel,
      int maxGames,
    });

enum LocalChessTreeBuildPhase { queued, scanning, building, persisting, failed }

@immutable
class LocalChessTreeBuildProgress {
  const LocalChessTreeBuildProgress({
    required this.path,
    required this.phase,
    required double fraction,
    required this.message,
    this.startedAtMs,
    this.updatedAtMs,
    this.error,
  }) : fraction =
           fraction < 0
               ? 0
               : fraction > 1
               ? 1
               : fraction;

  final String path;
  final LocalChessTreeBuildPhase phase;
  final double fraction;
  final String message;
  final int? startedAtMs;
  final int? updatedAtMs;
  final String? error;

  int get percent => (fraction * 100).round().clamp(0, 100).toInt();

  bool get isActive => phase != LocalChessTreeBuildPhase.failed;

  Duration? get estimatedRemaining {
    final started = startedAtMs;
    final updated = updatedAtMs;
    if (started == null ||
        updated == null ||
        fraction < 0.02 ||
        fraction >= 1) {
      return null;
    }
    final elapsedMs = updated - started;
    if (elapsedMs < 1000) return null;
    final remainingMs = (elapsedMs * ((1 - fraction) / fraction)).round();
    if (remainingMs <= 0) return null;
    return Duration(milliseconds: remainingMs);
  }

  String? get compactEta {
    final remaining = estimatedRemaining;
    if (remaining == null) return null;
    final seconds = remaining.inSeconds.clamp(1, 24 * 60 * 60);
    if (seconds < 60) return '~${seconds}s';
    final minutes = (seconds / 60).ceil();
    if (minutes < 60) return '~${minutes}m';
    final hours = minutes ~/ 60;
    final remainder = minutes % 60;
    return remainder == 0 ? '~${hours}h' : '~${hours}h ${remainder}m';
  }
}

@immutable
class LocalChessLibraryState {
  const LocalChessLibraryState({
    this.source,
    this.selectedPath,
    this.isScanning = false,
    this.scanProgress,
    this.error,
    this.warning,
    this.backgroundImports = const <String, LocalChessScanProgress>{},
    this.sessionSources = const <String, LocalChessSource>{},
    this.treeBuilds = const <String, LocalChessTreeBuildProgress>{},
  });

  final LocalChessSource? source;
  final String? selectedPath;
  final bool isScanning;
  final LocalChessScanProgress? scanProgress;
  final String? error;
  final String? warning;
  final Map<String, LocalChessScanProgress> backgroundImports;
  final Map<String, LocalChessSource> sessionSources;
  final Map<String, LocalChessTreeBuildProgress> treeBuilds;

  LocalChessNode? get selectedNode => source?.nodeForPath(selectedPath);

  LocalChessTreeBuildProgress? treeBuildForPath(String? path) {
    if (path == null || path.trim().isEmpty) return null;
    return treeBuilds[localChessInputPathKey(path)];
  }

  LocalChessScanProgress? backgroundImportForPath(String? path) {
    if (path == null || path.trim().isEmpty) return null;
    return backgroundImports[localChessInputPathKey(path)];
  }

  LocalChessSource? sessionSourceForPath(String? path) {
    if (path == null || path.trim().isEmpty) return null;
    return sessionSources[localChessInputPathKey(path)];
  }

  LocalChessLibraryState copyWith({
    Object? source = _localChessUnset,
    Object? selectedPath = _localChessUnset,
    bool? isScanning,
    Object? scanProgress = _localChessUnset,
    Object? error = _localChessUnset,
    Object? warning = _localChessUnset,
    Map<String, LocalChessScanProgress>? backgroundImports,
    Map<String, LocalChessSource>? sessionSources,
    Map<String, LocalChessTreeBuildProgress>? treeBuilds,
  }) {
    return LocalChessLibraryState(
      source:
          identical(source, _localChessUnset)
              ? this.source
              : source as LocalChessSource?,
      selectedPath:
          identical(selectedPath, _localChessUnset)
              ? this.selectedPath
              : selectedPath as String?,
      isScanning: isScanning ?? this.isScanning,
      scanProgress:
          identical(scanProgress, _localChessUnset)
              ? this.scanProgress
              : scanProgress as LocalChessScanProgress?,
      error: identical(error, _localChessUnset) ? this.error : error as String?,
      warning:
          identical(warning, _localChessUnset)
              ? this.warning
              : warning as String?,
      backgroundImports: backgroundImports ?? this.backgroundImports,
      sessionSources: sessionSources ?? this.sessionSources,
      treeBuilds: treeBuilds ?? this.treeBuilds,
    );
  }
}

class LocalChessLibraryNotifier extends StateNotifier<LocalChessLibraryState> {
  LocalChessLibraryNotifier({
    this.registry,
    this.localDatabaseRepository,
    LocalChessPathsScanner? scanPathsWithProgress,
    LocalChessFileNodeScanner? scanFileNodeWithProgress,
    LocalChessPgnCatalogScanner? scanPgnCatalog,
  }) : _scanPathsWithProgress =
           scanPathsWithProgress ?? scanLocalChessPathsWithProgress,
       _scanFileNodeWithProgress =
           scanFileNodeWithProgress ?? scanLocalChessFileNodeWithProgress,
       _scanPgnCatalog = scanPgnCatalog ?? scanLocalChessPgnCatalog,
       super(const LocalChessLibraryState());

  /// Optional registry that records picked/opened local PGNs as persistent
  /// "local databases" the user can save into later. Tests can leave
  /// this null to avoid touching the DB.
  final LocalLibraryRegistryNotifier? registry;
  final LocalChessDatabaseRepository? localDatabaseRepository;
  final LocalChessPathsScanner _scanPathsWithProgress;
  final LocalChessFileNodeScanner _scanFileNodeWithProgress;
  final LocalChessPgnCatalogScanner _scanPgnCatalog;

  Object? _scanToken;
  final Map<String, Object> _backgroundImportTokens = <String, Object>{};
  final Set<String> _activeTreeBuilds = <String>{};
  final Set<String> _pendingTreeBuilds = <String>{};
  final Map<String, OperationCancellationToken> _treeBuildCancellationTokens =
      <String, OperationCancellationToken>{};
  final Map<String, List<Completer<PlayerOpeningTreeIndex?>>>
  _treeBuildWaiters = <String, List<Completer<PlayerOpeningTreeIndex?>>>{};
  int _treeBuildGeneration = 0;

  Future<bool> pickFolder() async {
    final directory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Browse local chess folder',
      lockParentWindow: true,
    );
    if (directory == null || directory.isEmpty) return false;
    return openPaths(<String>[directory]);
  }

  Future<bool> pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Open chess files',
      type: FileType.custom,
      allowedExtensions: localChessPickerExtensions,
      allowMultiple: true,
      withData: false,
      lockParentWindow: true,
    );
    if (result == null || result.files.isEmpty) return false;
    final paths = result.files
        .map((file) => file.path)
        .whereType<String>()
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    if (paths.isEmpty) return false;
    return openPaths(paths, sourceLabel: paths.length == 1 ? null : 'Files');
  }

  Future<bool> openPaths(
    List<String> paths, {
    String? sourceLabel,
    LocalLibraryEntryMetadata? registryMetadata,
    bool forceRefresh = false,
  }) async {
    final token = Object();
    _scanToken = token;
    _invalidateTreeBuilds();
    final sessionSource =
        !forceRefresh && paths.length == 1
            ? state.sessionSourceForPath(paths.single)
            : null;
    if (sessionSource != null) {
      final requestedPath = paths.single;
      state = state.copyWith(
        source: sessionSource,
        selectedPath:
            sessionSource.nodeForPath(requestedPath)?.path ??
            sessionSource.root.path,
        isScanning: false,
        scanProgress: null,
        error: null,
        warning: null,
      );
      return true;
    }
    // Do NOT enter the scanning state up front. A source that was already
    // imported and persisted loads from its warm resqlite cache instantly and
    // must open without ever re-showing the loading popup. Only a genuine cache
    // miss (import/scan) or a slow restore/migration — which emits progress —
    // flips `isScanning` on below.
    state = state.copyWith(error: null, warning: null);
    try {
      final cached = await _loadFreshSourceBestEffort(
        paths,
        sourceLabel: sourceLabel,
        onProgress: (progress) {
          if (_scanToken != token) return;
          state = state.copyWith(
            isScanning: true,
            scanProgress: progress,
            error: null,
          );
        },
      );
      if (_scanToken != token) return false;

      LocalChessSource? source = cached;
      LocalChessSource? imported;
      if (source == null) {
        final repository = localDatabaseRepository;
        final immediatePgnPath = await _immediatePgnCatalogPath(paths);
        if (repository != null && immediatePgnPath != null) {
          final preview = await _scanPgnCatalog(
            immediatePgnPath,
            sourceLabel: sourceLabel,
            maxGames: _immediatePgnCatalogGameLimit,
          );
          if (_scanToken != token) return false;
          final previewOutcome = _localChessSourceOpenOutcome(paths, preview);
          if (previewOutcome.failure != null) throw previewOutcome.failure!;

          var openedSource = preview;
          final previewFile = preview.nodeForPath(immediatePgnPath);
          if (previewFile is LocalChessFileNode) {
            final compactTree = repository
                .loadCompactOpeningTreeIndexForDatabase(
                  databasePath: immediatePgnPath,
                );
            if (compactTree != null && compactTree.isUsable) {
              final replacement = _replaceFileNode(
                preview.root,
                _fileWithOpeningTreeIndex(previewFile, compactTree),
              );
              if (replacement.replaced) {
                openedSource = LocalChessSource(
                  id: preview.id,
                  label: preview.label,
                  paths: preview.paths,
                  rootPath: preview.rootPath,
                  scannedAt: preview.scannedAt,
                  root: replacement.folder,
                );
              }
            }
          }

          state = state.copyWith(
            source: openedSource,
            selectedPath: openedSource.root.path,
            isScanning: false,
            scanProgress: null,
            error: null,
            warning: previewOutcome.warning,
            sessionSources: _sessionSourcesWith(openedSource),
          );
          await _registerAllBestEffort(
            paths,
            source: openedSource,
            registryMetadata: registryMetadata,
          );
          return true;
        }
        // Non-PGN sources and compressed files still require a complete scan,
        // so retain the blocking progress surface for those slower formats.
        state = state.copyWith(
          isScanning: true,
          scanProgress:
              state.scanProgress ??
              LocalChessScanProgress(fraction: 0, message: 'Preparing PGN...'),
          error: null,
        );
        await Future<void>.delayed(Duration.zero);
        imported =
            repository == null
                ? null
                : await _importLocalChessFilePaths(
                  repository,
                  paths,
                  sourceLabel: sourceLabel,
                  token: token,
                );
        if (_scanToken != token) return false;
        source =
            imported ??
            await _scanPathsWithProgress(
              paths,
              sourceLabel: sourceLabel,
              buildOpeningTree: false,
              onProgress: (progress) {
                if (_scanToken != token) return;
                state = state.copyWith(
                  isScanning: true,
                  scanProgress: progress,
                  error: null,
                );
              },
            );
      }
      if (_scanToken != token) {
        return false;
      }
      final outcome = _localChessSourceOpenOutcome(paths, source);
      if (outcome.failure != null) throw outcome.failure!;
      state = state.copyWith(
        source: source,
        selectedPath: source.root.path,
        isScanning: false,
        scanProgress: null,
        error: null,
        warning: outcome.warning,
        sessionSources: _sessionSourcesWith(source),
      );
      await _registerAllBestEffort(
        paths,
        source: source,
        registryMetadata: registryMetadata,
      );
      if (cached == null && imported == null) {
        await _persistSourceBestEffort(source);
      }
      return true;
    } catch (e) {
      if (_scanToken != token) return false;
      state = state.copyWith(
        isScanning: false,
        scanProgress: null,
        error: localChessOpenErrorMessage(e),
        warning: null,
      );
      return false;
    }
  }

  Future<void> refresh() async {
    final source = state.source;
    if (source == null) return;
    await openPaths(
      source.paths,
      sourceLabel: source.label,
      forceRefresh: true,
    );
  }

  Future<bool> refreshFile(String path) async {
    final source = state.source;
    if (source == null) return false;
    final existing = source.nodeForPath(path);
    if (existing is! LocalChessFileNode) return false;

    final token = Object();
    _scanToken = token;
    _invalidateTreeBuilds();
    state = state.copyWith(
      isScanning: true,
      scanProgress: LocalChessScanProgress(
        fraction: 0,
        message: 'Updating local database...',
      ),
      error: null,
    );

    try {
      final rootPath = _rootPathForFileRefresh(source, existing);
      final cached = await _loadFreshFileNodeBestEffort(
        existing.path,
        rootPath: rootPath,
        onProgress: (progress) {
          if (_scanToken != token) return;
          state = state.copyWith(
            isScanning: true,
            scanProgress: progress,
            error: null,
          );
        },
      );
      if (_scanToken != token) return false;
      if (cached != null) {
        final installed = _installRefreshedFile(source, cached);
        if (!installed) {
          state = state.copyWith(isScanning: false, scanProgress: null);
          return false;
        }
        final refreshedSource = state.source;
        if (refreshedSource != null) {
          await _registerAllBestEffort(
            refreshedSource.paths,
            source: refreshedSource,
          );
        }
        return installed;
      }

      final refreshed = await _scanFileNodeWithProgress(
        path: existing.path,
        rootPath: rootPath,
        buildOpeningTree: false,
        onProgress: (progress) {
          if (_scanToken != token) return;
          state = state.copyWith(
            isScanning: true,
            scanProgress: progress,
            error: null,
          );
        },
      );
      if (_scanToken != token) return false;

      final installed = _installRefreshedFile(source, refreshed);
      if (!installed) {
        state = state.copyWith(isScanning: false, scanProgress: null);
        return false;
      }
      await _persistFileNodeBestEffort(refreshed, sourceLabel: source.label);
      if (_scanToken != token) return false;

      final refreshedSource = state.source;
      if (refreshedSource != null) {
        await _registerAllBestEffort(
          refreshedSource.paths,
          source: refreshedSource,
        );
      }
      return installed;
    } catch (e) {
      if (_scanToken != token) return false;
      state = state.copyWith(
        isScanning: false,
        scanProgress: null,
        error: localChessOpenErrorMessage(e),
      );
      return false;
    }
  }

  void selectPath(String path) {
    final source = state.source;
    if (source == null || source.nodeForPath(path) == null) return;
    state = state.copyWith(source: source, selectedPath: path);
  }

  void clear() {
    _scanToken = null;
    _backgroundImportTokens.clear();
    _invalidateTreeBuilds();
    _activeTreeBuilds.clear();
    _pendingTreeBuilds.clear();
    state = const LocalChessLibraryState();
  }

  bool rebuildOpeningTree(String path) {
    final source = state.source;
    if (source == null) return false;
    final node = source.nodeForPath(path);
    if (node is! LocalChessFileNode || !node.isPlayable) return false;
    return _scheduleTreeBuild(node, source, force: true);
  }

  /// Starts an explicit tree rebuild and resolves with that build's usable
  /// index. Background rebuild callers keep using [rebuildOpeningTree], while
  /// user-initiated surfaces can await this result before navigating.
  Future<PlayerOpeningTreeIndex?> rebuildOpeningTreeAndWait(String path) {
    final source = state.source;
    final node = source?.nodeForPath(path);
    if (source == null ||
        node is! LocalChessFileNode ||
        !node.isPlayable ||
        localDatabaseRepository == null) {
      return Future<PlayerOpeningTreeIndex?>.value();
    }

    final key = localChessInputPathKey(path);
    final completer = Completer<PlayerOpeningTreeIndex?>();
    (_treeBuildWaiters[key] ??= <Completer<PlayerOpeningTreeIndex?>>[]).add(
      completer,
    );
    final scheduled = _scheduleTreeBuild(node, source, force: true);
    if (!scheduled && !_activeTreeBuilds.contains(key)) {
      _removeTreeBuildWaiter(key, completer);
      completer.complete();
    }
    return completer.future;
  }

  bool cancelOpeningTreeBuild(String path) {
    final key = localChessInputPathKey(path);
    final token = _treeBuildCancellationTokens[key];
    final wasActive =
        token != null ||
        _activeTreeBuilds.contains(key) ||
        _pendingTreeBuilds.contains(key);
    if (!wasActive) return false;
    _pendingTreeBuilds.remove(key);
    token?.cancel();
    _removeTreeBuildProgress(path);
    _completeTreeBuildWaiters(path, null);
    return true;
  }

  /// Starts the optional searchable cache only when Library search, filtering,
  /// or non-file-order sorting asks for it. Basic browsing and tree building
  /// operate directly from the PGN catalog and never wait for this work.
  bool ensureSearchIndex(String path) {
    final repository = localDatabaseRepository;
    final source = state.source;
    final node = source?.nodeForPath(path);
    if (repository == null ||
        source == null ||
        node is! LocalChessFileNode ||
        !node.isPlayable ||
        node.contentFingerprint.isNotEmpty ||
        node.pgnOffsetIndex == null) {
      return false;
    }
    final key = localChessInputPathKey(path);
    if (_backgroundImportTokens.containsKey(key)) return false;

    final importToken = Object();
    _backgroundImportTokens[key] = importToken;
    final nextBackgroundImports = Map<String, LocalChessScanProgress>.of(
      state.backgroundImports,
    )..[key] = LocalChessScanProgress(
      fraction: 0,
      message: 'Preparing search...',
    );
    state = state.copyWith(
      backgroundImports: Map<String, LocalChessScanProgress>.unmodifiable(
        nextBackgroundImports,
      ),
    );
    unawaited(
      _finishPgnImportInBackground(
        repository,
        path: path,
        sourceLabel: source.label,
        importToken: importToken,
        registryMetadata: null,
      ),
    );
    return true;
  }

  Future<String?> _immediatePgnCatalogPath(List<String> paths) async {
    if (paths.length != 1) return null;
    final path = paths.single.trim();
    if (path.isEmpty || p.extension(path).toLowerCase() != '.pgn') return null;
    try {
      final type = await FileSystemEntity.type(path, followLinks: true);
      if (type != FileSystemEntityType.file) return null;
      return path;
    } on FileSystemException {
      return null;
    }
  }

  Map<String, LocalChessSource> _sessionSourcesWith(LocalChessSource source) {
    final next = Map<String, LocalChessSource>.of(state.sessionSources);

    void rememberNode(LocalChessNode node) {
      next[localChessInputPathKey(node.path)] = source;
      if (node is LocalChessFolderNode) {
        for (final child in node.children) {
          rememberNode(child);
        }
      }
    }

    for (final path in source.paths) {
      next[localChessInputPathKey(path)] = source;
    }
    rememberNode(source.root);
    return Map<String, LocalChessSource>.unmodifiable(next);
  }

  Future<void> _finishPgnImportInBackground(
    LocalChessDatabaseRepository repository, {
    required String path,
    required String? sourceLabel,
    required Object importToken,
    required LocalLibraryEntryMetadata? registryMetadata,
  }) async {
    final key = localChessInputPathKey(path);
    try {
      final imported = await repository.importSingleFileSource(
        path: path,
        sourceLabel: sourceLabel,
        onProgress: (progress) {
          if (!identical(_backgroundImportTokens[key], importToken)) {
            return;
          }
          final next = Map<String, LocalChessScanProgress>.of(
            state.backgroundImports,
          );
          next[key] = progress;
          state = state.copyWith(
            backgroundImports: Map<String, LocalChessScanProgress>.unmodifiable(
              next,
            ),
          );
        },
      );
      if (!identical(_backgroundImportTokens[key], importToken)) return;
      if (imported == null) {
        _finishBackgroundImportWithWarning(
          path,
          importToken,
          'The PGN is open, but its searchable cache could not be completed.',
        );
        return;
      }

      final outcome = _localChessSourceOpenOutcome(<String>[path], imported);
      if (outcome.failure != null) {
        _finishBackgroundImportWithWarning(
          path,
          importToken,
          'The PGN is open, but background indexing failed. '
          '${localChessOpenErrorMessage(outcome.failure!)}',
        );
        return;
      }

      state = state.copyWith(sessionSources: _sessionSourcesWith(imported));
      final importedFile = imported.nodeForPath(path);
      final currentSource = state.source;
      if (importedFile is LocalChessFileNode &&
          currentSource != null &&
          _sourceContainsPath(path)) {
        _installRefreshedFile(currentSource, importedFile);
      }
      _removeBackgroundImport(path, importToken);
      await _registerAllBestEffort(
        <String>[path],
        source: imported,
        registryMetadata: registryMetadata,
      );
    } catch (error, stackTrace) {
      _debugLocalChessCacheFailure(
        'index PGN in background',
        error,
        stackTrace,
      );
      if (!identical(_backgroundImportTokens[key], importToken)) return;
      _finishBackgroundImportWithWarning(
        path,
        importToken,
        'The PGN is open, but background indexing failed. '
        '${localChessOpenErrorMessage(error)}',
      );
    }
  }

  void _finishBackgroundImportWithWarning(
    String path,
    Object importToken,
    String warning,
  ) {
    if (!_sourceContainsPath(path)) {
      _removeBackgroundImport(path, importToken);
      return;
    }
    _removeBackgroundImport(path, importToken);
    state = state.copyWith(warning: warning);
  }

  void _removeBackgroundImport(String path, Object importToken) {
    final key = localChessInputPathKey(path);
    if (!identical(_backgroundImportTokens[key], importToken)) return;
    _backgroundImportTokens.remove(key);
    if (!state.backgroundImports.containsKey(key)) return;
    final next = Map<String, LocalChessScanProgress>.of(state.backgroundImports)
      ..remove(key);
    state = state.copyWith(
      backgroundImports: Map<String, LocalChessScanProgress>.unmodifiable(next),
    );
  }

  /// Imports pure PGN/file lists through the same resqlite cache path single
  /// file import uses. Multi-file picks used to fall straight into the slower
  /// scanner path and skip `importSingleFileSource`, which made large multi-PGN
  /// imports feel stuck and left the cache colder than a single-file import.
  Future<LocalChessSource?> _importLocalChessFilePaths(
    LocalChessDatabaseRepository repository,
    List<String> paths, {
    String? sourceLabel,
    required Object token,
  }) async {
    final filePaths = await _resolvableImportFilePaths(paths);
    if (filePaths == null || filePaths.isEmpty) return null;

    void publish(LocalChessScanProgress progress) {
      if (_scanToken != token) return;
      state = state.copyWith(
        isScanning: true,
        scanProgress: progress,
        error: null,
      );
    }

    if (filePaths.length == 1) {
      return repository.importSingleFileSource(
        path: filePaths.single,
        sourceLabel: sourceLabel,
        onProgress: publish,
      );
    }

    final total = filePaths.length;
    for (var index = 0; index < total; index++) {
      if (_scanToken != token) return null;
      final path = filePaths[index];
      final start = index / total;
      final span = 1 / total;
      final label = p.basename(path);
      publish(
        LocalChessScanProgress(
          fraction: start,
          message: 'Importing file ${index + 1} of $total ($label)...',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final imported = await repository.importSingleFileSource(
        path: path,
        sourceLabel: label,
        onProgress: (progress) {
          publish(
            LocalChessScanProgress(
              fraction:
                  (start + (progress.fraction * span))
                      .clamp(0.0, 1.0)
                      .toDouble(),
              message: 'File ${index + 1} of $total: ${progress.message}',
            ),
          );
        },
      );
      if (imported == null) return null;
    }
    if (_scanToken != token) return null;
    publish(
      LocalChessScanProgress(
        fraction: 0.98,
        message: 'Opening imported databases...',
      ),
    );
    try {
      return await repository.loadFreshSource(
        filePaths,
        sourceLabel: sourceLabel,
        onProgress: publish,
      );
    } catch (error, stackTrace) {
      _debugLocalChessCacheFailure(
        'load multi-file import cache',
        error,
        stackTrace,
      );
      return null;
    }
  }

  Future<List<String>?> _resolvableImportFilePaths(List<String> paths) async {
    if (paths.isEmpty) return null;
    final files = <String>[];
    final seen = <String>{};
    for (final raw in paths) {
      final path = raw.trim();
      if (path.isEmpty || !looksLikeLocalChessFile(path)) return null;
      if (seen.add(localChessInputPathKey(path))) files.add(path);
    }
    return files;
  }

  Future<LocalChessSource?> _loadFreshSourceBestEffort(
    List<String> paths, {
    String? sourceLabel,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    final repository = localDatabaseRepository;
    if (repository == null) return null;
    try {
      return await repository.loadFreshSource(
        paths,
        sourceLabel: sourceLabel,
        onProgress: onProgress,
      );
    } on LocalChessFileAccessException {
      rethrow;
    } catch (error, stackTrace) {
      _debugLocalChessCacheFailure(
        'load local source cache',
        error,
        stackTrace,
      );
      return null;
    }
  }

  Future<LocalChessFileNode?> _loadFreshFileNodeBestEffort(
    String path, {
    required String rootPath,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    final repository = localDatabaseRepository;
    if (repository == null) return null;
    try {
      return await repository.loadFreshFileNode(
        path,
        rootPath: rootPath,
        onProgress: onProgress,
      );
    } on LocalChessFileAccessException {
      rethrow;
    } catch (error, stackTrace) {
      _debugLocalChessCacheFailure('load local file cache', error, stackTrace);
      return null;
    }
  }

  Future<void> _persistSourceBestEffort(LocalChessSource source) async {
    final repository = localDatabaseRepository;
    if (repository == null) return;
    try {
      await repository.persistSource(source);
    } catch (error, stackTrace) {
      _debugLocalChessCacheFailure(
        'persist local source cache',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _persistFileNodeBestEffort(
    LocalChessFileNode file, {
    required String sourceLabel,
  }) async {
    final repository = localDatabaseRepository;
    if (repository == null) return;
    try {
      await repository.persistFileNode(file, sourceLabel: sourceLabel);
    } catch (error, stackTrace) {
      _debugLocalChessCacheFailure(
        'persist local file cache',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _registerAllBestEffort(
    List<String> paths, {
    LocalChessSource? source,
    LocalLibraryEntryMetadata? registryMetadata,
  }) async {
    final localRegistry = registry;
    if (localRegistry == null) return;
    try {
      await localRegistry.registerAll(
        paths,
        metadataByPath:
            source == null
                ? const <String, LocalLibraryEntryMetadata>{}
                : _registryMetadataByPath(
                  source,
                  paths,
                  baseMetadata: registryMetadata,
                ),
      );
    } catch (error, stackTrace) {
      _debugLocalChessCacheFailure('register local files', error, stackTrace);
    }
  }

  Map<String, LocalLibraryEntryMetadata> _registryMetadataByPath(
    LocalChessSource source,
    List<String> paths, {
    LocalLibraryEntryMetadata? baseMetadata,
  }) {
    return <String, LocalLibraryEntryMetadata>{
      for (final path in paths)
        path: LocalLibraryEntryMetadata(
          gameCount: _sourceGameCountForPath(source, path),
          indexedAt: source.scannedAt,
          groupId: baseMetadata?.groupId,
          groupLabel: baseMetadata?.groupLabel,
          playerWorkspaceSource: baseMetadata?.playerWorkspaceSource,
        ),
    };
  }

  int? _sourceGameCountForPath(LocalChessSource source, String path) {
    final node = source.root.find(path);
    return switch (node) {
      LocalChessFolderNode(:final gameCount) => gameCount,
      LocalChessFileNode(:final gameCount) => gameCount,
      _ => source.paths.length == 1 ? source.root.gameCount : null,
    };
  }

  bool _installRefreshedFile(
    LocalChessSource source,
    LocalChessFileNode refreshed,
  ) {
    final replacement = _replaceFileNode(source.root, refreshed);
    if (!replacement.replaced) return false;
    final nextSource = LocalChessSource(
      id: source.id,
      label: source.label,
      paths: source.paths,
      rootPath: source.rootPath,
      scannedAt: DateTime.now(),
      root: replacement.folder,
    );
    final previousSelectedPath = state.selectedPath;
    final nextSelectedPath =
        nextSource.nodeForPath(previousSelectedPath) == null
            ? refreshed.path
            : previousSelectedPath;
    state = state.copyWith(
      source: nextSource,
      selectedPath: nextSelectedPath,
      isScanning: false,
      scanProgress: null,
      error: null,
      sessionSources: _sessionSourcesWith(nextSource),
    );
    return true;
  }

  bool _scheduleTreeBuild(
    LocalChessFileNode file,
    LocalChessSource source, {
    bool force = false,
    Duration delay = Duration.zero,
  }) {
    if (localDatabaseRepository == null) return false;
    if (!file.isPlayable) return false;
    if (!force && file.openingTreeIndex != null) return false;
    final key = localChessInputPathKey(file.path);
    if (!_activeTreeBuilds.add(key)) {
      _pendingTreeBuilds.add(key);
      return false;
    }

    final generation = _treeBuildGeneration;
    final cancellationToken = OperationCancellationToken();
    _treeBuildCancellationTokens[key] = cancellationToken;
    _setTreeBuildProgress(
      LocalChessTreeBuildProgress(
        path: file.path,
        phase: LocalChessTreeBuildPhase.queued,
        fraction: 0,
        message: 'Opening tree queued...',
      ),
    );
    unawaited(
      (() async {
        if (delay > Duration.zero) {
          await Future<void>.delayed(delay);
        }
        if (!_isCurrentTreeBuild(file.path, generation) ||
            cancellationToken.isCanceled) {
          return;
        }
        await _rebuildOpeningTree(
          path: file.path,
          generation: generation,
          cancellationToken: cancellationToken,
        );
      })().whenComplete(() {
        if (identical(_treeBuildCancellationTokens[key], cancellationToken)) {
          _treeBuildCancellationTokens.remove(key);
        }
        _activeTreeBuilds.remove(key);
        if (cancellationToken.isCanceled) {
          _pendingTreeBuilds.remove(key);
          return;
        }
        if (!_pendingTreeBuilds.remove(key)) return;
        final currentSource = state.source;
        final currentNode = currentSource?.nodeForPath(file.path);
        if (currentSource != null &&
            currentNode is LocalChessFileNode &&
            currentNode.openingTreeIndex == null) {
          _scheduleTreeBuild(currentNode, currentSource, force: true);
        }
      }),
    );
    return true;
  }

  Future<void> _rebuildOpeningTree({
    required String path,
    required int generation,
    required OperationCancellationToken cancellationToken,
  }) async {
    final repository = localDatabaseRepository;
    if (repository == null) return;
    final startedAtMs = DateTime.now().millisecondsSinceEpoch;
    var lastProgressFraction = -1.0;
    var lastProgressPhase = LocalChessTreeBuildPhase.queued;
    var lastProgressMessage = '';
    var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);

    void publishProgress(
      LocalChessTreeBuildPhase phase,
      double fraction,
      String message, {
      bool force = false,
    }) {
      if (!_isCurrentTreeBuild(path, generation) ||
          cancellationToken.isCanceled) {
        return;
      }
      final now = DateTime.now();
      final fractionDelta = (fraction - lastProgressFraction).abs();
      final shouldPublish =
          force ||
          phase != lastProgressPhase ||
          message != lastProgressMessage ||
          fraction >= 1 ||
          fractionDelta >= _treeProgressMinFractionDelta ||
          now.difference(lastProgressAt) >= _treeProgressMinInterval;
      if (!shouldPublish) return;
      lastProgressFraction = fraction;
      lastProgressPhase = phase;
      lastProgressMessage = message;
      lastProgressAt = now;
      _setTreeBuildProgress(
        LocalChessTreeBuildProgress(
          path: path,
          phase: phase,
          fraction: fraction,
          message: message,
          startedAtMs: startedAtMs,
          updatedAtMs: now.millisecondsSinceEpoch,
        ),
      );
    }

    try {
      cancellationToken.throwIfCanceled();
      if (!_isCurrentTreeBuild(path, generation)) return;
      publishProgress(
        LocalChessTreeBuildPhase.building,
        0,
        'Preparing PGN tree...',
        force: true,
      );
      final result = await repository.rebuildOpeningTreeFromPgnFile(
        databasePath: path,
        cancellationToken: cancellationToken,
        onProgress: (progress) {
          if (!_isCurrentTreeBuild(path, generation) ||
              cancellationToken.isCanceled) {
            return;
          }
          final progressMessage = progress.message.toLowerCase();
          final phase =
              progressMessage.contains('saving') ||
                      progressMessage.contains('publishing') ||
                      progressMessage.contains('finalizing')
                  ? LocalChessTreeBuildPhase.persisting
                  : LocalChessTreeBuildPhase.building;
          publishProgress(phase, progress.fraction, progress.message);
        },
      );
      cancellationToken.throwIfCanceled();
      if (!_isCurrentTreeBuild(path, generation)) return;
      final index = result?.index;
      if (index == null || !index.isUsable) {
        throw StateError('Opening tree build did not produce an index.');
      }

      final currentSource = state.source;
      final currentNode = currentSource?.nodeForPath(path);
      if (currentSource != null && currentNode is LocalChessFileNode) {
        _installRefreshedFile(
          currentSource,
          _fileWithOpeningTreeIndex(currentNode, index),
        );
      }
      _removeTreeBuildProgress(path);
      _completeTreeBuildWaiters(path, index);
    } catch (e) {
      if (cancellationToken.isCanceled || isOperationCanceled(e)) {
        _removeTreeBuildProgress(path);
        _completeTreeBuildWaiters(path, null);
        return;
      }
      _setTreeBuildProgress(
        LocalChessTreeBuildProgress(
          path: path,
          phase: LocalChessTreeBuildPhase.failed,
          fraction: 0,
          message:
              'Opening tree rebuild failed. Click Build Tree to start over.',
          error: localChessOpenErrorMessage(e),
        ),
      );
      _completeTreeBuildWaiters(path, null);
    }
  }

  LocalChessFileNode _fileWithOpeningTreeIndex(
    LocalChessFileNode file,
    PlayerOpeningTreeIndex index,
  ) {
    return LocalChessFileNode(
      name: file.name,
      path: file.path,
      relativePath: file.relativePath,
      extension: file.extension,
      status: file.status,
      games: file.games,
      gameCount: file.gameCount,
      sizeBytes: file.sizeBytes,
      modifiedAt: file.modifiedAt,
      message: file.message,
      openingTreeIndex: index,
      pgnOffsetIndex: file.pgnOffsetIndex,
      contentFingerprint: file.contentFingerprint,
      isWritableEmptyDatabase: file.isWritableEmptyDatabase,
    );
  }

  void _setTreeBuildProgress(LocalChessTreeBuildProgress progress) {
    if (!_sourceContainsPath(progress.path)) return;
    final next = Map<String, LocalChessTreeBuildProgress>.of(state.treeBuilds);
    next[localChessInputPathKey(progress.path)] = progress;
    state = state.copyWith(treeBuilds: Map.unmodifiable(next));
  }

  void _removeTreeBuildProgress(String path) {
    final key = localChessInputPathKey(path);
    if (!state.treeBuilds.containsKey(key)) return;
    final next = Map<String, LocalChessTreeBuildProgress>.of(state.treeBuilds)
      ..remove(key);
    state = state.copyWith(treeBuilds: Map.unmodifiable(next));
  }

  bool _sourceContainsPath(String path) {
    return state.source?.nodeForPath(path) != null;
  }

  void _invalidateTreeBuilds() {
    _treeBuildGeneration++;
    for (final token in _treeBuildCancellationTokens.values) {
      token.cancel();
    }
    _treeBuildCancellationTokens.clear();
    _pendingTreeBuilds.clear();
    _completeAllTreeBuildWaiters(null);
    if (state.treeBuilds.isNotEmpty) {
      state = state.copyWith(
        treeBuilds: const <String, LocalChessTreeBuildProgress>{},
      );
    }
  }

  void _removeTreeBuildWaiter(
    String key,
    Completer<PlayerOpeningTreeIndex?> completer,
  ) {
    final waiters = _treeBuildWaiters[key];
    waiters?.remove(completer);
    if (waiters?.isEmpty == true) _treeBuildWaiters.remove(key);
  }

  void _completeTreeBuildWaiters(String path, PlayerOpeningTreeIndex? index) {
    final waiters = _treeBuildWaiters.remove(localChessInputPathKey(path));
    if (waiters == null) return;
    for (final completer in waiters) {
      if (!completer.isCompleted) completer.complete(index);
    }
  }

  void _completeAllTreeBuildWaiters(PlayerOpeningTreeIndex? index) {
    final waiters = _treeBuildWaiters.values.expand((items) => items).toList();
    _treeBuildWaiters.clear();
    for (final completer in waiters) {
      if (!completer.isCompleted) completer.complete(index);
    }
  }

  @override
  void dispose() {
    _completeAllTreeBuildWaiters(null);
    super.dispose();
  }

  bool _isCurrentTreeBuild(String path, int generation) {
    return generation == _treeBuildGeneration && _sourceContainsPath(path);
  }
}

final localChessLibraryProvider =
    StateNotifierProvider<LocalChessLibraryNotifier, LocalChessLibraryState>(
      (ref) => LocalChessLibraryNotifier(
        registry: ref.read(localLibraryRegistryProvider.notifier),
        localDatabaseRepository: ref.read(localChessDatabaseRepositoryProvider),
      ),
    );

String localChessOpenErrorMessage(Object error) {
  if (error is LocalChessFileAccessException) {
    return error.userMessage;
  }

  if (error is ArgumentError) {
    final message = error.message;
    if (message != null) {
      final text = message.toString().trim();
      if (text.isNotEmpty) return text;
    }
  }

  if (error is FileSystemException) {
    return LocalChessFileAccessException.from(error).userMessage;
  }

  return error.toString();
}

({Object? failure, String? warning}) _localChessSourceOpenOutcome(
  List<String> requestedPaths,
  LocalChessSource source,
) {
  final issues = <Object>[];
  final issueKeys = <String>{};
  var openableDatabaseCount = 0;

  void addIssue(String key, Object issue) {
    if (issueKeys.add(key)) issues.add(issue);
  }

  void visit(LocalChessNode node) {
    switch (node) {
      case LocalChessFolderNode(:final path, :final children, :final scanError):
        final message = scanError?.trim();
        if (message != null && message.isNotEmpty) {
          final accessError = LocalChessFileAccessException.from(
            message,
            path: path,
          );
          addIssue(
            'folder:${localChessInputPathKey(path)}',
            accessError.issue == LocalChessFileAccessIssue.unknown
                ? ArgumentError(message)
                : accessError,
          );
        }
        for (final child in children) {
          visit(child);
        }
      case LocalChessFileNode(:final status):
        final key = 'file:${localChessInputPathKey(node.path)}';
        switch (status) {
          case LocalChessFileStatus.parsed:
            openableDatabaseCount++;
          case LocalChessFileStatus.noGames:
            if (node.isOpenableDatabase) {
              // A genuinely empty plain PGN is a valid writable destination.
              openableDatabaseCount++;
            } else {
              addIssue(
                key,
                ArgumentError(
                  node.message ??
                      'No playable PGN games were found in this source.',
                ),
              );
            }
          case LocalChessFileStatus.failed:
            final message = node.message ?? 'Could not read this PGN file.';
            final accessError = LocalChessFileAccessException.from(
              message,
              path: node.path,
            );
            addIssue(
              key,
              accessError.issue == LocalChessFileAccessIssue.unknown
                  ? ArgumentError(message)
                  : accessError,
            );
          case LocalChessFileStatus.unsupported:
            addIssue(
              key,
              ArgumentError(node.message ?? localChessUnsupportedFormatMessage),
            );
        }
    }
  }

  visit(source.root);
  for (final rawPath in requestedPaths) {
    final path = rawPath.trim();
    if (path.isEmpty || source.nodeForPath(path) != null) continue;
    addIssue(
      'missing:${localChessInputPathKey(path)}',
      LocalChessFileAccessException(
        issue: LocalChessFileAccessIssue.missing,
        path: path,
      ),
    );
  }

  if (openableDatabaseCount == 0) {
    if (issues.isEmpty) {
      return (
        failure: ArgumentError(
          'No playable PGN databases were found. Choose a PGN containing '
          'chess games and try again.',
        ),
        warning: null,
      );
    }
    if (issues.length == 1) return (failure: issues.single, warning: null);
    final first = localChessOpenErrorMessage(issues.first);
    final remaining = issues.length - 1;
    return (
      failure: ArgumentError(
        'No PGN files could be opened. $first $remaining other '
        '${remaining == 1 ? 'file or folder also failed' : 'files or folders also failed'}.',
      ),
      warning: null,
    );
  }

  if (issues.isEmpty) return (failure: null, warning: null);
  final first = localChessOpenErrorMessage(issues.first);
  final issueCount = issues.length;
  return (
    failure: null,
    warning:
        'Opened ${openableDatabaseCount == 1 ? '1 PGN database' : '$openableDatabaseCount PGN databases'}, '
        'but $issueCount ${issueCount == 1 ? 'file or folder could not be opened' : 'files or folders could not be opened'}. '
        '$first',
  );
}

void _debugLocalChessCacheFailure(
  String operation,
  Object error,
  StackTrace stackTrace,
) {
  // Always log: release-mode library/import failures were previously silent
  // (`kDebugMode` only), which made "works in debug, broken in release"
  // much harder to diagnose.
  localChessLog.warning(
    'Local chess cache $operation failed',
    error: error,
    stackTrace: stackTrace,
  );
  if (kDebugMode) {
    debugPrint('Local chess cache $operation failed: $error\n$stackTrace');
  }
}

({LocalChessFolderNode folder, bool replaced}) _replaceFileNode(
  LocalChessFolderNode folder,
  LocalChessFileNode file,
) {
  var replaced = false;
  final children = <LocalChessNode>[];
  for (final child in folder.children) {
    switch (child) {
      case LocalChessFileNode():
        if (_sameLocalPath(child.path, file.path)) {
          children.add(file);
          replaced = true;
        } else {
          children.add(child);
        }
      case LocalChessFolderNode():
        final nested = _replaceFileNode(child, file);
        if (nested.replaced) {
          children.add(nested.folder);
          replaced = true;
        } else {
          children.add(child);
        }
    }
  }
  if (!replaced) return (folder: folder, replaced: false);
  return (
    folder: LocalChessFolderNode.fromChildren(
      name: folder.name,
      path: folder.path,
      relativePath: folder.relativePath,
      children: children,
      scanError: folder.scanError,
    ),
    replaced: true,
  );
}

String _rootPathForFileRefresh(
  LocalChessSource source,
  LocalChessFileNode file,
) {
  final sourceRoot = source.rootPath.trim();
  if (sourceRoot.isNotEmpty &&
      !_isSyntheticLocalRoot(sourceRoot) &&
      _pathContains(sourceRoot, file.path)) {
    return sourceRoot;
  }

  final relativePath = file.relativePath.trim();
  if (relativePath.isNotEmpty) {
    final normalizedPath = p.normalize(file.path);
    final normalizedRelativePath = p.normalize(relativePath);
    final suffix = '${p.separator}$normalizedRelativePath';
    if (normalizedPath.endsWith(suffix)) {
      final root = normalizedPath.substring(
        0,
        normalizedPath.length - suffix.length,
      );
      if (root.isNotEmpty) return root;
    }
  }

  return p.dirname(file.path);
}

bool _pathContains(String rootPath, String filePath) {
  try {
    return p.equals(rootPath, filePath) || p.isWithin(rootPath, filePath);
  } catch (_) {
    return false;
  }
}

bool _isSyntheticLocalRoot(String path) =>
    path.startsWith('local-file:') || path.startsWith('local-batch:');

bool _sameLocalPath(String a, String b) =>
    localChessInputPathKey(a) == localChessInputPathKey(b);
