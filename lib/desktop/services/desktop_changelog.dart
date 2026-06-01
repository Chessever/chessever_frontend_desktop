import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const desktopChangelogAssetPath = 'assets/changelog/desktop_releases.json';
const desktopChangelogMaxVisibleEntries = 10;
const desktopChangelogMinimumVisibleImpact = 60;
const desktopChangelogRemoteTable = 'desktop_release_notes';
const desktopChangelogRemotePlatform = 'desktop';
const desktopChangelogCachePrefix = 'desktop_release_notes_cache::';
const desktopChangelogRemoteTimeout = Duration(seconds: 4);

class DesktopChangelogRelease {
  const DesktopChangelogRelease({
    required this.version,
    required this.date,
    required this.entries,
    this.title,
    this.subtitle,
  });

  final String version;
  final String date;
  final List<DesktopChangelogEntry> entries;
  final String? title;
  final String? subtitle;

  String resolvedTitle({String fallbackVersion = ''}) {
    final value = title?.trim();
    if (value != null && value.isNotEmpty) return value;
    final v = version.isNotEmpty ? version : fallbackVersion;
    return 'What’s new in ChessEver v$v';
  }

  String resolvedSubtitle() {
    final value = subtitle?.trim();
    if (value != null && value.isNotEmpty) return value;
    return 'Recent improvements in this release';
  }

  List<DesktopChangelogEntry> get visibleEntries {
    final visible =
        entries
            .where(
              (entry) =>
                  entry.impact >= desktopChangelogMinimumVisibleImpact &&
                  entry.type.toLowerCase() != 'polish',
            )
            .toList()
          ..sort((a, b) {
            final impactComparison = b.impact.compareTo(a.impact);
            if (impactComparison != 0) return impactComparison;
            return a.title.compareTo(b.title);
          });
    return visible.take(desktopChangelogMaxVisibleEntries).toList();
  }

  factory DesktopChangelogRelease.fromJson(Map<String, Object?> json) {
    return DesktopChangelogRelease(
      version: json['version'] as String? ?? '',
      date: (json['date'] ?? json['release_date']) as String? ?? '',
      title: json['title'] as String?,
      subtitle: json['subtitle'] as String?,
      entries:
          (json['entries'] as List? ?? const [])
              .whereType<Map>()
              .map(
                (entry) => DesktopChangelogEntry.fromJson(
                  entry.cast<String, Object?>(),
                ),
              )
              .toList(),
    );
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'date': date,
    if (title != null) 'title': title,
    if (subtitle != null) 'subtitle': subtitle,
    'entries': entries.map((e) => e.toJson()).toList(),
  };
}

class DesktopChangelogEntry {
  const DesktopChangelogEntry({
    required this.type,
    required this.impact,
    required this.title,
    required this.summary,
    this.shortcut,
  });

  final String type;
  final int impact;
  final String title;
  final String summary;
  final String? shortcut;

