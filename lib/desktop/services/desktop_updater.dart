// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:desktop_updater/desktop_updater.dart' as desktop_updater;
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chessever/desktop/services/desktop_shutdown_coordinator.dart';
import 'package:chessever/desktop/services/desktop_update_recovery_marker.dart';
import 'package:chessever/desktop/services/desktop_updater_state.dart';

export 'package:chessever/desktop/services/desktop_updater_state.dart';

/// Cross-platform facade over package:desktop_updater.
///
/// The UI contract stays the same as the previous updater path:
/// background checks silently download the diff archive, the top-left chip
/// appears only after the update is staged, and tapping it hands off to the
/// native restart installer.
class DesktopUpdaterService {
  DesktopUpdaterService._();

  static final DesktopUpdaterService instance = DesktopUpdaterService._();

  static const String _archiveUrl =
      'https://chessever.com/updates/desktop/app-archive.json';
  static const String _downloadPageUrl = 'https://chessever.com/#download';

  static const Duration _checkInterval = Duration(hours: 1);

  static const List<Duration> _retrySchedule = <Duration>[
    Duration(seconds: 60),
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(hours: 1),
  ];

  final ValueNotifier<DesktopUpdateState> state =
      ValueNotifier<DesktopUpdateState>(const DesktopUpdateState.idle());

  final desktop_updater.DesktopUpdater _updater =
      desktop_updater.DesktopUpdater();
  final DesktopUpdateRecoveryMarkerStore _recoveryMarkerStore =
      DesktopUpdateRecoveryMarkerStore();
  final DesktopUpdateStagedDownloadMarkerStore _stagedDownloadStore =
      DesktopUpdateStagedDownloadMarkerStore();
  final DesktopUpdateStageDirectoryCleaner _stageCleaner =
      DesktopUpdateStageDirectoryCleaner();

  bool _initialized = false;
  bool _checking = false;
  String _currentVersion = '';
  desktop_updater.ItemModel? _targetItem;
  String? _stagingPath;
  List<String> _removedFiles = const [];
  Timer? _checkTimer;
  Timer? _retryTimer;
  int _retryAttempt = 0;

