/// Shared state model for the desktop updater. The runtime uses
/// package:desktop_updater on both macOS and Windows, while the UI keeps the
/// same "silent download, then show an Update button" flow.
class DesktopUpdateState {
  const DesktopUpdateState({
    required this.status,
    this.version = '',
    this.releaseNotes = '',
    this.releaseNotesUrl = '',
    this.tier = DesktopUpdateTier.minor,
    this.errorMessage,
    this.manualDownloadUrl = '',
    this.retryAttempt = 0,
    this.maxRetryAttempts = 0,
    this.nextRetryAt,
    this.progress = 0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
  });

  const DesktopUpdateState.idle() : this(status: DesktopUpdateStatus.idle);

  const DesktopUpdateState.error(String message)
    : this(status: DesktopUpdateStatus.error, errorMessage: message);

  const DesktopUpdateState.available({
    required String version,
    required String releaseNotes,
    String releaseNotesUrl = '',
    DesktopUpdateTier tier = DesktopUpdateTier.minor,
  }) : this(
         status: DesktopUpdateStatus.available,
         version: version,
         releaseNotes: releaseNotes,
         releaseNotesUrl: releaseNotesUrl,
         tier: tier,
       );

  final DesktopUpdateStatus status;
  final String version;
  final String releaseNotes;
  final String releaseNotesUrl;
  final DesktopUpdateTier tier;
  final String? errorMessage;
  final String manualDownloadUrl;
  final int retryAttempt;
  final int maxRetryAttempts;
  final DateTime? nextRetryAt;
  final double progress;
  final double receivedBytes;
  final double totalBytes;

  bool get isMajor => tier == DesktopUpdateTier.major;
  bool get requiresManualDownload =>
      status == DesktopUpdateStatus.manualDownloadRequired;
  bool get isRetrying => status == DesktopUpdateStatus.retrying;
  bool get hasTargetVersion => version.trim().isNotEmpty;

  /// True when the chip / gate should accept a tap to install. `downloaded`
  /// means the diff archive is staged and verified; `installing` is the brief
  /// handoff window before the native helper quits and relaunches the app.
  bool get isReadyToApply =>
      status == DesktopUpdateStatus.downloaded ||
      status == DesktopUpdateStatus.installing;

  DesktopUpdateState copyChecking() => DesktopUpdateState(
    status: DesktopUpdateStatus.checking,
    version: version,
    releaseNotes: releaseNotes,
    releaseNotesUrl: releaseNotesUrl,
    tier: tier,
    manualDownloadUrl: manualDownloadUrl,
    retryAttempt: retryAttempt,
    maxRetryAttempts: maxRetryAttempts,
    nextRetryAt: nextRetryAt,
    progress: progress,
    receivedBytes: receivedBytes,
    totalBytes: totalBytes,
  );

  DesktopUpdateState copyDownloading({
    required double progress,
    required double receivedBytes,
    required double totalBytes,
  }) => DesktopUpdateState(
    status: DesktopUpdateStatus.available,
    version: version,
    releaseNotes: releaseNotes,
    releaseNotesUrl: releaseNotesUrl,
    tier: tier,
    manualDownloadUrl: manualDownloadUrl,
    retryAttempt: retryAttempt,
    maxRetryAttempts: maxRetryAttempts,
    progress: progress,
    receivedBytes: receivedBytes,
    totalBytes: totalBytes,
  );

  DesktopUpdateState copyDownloaded() => DesktopUpdateState(
    status: DesktopUpdateStatus.downloaded,
    version: version,
    releaseNotes: releaseNotes,
    releaseNotesUrl: releaseNotesUrl,
    tier: tier,
    manualDownloadUrl: manualDownloadUrl,
    retryAttempt: retryAttempt,
    maxRetryAttempts: maxRetryAttempts,
    progress: 1,
    receivedBytes: totalBytes,
    totalBytes: totalBytes,
  );

  DesktopUpdateState copyInstalling() => DesktopUpdateState(
    status: DesktopUpdateStatus.installing,
    version: version,
    releaseNotes: releaseNotes,
    releaseNotesUrl: releaseNotesUrl,
    tier: tier,
    manualDownloadUrl: manualDownloadUrl,
    retryAttempt: retryAttempt,
    maxRetryAttempts: maxRetryAttempts,
    progress: progress,
    receivedBytes: receivedBytes,
    totalBytes: totalBytes,
  );

