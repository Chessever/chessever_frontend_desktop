import 'dart:convert';

import 'package:chessever/desktop/services/desktop_changelog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAssetBundle extends CachingAssetBundle {
  _FakeAssetBundle(this._content);

  final String? _content;

  @override
  Future<ByteData> load(String key) async {
    final body = _content;
    if (body == null) {
      throw FlutterError('asset missing');
    }
    final bytes = utf8.encode(body);
    return ByteData.view(Uint8List.fromList(bytes).buffer);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Desktop changelog parsing', () {
    test('sorts by impact, hides small polish, and caps at ten entries', () {
      final release = DesktopChangelogRelease(
        version: '10.4.1',
        date: '2026-05-26',
        entries: [
          const DesktopChangelogEntry(
            type: 'Polish',
            impact: 99,
            title: 'Tiny visual polish',
            summary: 'Hidden from the home panel.',
          ),
          const DesktopChangelogEntry(
            type: 'Fixed',
            impact: 59,
            title: 'Small fix',
            summary: 'Below user-impact threshold.',
          ),
          for (var i = 0; i < 12; i++)
            DesktopChangelogEntry(
              type: i.isEven ? 'New' : 'Improved',
              impact: 60 + i,
              title: 'Entry $i',
              summary: 'Visible update $i',
            ),
        ],
      );

      final visible = release.visibleEntries;

      expect(visible, hasLength(10));
      expect(visible.first.title, 'Entry 11');
      expect(visible.last.title, 'Entry 2');
      expect(visible.any((entry) => entry.type == 'Polish'), isFalse);
      expect(visible.any((entry) => entry.impact < 60), isFalse);
    });

    test('bundled v11.1 release has user-facing update entries', () async {
      final release = await loadDesktopChangelogRelease(
        '11.1.0',
        remoteFetcher: (_, __) async => null,
        prefsLoader: SharedPreferences.getInstance,
      );

      expect(release.resolvedTitle(), 'What’s new in ChessEver Desktop v11.1');
      expect(release.visibleEntries, hasLength(7));
      expect(
        release.visibleEntries.first.title,
        'Tournament tabs keep your place',
      );
      expect(
        release.visibleEntries.map((entry) => entry.title),
        containsAll([
          'Open local databases in the current app',
          'Easier My Databases workflow',
          'Select and copy multiple games',
        ]),
      );
      expect(
        release.visibleEntries.map((entry) => entry.title),
        isNot(contains('Editable What’s New')),
      );
      expect(
        release.visibleEntries.map((entry) => entry.title),
        isNot(contains('Official tournament standings')),
      );
    });

    test('returns fallback bug-fix message when version has no release', () {
      final releases = parseDesktopChangelogReleases({
        'releases': [
          {
            'version': '10.4.1',
            'date': '2026-05-26',
            'entries': <Map<String, Object?>>[],
          },
        ],
      });

      final release = releases.firstWhere(
        (release) => release.version == '10.4.2',
        orElse: () => fallbackDesktopChangelogRelease('10.4.2'),
      );

      expect(release.version, '10.4.2');
      expect(
        release.visibleEntries.single.title,
        'Bug fixes and performance improvements',
      );
    });
  });

  group('Resolved title/subtitle', () {
    test('uses remote title/subtitle when provided', () {
      const release = DesktopChangelogRelease(
        version: '10.5.0',
        date: '',
        entries: [],
        title: 'Custom remote title',
        subtitle: 'Custom remote subtitle',
      );

      expect(release.resolvedTitle(), 'Custom remote title');
      expect(release.resolvedSubtitle(), 'Custom remote subtitle');
    });

    test('falls back to default title/subtitle when remote is empty', () {
      const release = DesktopChangelogRelease(
        version: '10.5.0',
        date: '',
        entries: [],
      );

      expect(
        release.resolvedTitle(fallbackVersion: '10.5.0'),
        'What’s new in ChessEver v10.5.0',
      );
      expect(release.resolvedSubtitle(), 'Recent improvements in this release');
    });
  });

  group('loadDesktopChangelogRelease remote pipeline', () {
    test(
      'prefers remote response and caches it for later offline use',
      () async {
        final remote = <String, Object?>{
          'version': '10.5.0',
          'release_date': '2026-05-29',
          'title': 'Hello from Supabase',
          'subtitle': 'Edited without a rebuild',
          'entries': [
            {
              'type': 'New',
              'impact': 91,
              'title': 'Remote release entry',
              'summary': 'Loaded from Supabase.',
            },
          ],
        };

        final release = await loadDesktopChangelogRelease(
          '10.5.0',
          assetBundle: _FakeAssetBundle(null),
          remoteFetcher: (platform, version) async {
            expect(platform, desktopChangelogRemotePlatform);
            expect(version, '10.5.0');
            return remote;
          },
          prefsLoader: SharedPreferences.getInstance,
        );

        expect(release.title, 'Hello from Supabase');
        expect(release.subtitle, 'Edited without a rebuild');
        expect(release.visibleEntries.single.title, 'Remote release entry');

        final prefs = await SharedPreferences.getInstance();
        final cached = prefs.getString(
          '${desktopChangelogCachePrefix}desktop::10.5.0',
        );
        expect(cached, isNotNull);
        final decoded = json.decode(cached!) as Map<String, Object?>;
        expect(decoded['title'], 'Hello from Supabase');
      },
    );

    test('falls back to cached release when remote is unavailable', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '${desktopChangelogCachePrefix}desktop::10.5.0': json.encode({
          'version': '10.5.0',
          'date': '2026-05-29',
          'title': 'Cached title',
          'subtitle': 'Cached subtitle',
          'entries': [
            {
              'type': 'Fixed',
              'impact': 88,
              'title': 'Cached entry',
              'summary': 'Loaded from disk.',
            },
          ],
        }),
      });

      final release = await loadDesktopChangelogRelease(
        '10.5.0',
        assetBundle: _FakeAssetBundle(null),
        remoteFetcher: (_, __) async => null,
        prefsLoader: SharedPreferences.getInstance,
      );

      expect(release.title, 'Cached title');
      expect(release.visibleEntries.single.title, 'Cached entry');
    });

    test('falls back to bundled asset when remote and cache miss', () async {
      final bundled = json.encode({
        'releases': [
          {
            'version': '10.5.0',
            'date': '2026-05-29',
            'entries': [
              {
                'type': 'New',
                'impact': 90,
                'title': 'Bundled entry',
                'summary': 'Shipped with the binary.',
              },
            ],
          },
        ],
      });

      final release = await loadDesktopChangelogRelease(
        '10.5.0',
        assetBundle: _FakeAssetBundle(bundled),
        remoteFetcher: (_, __) async => null,
        prefsLoader: SharedPreferences.getInstance,
      );

      expect(release.visibleEntries.single.title, 'Bundled entry');
      expect(release.title, isNull);
      expect(release.resolvedSubtitle(), 'Recent improvements in this release');
    });

    test('falls back to default message when everything is missing', () async {
      final release = await loadDesktopChangelogRelease(
        '99.9.9',
        assetBundle: _FakeAssetBundle(null),
        remoteFetcher: (_, __) async => null,
        prefsLoader: SharedPreferences.getInstance,
      );

      expect(release.version, '99.9.9');
      expect(
        release.visibleEntries.single.title,
        'Bug fixes and performance improvements',
      );
    });
  });
}