  factory DesktopChangelogEntry.fromJson(Map<String, Object?> json) {
    return DesktopChangelogEntry(
      type: json['type'] as String? ?? 'Improved',
      impact:
          (json['impact'] as num?)?.round() ??
          desktopChangelogMinimumVisibleImpact,
      title: json['title'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
      shortcut: json['shortcut'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'impact': impact,
    'title': title,
    'summary': summary,
    if (shortcut != null) 'shortcut': shortcut,
  };
}

typedef DesktopChangelogRemoteFetcher = Future<Map<String, Object?>?> Function(
  String platform,
  String version,
);

typedef DesktopChangelogPrefsLoader = Future<SharedPreferences> Function();

Future<Map<String, Object?>?> _defaultRemoteFetcher(
  String platform,
  String version,
) async {
  try {
    final client = Supabase.instance.client;
    final row = await client
        .from(desktopChangelogRemoteTable)
        .select(
          'version, release_date, title, subtitle, entries',
        )
        .eq('platform', platform)
        .eq('version', version)
        .eq('enabled', true)
        .maybeSingle()
        .timeout(desktopChangelogRemoteTimeout);
    if (row == null) return null;
    return Map<String, Object?>.from(row);
  } catch (_) {
    return null;
  }
}

Future<DesktopChangelogRelease> loadDesktopChangelogRelease(
  String appVersion, {
  AssetBundle? assetBundle,
  DesktopChangelogRemoteFetcher? remoteFetcher,
  DesktopChangelogPrefsLoader? prefsLoader,
  String platform = desktopChangelogRemotePlatform,
}) async {
  final fetcher = remoteFetcher ?? _defaultRemoteFetcher;
  final prefs = prefsLoader ?? SharedPreferences.getInstance;
  final cacheKey = '$desktopChangelogCachePrefix$platform::$appVersion';

  final remote = await fetcher(platform, appVersion);
  if (remote != null) {
    final release = _releaseFromRemoteRow(remote, appVersion);
    if (release != null) {
      await _cacheRemoteRelease(prefs, cacheKey, release);
      return release;
    }
  }

  final cached = await _readCachedRelease(prefs, cacheKey);
  if (cached != null) return cached;

  try {
    final raw = await (assetBundle ?? rootBundle).loadString(
      desktopChangelogAssetPath,
    );
    final decoded = json.decode(raw) as Map<String, Object?>;
    final releases = parseDesktopChangelogReleases(decoded);
    return releases.firstWhere(
      (release) => release.version == appVersion,
      orElse: () => fallbackDesktopChangelogRelease(appVersion),
    );
  } catch (_) {
    return fallbackDesktopChangelogRelease(appVersion);
  }
}

DesktopChangelogRelease? _releaseFromRemoteRow(
  Map<String, Object?> row,
  String appVersion,
) {
  final entriesRaw = row['entries'];
  List<Object?> entriesList;
  if (entriesRaw is List) {
    entriesList = entriesRaw;
  } else if (entriesRaw is String && entriesRaw.isNotEmpty) {
    try {
      final decoded = json.decode(entriesRaw);
      entriesList = decoded is List ? decoded : const [];
    } catch (_) {
      return null;
    }
  } else {
    entriesList = const [];
  }

  return DesktopChangelogRelease(
    version: (row['version'] as String?) ?? appVersion,
    date: (row['release_date'] as String?) ?? '',
    title: row['title'] as String?,
    subtitle: row['subtitle'] as String?,
    entries: entriesList
        .whereType<Map>()
        .map(
          (entry) => DesktopChangelogEntry.fromJson(
            entry.cast<String, Object?>(),
          ),
        )
        .toList(),
  );
}

Future<void> _cacheRemoteRelease(
  DesktopChangelogPrefsLoader prefsLoader,
  String cacheKey,
  DesktopChangelogRelease release,
) async {
  try {
    final prefs = await prefsLoader();
    await prefs.setString(cacheKey, json.encode(release.toJson()));
  } catch (_) {
    // Cache failures must not affect the visible panel.
  }
}

Future<DesktopChangelogRelease?> _readCachedRelease(
  DesktopChangelogPrefsLoader prefsLoader,
  String cacheKey,
) async {
  try {
    final prefs = await prefsLoader();
    final raw = prefs.getString(cacheKey);
    if (raw == null || raw.isEmpty) return null;
    final decoded = json.decode(raw);
    if (decoded is! Map) return null;
    return DesktopChangelogRelease.fromJson(
      decoded.cast<String, Object?>(),
    );
  } catch (_) {
    return null;
  }
}

List<DesktopChangelogRelease> parseDesktopChangelogReleases(
  Map<String, Object?> json,
) {
  return (json['releases'] as List? ?? const []).whereType<Map>().map((
    release,
  ) {
    return DesktopChangelogRelease.fromJson(release.cast<String, Object?>());
  }).toList();
}

DesktopChangelogRelease fallbackDesktopChangelogRelease(String appVersion) {
  return DesktopChangelogRelease(
    version: appVersion,
    date: '',
    entries: const [
      DesktopChangelogEntry(
        type: 'Improved',
        impact: 80,
        title: 'Bug fixes and performance improvements',
        summary: 'This release includes reliability and speed improvements.',
      ),
    ],
  );
}