  DesktopUpdateState copyRetrying({
    required String message,
    required int retryAttempt,
    required int maxRetryAttempts,
    required DateTime nextRetryAt,
    required String manualDownloadUrl,
  }) => DesktopUpdateState(
    status: DesktopUpdateStatus.retrying,
    version: version,
    releaseNotes: releaseNotes,
    releaseNotesUrl: releaseNotesUrl,
    tier: tier,
    errorMessage: message,
    manualDownloadUrl: manualDownloadUrl,
    retryAttempt: retryAttempt,
    maxRetryAttempts: maxRetryAttempts,
    nextRetryAt: nextRetryAt,
    progress: progress,
    receivedBytes: receivedBytes,
    totalBytes: totalBytes,
  );

  DesktopUpdateState copyManualDownloadRequired({
    required String message,
    required String manualDownloadUrl,
  }) => DesktopUpdateState(
    status: DesktopUpdateStatus.manualDownloadRequired,
    version: version,
    releaseNotes: releaseNotes,
    releaseNotesUrl: releaseNotesUrl,
    tier: tier,
    errorMessage: message,
    manualDownloadUrl: manualDownloadUrl,
    retryAttempt: retryAttempt,
    maxRetryAttempts: maxRetryAttempts,
    progress: progress,
    receivedBytes: receivedBytes,
    totalBytes: totalBytes,
  );

  /// Compares two semver-ish version strings and returns the upgrade tier.
  /// Falls back to [DesktopUpdateTier.minor] when either side is unparseable
  /// — better to show a regular chip than miss an update entirely.
  static DesktopUpdateTier classify(String current, String next) {
    final c = _parseReleaseVersion(current);
    final n = _parseReleaseVersion(next);
    if (c == null || n == null) return DesktopUpdateTier.minor;
    if (n[0] > c[0]) return DesktopUpdateTier.major;
    if (n[1] > c[1]) return DesktopUpdateTier.minor;
    if (n[2] > c[2] || n[3] > c[3]) return DesktopUpdateTier.patch;
    return DesktopUpdateTier.patch;
  }

  static bool isStrictlyNewer(String current, String next) {
    return compareReleaseVersions(current, next) < 0;
  }

  static bool isAtLeast(String current, String target) {
    return compareReleaseVersions(current, target) >= 0;
  }

  static int compareReleaseVersions(String left, String right) {
    if (right.trim().isEmpty) return 0;
    if (left.trim().isEmpty) return -1;
    final c = _parseReleaseVersion(left);
    final n = _parseReleaseVersion(right);
    if (c == null || n == null) {
      final normalizedLeft = left.trim();
      final normalizedRight = right.trim();
      if (normalizedLeft == normalizedRight) return 0;
      return normalizedLeft.compareTo(normalizedRight);
    }
    for (var i = 0; i < 4; i++) {
      if (c[i] != n[i]) return c[i].compareTo(n[i]);
    }
    return 0;
  }

  static String composeReleaseVersion({
    required String shortVersion,
    String buildNumber = '',
  }) {
    final short = shortVersion.trim();
    final build = buildNumber.trim();
    if (short.isEmpty) return build;
    if (build.isEmpty || build == short || short.contains('+')) return short;
    return '$short+$build';
  }

  static List<int>? _parseReleaseVersion(String v) {
    if (v.isEmpty) return null;
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final buildParts = s.split('+');
    final core = buildParts.first.split('-').first;
    final build = buildParts.length > 1 ? buildParts[1] : '';
    final parts = core.split('.');
    if (parts.isEmpty) return null;
    final out = <int>[0, 0, 0, _buildSortValue(build)];
    for (var i = 0; i < 3 && i < parts.length; i++) {
      final n = int.tryParse(parts[i]);
      if (n == null) return null;
      out[i] = n;
    }
    return out;
  }

  static int _buildSortValue(String build) {
    if (build.isEmpty) return 0;
    if (int.tryParse(build) case final n?) return n;
    final matches = RegExp(r'\d+').allMatches(build).toList();
    if (matches.isEmpty) return 0;
    return int.tryParse(matches.last.group(0) ?? '') ?? 0;
  }
}

enum DesktopUpdateTier { major, minor, patch }

enum DesktopUpdateStatus {
  idle,
  checking,
  available,
  retrying,
  downloaded,
  installing,
  error,
  manualDownloadRequired,
}
