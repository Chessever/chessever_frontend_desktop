import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show appBuildName, appBuildNumber;
import 'package:http/http.dart' as http;

import 'package:chessever/desktop/services/desktop_updater_state.dart';

/// Notices when app.chessever.com has a newer deploy than the open tab.
///
/// The web build has nothing to download or install: a reload fetches the
/// live build. All a tab has to learn is that the build it is running is no
/// longer the live one, so it compares the version compiled into it with the
/// `version.json` the deploy serves (Flutter writes it into build/web).
class WebReleaseWatcher {
  WebReleaseWatcher({
    required this.runningVersion,
    required this.onNewerRelease,
    required this.onCurrent,
    Future<String?> Function()? fetchVersionJson,
    DateTime Function()? now,
  }) : _fetchVersionJson = fetchVersionJson ?? _fetchLiveVersionJson,
       _now = now ?? DateTime.now;

  /// The version this tab is running, from [compiledVersion].
  final String runningVersion;

  /// A newer build is live. Called again on later checks while it stays so.
  final void Function(String liveVersion) onNewerRelease;

  /// The live build is not newer than this tab (for example after a
  /// rollback), so any earlier "update available" no longer holds.
  final void Function() onCurrent;

  final Future<String?> Function() _fetchVersionJson;
  final DateTime Function() _now;

  /// Focus checks closer together than this are skipped; the periodic check
  /// still runs.
  static const Duration minFocusGap = Duration(seconds: 30);

  bool _checking = false;
  DateTime? _lastCheck;

  /// The version compiled into this build (`22.19.0+535`), or empty when the
  /// build carries none. Embedded at build time, so unlike `version.json` it
  /// always describes the code that is running, even after a newer deploy.
  static String compiledVersion() {
    final name = appBuildName?.trim() ?? '';
    if (name.isEmpty) return '';
    return DesktopUpdateState.composeReleaseVersion(
      shortVersion: name,
      buildNumber: appBuildNumber?.trim() ?? '',
    );
  }

  /// Parses Flutter's `version.json` into `version+build`, or null when the
  /// body is not one (a Cloudflare challenge page, an error page).
  static String? parseVersionJson(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final version = decoded['version'];
      if (version is! String || version.trim().isEmpty) return null;
      final build = decoded['build_number'];
      return DesktopUpdateState.composeReleaseVersion(
        shortVersion: version.trim(),
        buildNumber: build == null ? '' : build.toString().trim(),
      );
    } on FormatException {
      return null;
    }
  }

  /// Check now if the last check is at least [minFocusGap] old. For the tab
  /// coming back into view, which can fire many times a minute.
  Future<void> checkIfStale() async {
    final last = _lastCheck;
    if (last != null && _now().difference(last) < minFocusGap) return;
    await check();
  }

  /// Fetches the live version and reports how it compares. A failed fetch
  /// changes nothing: the next check tries again.
  Future<void> check() async {
    if (_checking || runningVersion.isEmpty) return;
    _checking = true;
    _lastCheck = _now();
    try {
      final body = await _fetchVersionJson();
      final live = body == null ? null : parseVersionJson(body);
      if (live == null) return;
      if (DesktopUpdateState.isStrictlyNewer(runningVersion, live)) {
        onNewerRelease(live);
      } else {
        onCurrent();
      }
    } catch (_) {
      // Offline, or the edge refused the request. Not worth a message.
    } finally {
      _checking = false;
    }
  }

  static Future<String?> _fetchLiveVersionJson() async {
    // The query string keeps the browser and any cache in between from
    // answering with an old copy; static assets ignore it.
    final uri = Uri.base.resolve(
      '/version.json?t=${DateTime.now().millisecondsSinceEpoch}',
    );
    final response = await http
        .get(uri, headers: const {'Cache-Control': 'no-cache'})
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return null;
    return response.body;
  }
}