  bool get _isSupported => Platform.isMacOS || Platform.isWindows;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final info = await PackageInfo.fromPlatform();
      _currentVersion = DesktopUpdateState.composeReleaseVersion(
        shortVersion: info.version,
        buildNumber: info.buildNumber,
      );
    } catch (_) {
      _currentVersion = '';
    }

    if (!_isSupported) {
      print('[updater] skip: ${Platform.operatingSystem} not supported');
      return;
    }

    final recoveredFailedInstall = await _recoverFailedInstallIfNeeded();
    if (recoveredFailedInstall) {
      _checkTimer?.cancel();
      _checkTimer = Timer.periodic(
        _checkInterval,
        (_) => unawaited(_checkAndDownload(silent: true)),
      );
      unawaited(_cleanupOrphanedStageDirectories());
      print(
        '[updater] previous install handoff did not reach target version; '
        'waiting for manual recovery',
      );
      return;
    }

    await _restoreStagedDownloadIfNeeded();
    unawaited(_cleanupOrphanedStageDirectories());
    unawaited(_checkAndDownload(silent: true));
    _checkTimer?.cancel();
    _checkTimer = Timer.periodic(
      _checkInterval,
      (_) => unawaited(_checkAndDownload(silent: true)),
    );
    print('[updater] desktop_updater initialized for v$_currentVersion');
  }

  /// User-initiated "Check for updates" from Settings.
  Future<void> checkForUpdates() async {
    if (!_isSupported) return;
    if (state.value.requiresManualDownload) {
      await _recoveryMarkerStore.clear();
      _resetRetries();
    }
    await _checkAndDownload(silent: false);
  }

  Future<bool> openDownloadPage() {
    return launchUrl(
      Uri.parse(_downloadPageUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  /// Tap handler for the chip / mandatory-update gate. The update has already
  /// been downloaded into a staging directory; package:desktop_updater schedules
  /// a native helper, quits this process, copies changed files, removes deleted
  /// files, and relaunches the app.
  Future<void> applyUpdate() async {
    if (!_isSupported) return;
    final stagingPath = _stagingPath;
    if (stagingPath == null || stagingPath.isEmpty) {
      state.value = DesktopUpdateState.error(
        'No downloaded update is ready to install',
      );
      return;
    }

    state.value = state.value.copyInstalling();
    final shutdownCoordinator = DesktopShutdownCoordinator.instance;
    try {
      await _writeInstallMarker(stagingPath);
      await shutdownCoordinator?.prepareForExternalTermination();
      await _updater.installUpdate(
        stagingPath: stagingPath,
        removedFiles: _removedFiles,
      );
    } catch (e, stack) {
      print('[updater] install handoff failed: $e');
      print(stack);
      await shutdownCoordinator?.restoreCloseInterception();
      state.value = state.value.copyManualDownloadRequired(
        message:
            'The updater could not hand the downloaded files to the native '
            'installer. Download the latest version from the website.',
        manualDownloadUrl: _downloadPageUrl,
      );
    }
  }

  Future<void> _checkAndDownload({required bool silent}) async {
    if (_checking) return;
    if (silent && state.value.requiresManualDownload) return;
    _checking = true;
    _retryTimer?.cancel();
    if (!silent && !state.value.isReadyToApply) {
      state.value = state.value.copyChecking();
    }

    try {
      final item = await _updater.versionCheck(appArchiveUrl: _archiveUrl);
      if (item == null) {
        await _clearPending(deleteStagedFiles: true);
        state.value = const DesktopUpdateState.idle();
        await _recoveryMarkerStore.clear();
        _resetRetries();
        return;
      }

      final version = _displayVersion(item);
      if (!DesktopUpdateState.isStrictlyNewer(_currentVersion, version)) {
        print(
          '[updater] dropping stale archive '
          '(advertised=$version, current=$_currentVersion)',
        );
        await _clearPending(deleteStagedFiles: true);
        state.value = const DesktopUpdateState.idle();
        await _recoveryMarkerStore.clear();
        _resetRetries();
        return;
      }

      if (_stagingPath != null &&
          state.value.isReadyToApply &&
          state.value.version == version) {
        print('[updater] update $version already staged');
        await _writeStagedDownloadMarker();
        await _recoveryMarkerStore.clear();
        _resetRetries();
        return;
      }

      if (_stagingPath != null && state.value.version != version) {
        await _clearPending(deleteStagedFiles: true);
      }

      _targetItem = item;
      _removedFiles = item.removedFiles;
      final nextState = DesktopUpdateState.available(
        version: version,
        releaseNotes: _formatReleaseNotes(item.changes),
        tier: DesktopUpdateState.classify(_currentVersion, version),
      );
      state.value = nextState;

      await _download(item);
      state.value = nextState.copyDownloaded();
      await _writeStagedDownloadMarker();
      await _recoveryMarkerStore.clear();
      _resetRetries();
    } catch (e, stack) {
      print('[updater] check/download failed: $e');
      print(stack);
      _scheduleRetryOrFallback(reason: e.toString());
    } finally {
      _checking = false;
    }
  }

  Future<void> _download(desktop_updater.ItemModel item) async {
    final changedFiles =
        item.changedFiles ?? const <desktop_updater.FileHashModel?>[];
    _stagingPath = null;

    final stream = await _updater.updateApp(
      remoteUpdateFolder: item.url,
      changedFiles: changedFiles,
    );

    await for (final progress in stream) {
      _stagingPath = progress.stagingDirectory ?? _stagingPath;
      state.value = state.value.copyDownloading(
        progress: progress.fraction,
        receivedBytes: progress.receivedBytes,
        totalBytes: progress.totalBytes,
      );
    }

    if (_stagingPath == null || _stagingPath!.isEmpty) {
      throw StateError('desktop_updater finished without a staging directory');
    }
  }

  void _scheduleRetryOrFallback({required String reason}) {
    _retryTimer?.cancel();

    if (_isTerminalUpdaterFailure(reason) ||
        _retryAttempt >= _retrySchedule.length) {
      _moveToManualDownload(
        'Automatic update could not complete safely. Download the latest '
        'version from the website.',
      );
      return;
    }

    final delay = _retrySchedule[_retryAttempt];
    final nextAttempt = _retryAttempt + 1;
    final nextRetryAt = DateTime.now().add(delay);
    print('[updater] retry #$nextAttempt in ${delay.inSeconds}s ($reason)');
    state.value = _stateWithTargetFallback().copyRetrying(
      message: reason,
      retryAttempt: nextAttempt,
      maxRetryAttempts: _retrySchedule.length,
      nextRetryAt: nextRetryAt,
      manualDownloadUrl: _downloadPageUrl,
    );
    _retryTimer = Timer(delay, () {
      _retryAttempt = nextAttempt;
      unawaited(_checkAndDownload(silent: true));
    });
  }

  void _resetRetries() {
    _retryAttempt = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<void> _clearPending({bool deleteStagedFiles = false}) async {
    final staleStagingPath = _stagingPath;
    _targetItem = null;
    _stagingPath = null;
    _removedFiles = const [];
    await _stagedDownloadStore.clear();
    if (deleteStagedFiles) {
      await _deleteStagedFiles(staleStagingPath);
    }
  }

  bool _isTerminalUpdaterFailure(String reason) {
    final r = reason.toLowerCase();
    return r.contains('downloaded file hash does not match') ||
        r.contains('downloaded file length does not match') ||
        r.contains('finished without a staging directory') ||
        r.contains('no downloaded update is ready') ||
        r.contains('permission denied') ||
        r.contains('operation not permitted');
  }

  void _moveToManualDownload(String message) {
    _retryTimer?.cancel();
    state.value = _stateWithTargetFallback().copyManualDownloadRequired(
      message: message,
      manualDownloadUrl: _downloadPageUrl,
    );
  }

  DesktopUpdateState _stateWithTargetFallback() {
    final current = state.value;
    if (current.hasTargetVersion) return current;

    final item = _targetItem;
    if (item == null) {
      return DesktopUpdateState(
        status: current.status,
        errorMessage: current.errorMessage,
        manualDownloadUrl: _downloadPageUrl,
      );
    }

    final version = _displayVersion(item);
    return DesktopUpdateState.available(
      version: version,
      releaseNotes: _formatReleaseNotes(item.changes),
      tier: DesktopUpdateState.classify(_currentVersion, version),
    );
  }

  Future<bool> _recoverFailedInstallIfNeeded() async {
    final marker = await _recoveryMarkerStore.read();
    if (marker == null) return false;

    if (marker.platform != Platform.operatingSystem) {
      await _recoveryMarkerStore.clear();
      return false;
    }

    if (marker.isSatisfiedBy(_currentVersion)) {
      await _recoveryMarkerStore.clear();
      return false;
    }

    state.value = DesktopUpdateState(
      status: DesktopUpdateStatus.manualDownloadRequired,
      version: marker.targetVersion,
      tier: DesktopUpdateState.classify(
        marker.fromVersion,
        marker.targetVersion,
      ),
      errorMessage:
          'The previous update started, but this launch is still running '
          'the old version. Download the latest version from the website.',
      manualDownloadUrl: _downloadPageUrl,
    );
    return true;
  }

  Future<bool> _restoreStagedDownloadIfNeeded() async {
    final marker = await _stagedDownloadStore.read();
    if (marker == null) return false;

    if (marker.platform != Platform.operatingSystem) {
      await _dropStagedDownloadMarker(marker);
      return false;
    }

    if (marker.isSatisfiedBy(_currentVersion)) {
      await _dropStagedDownloadMarker(marker);
      return false;
    }

    if (!DesktopUpdateState.isStrictlyNewer(
      _currentVersion,
      marker.targetVersion,
    )) {
      await _dropStagedDownloadMarker(marker);
      return false;
    }

    if (!await marker.hasCompleteStagingDirectory()) {
      await _dropStagedDownloadMarker(marker);
      return false;
    }

    _stagingPath = marker.stagingPath;
    _removedFiles = marker.removedFiles;
    state.value =
        DesktopUpdateState.available(
          version: marker.targetVersion,
          releaseNotes: marker.releaseNotes,
          tier: DesktopUpdateState.classify(
            _currentVersion,
            marker.targetVersion,
          ),
        ).copyDownloaded();
    print('[updater] restored staged update ${marker.targetVersion}');
    return true;
  }

  Future<void> _writeInstallMarker(String stagingPath) async {
    final targetVersion = state.value.version;
    if (targetVersion.isEmpty) return;
    await _recoveryMarkerStore.write(
      DesktopUpdateInstallMarker(
        platform: Platform.operatingSystem,
        fromVersion: _currentVersion,
        targetVersion: targetVersion,
        stagingPath: stagingPath,
        createdAt: DateTime.now(),
      ),
    );
  }

  Future<void> _writeStagedDownloadMarker() async {
    final stagingPath = _stagingPath;
    final targetVersion = state.value.version;
    if (stagingPath == null || stagingPath.isEmpty || targetVersion.isEmpty) {
      return;
    }

    await _stagedDownloadStore.write(
      DesktopUpdateStagedDownloadMarker(
        platform: Platform.operatingSystem,
        fromVersion: _currentVersion,
        targetVersion: targetVersion,
        stagingPath: stagingPath,
        removedFiles: _removedFiles,
        releaseNotes: state.value.releaseNotes,
        createdAt: DateTime.now(),
      ),
    );
  }

  Future<void> _dropStagedDownloadMarker(
    DesktopUpdateStagedDownloadMarker marker,
  ) async {
    await _stagedDownloadStore.clear();
    await _deleteStagedFiles(marker.stagingPath);
  }

  Future<void> _cleanupOrphanedStageDirectories() async {
    try {
      await _stageCleaner.deleteOrphaned(keepPath: _stagingPath);
    } catch (e) {
      print('[updater] stage cleanup skipped: $e');
    }
  }

  Future<void> _deleteStagedFiles(String? stagingPath) async {
    if (stagingPath == null || stagingPath.isEmpty) return;
    try {
      await _stageCleaner.deleteIfStageDirectory(stagingPath);
    } catch (e) {
      print('[updater] could not delete stale staging directory: $e');
    }
  }

  String _displayVersion(desktop_updater.ItemModel item) {
    return DesktopUpdateState.composeReleaseVersion(
      shortVersion: item.version,
      buildNumber: item.shortVersion.toString(),
    );
  }

  String _formatReleaseNotes(List<desktop_updater.ChangeModel> changes) {
    return changes
        .map((change) {
          final message = change.message.trim();
          if (message.isEmpty) return '';
          final type = change.type?.trim();
          if (type == null || type.isEmpty) return message;
          return '${type.toUpperCase()}: $message';
        })
        .where((line) => line.isNotEmpty)
        .join('\n');
  }
}

/// Riverpod provider: subscribes to the ValueNotifier and rebuilds dependents
/// whenever the underlying update state changes.
final desktopUpdateStateProvider =
    StateNotifierProvider<_DesktopUpdaterController, DesktopUpdateState>(
      (ref) => _DesktopUpdaterController(),
    );

class _DesktopUpdaterController extends StateNotifier<DesktopUpdateState> {
  _DesktopUpdaterController()
    : super(DesktopUpdaterService.instance.state.value) {
    DesktopUpdaterService.instance.state.addListener(_onChanged);
  }

  void _onChanged() {
    state = DesktopUpdaterService.instance.state.value;
  }

  @override
  void dispose() {
    DesktopUpdaterService.instance.state.removeListener(_onChanged);
    super.dispose();
  }
}
