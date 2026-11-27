import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/state/play_help_modules.dart';
import 'package:chessever/desktop/state/play_help_style.dart';
import 'package:chessever/desktop/state/play_settings_cloud.dart';

class _FakeRemote implements PlaySettingsRemote {
  PlaySettingsUser? user = const PlaySettingsUser(
    id: 'user-a',
    isAnonymous: false,
  );
  Map<String, dynamic>? row;
  bool failSave = false;
  bool failFetch = false;
  final saves = <({Map<String, dynamic> settings, DateTime at})>[];
  final _users = StreamController<String?>.broadcast();

  void signIn(PlaySettingsUser next) {
    user = next;
    _users.add(next.id);
  }

  @override
  PlaySettingsUser? get currentUser => user;

  @override
  Stream<String?> get userChanges => _users.stream;

  @override
  Future<Map<String, dynamic>?> fetch(String userId) async {
    if (failFetch) throw StateError('offline');
    return row == null
        ? null
        : jsonDecode(jsonEncode(row)) as Map<String, dynamic>;
  }

  @override
  Future<void> save(Map<String, dynamic> settings, DateTime updatedAt) async {
    if (failSave) throw StateError('offline');
    saves.add((settings: settings, at: updatedAt));
    row = {
      'settings': jsonDecode(jsonEncode(settings)),
      'settings_updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }
}

Map<String, dynamic> _row(Map<String, dynamic> settings, DateTime at) => {
  'settings': settings,
  'settings_updated_at': at.toUtc().toIso8601String(),
};

Future<ProviderContainer> _container(_FakeRemote remote) async {
  final container = ProviderContainer(
    overrides: [playSettingsRemoteProvider.overrideWithValue(remote)],
  );
  addTearDown(container.dispose);
  container.read(playHelpStyleProvider);
  container.read(playHelpModulesProvider);
  await container.read(playHelpStyleProvider.notifier).restored;
  await container.read(playHelpModulesProvider.notifier).restored;
  // The start-up pass.
  await container.read(playSettingsCloudProvider).syncNow();
  return container;
}

void main() {
  final t0 = DateTime.utc(2026, 11, 1);
  final t1 = DateTime.utc(2026, 11, 2);

  group('section rule', () {
    PlaySettingsSectionAction decide({
      bool remote = true,
      DateTime? remoteAt,
      DateTime? localAt,
      bool foreign = false,
    }) => decidePlaySettingsSection(
      remoteHasSection: remote,
      remoteAt: remoteAt,
      localAt: localAt,
      foreignOwner: foreign,
    );

    test('the newer side wins', () {
      expect(
        decide(remoteAt: t1, localAt: t0),
        PlaySettingsSectionAction.adopt,
      );
      expect(decide(remoteAt: t0, localAt: t1), PlaySettingsSectionAction.push);
      expect(decide(remoteAt: t1, localAt: t1), PlaySettingsSectionAction.keep);
    });

    test('a device that never chose takes the server', () {
      expect(decide(remoteAt: t0), PlaySettingsSectionAction.adopt);
      expect(decide(remoteAt: null), PlaySettingsSectionAction.adopt);
    });

    test('a section without a time does not beat a local choice', () {
      expect(decide(localAt: t0), PlaySettingsSectionAction.push);
    });

    test('a missing server section gets the local choice, if any', () {
      expect(
        decide(remote: false, remoteAt: t1, localAt: t0),
        PlaySettingsSectionAction.push,
      );
      expect(decide(remote: false), PlaySettingsSectionAction.keep);
    });

    test('another account on this device never overwrites the server', () {
      expect(
        decide(remoteAt: t0, localAt: t1, foreign: true),
        PlaySettingsSectionAction.adopt,
      );
    });

    test('another account\'s choice never seeds an empty server', () {
      expect(
        decide(remote: false, localAt: t1, foreign: true),
        PlaySettingsSectionAction.reset,
      );
      expect(
        decide(remote: false, foreign: true),
        PlaySettingsSectionAction.keep,
      );
    });

    test('each section is compared with its own time', () {
      final t10 = DateTime.utc(2026, 11, 27, 10);
      final t1005 = DateTime.utc(2026, 11, 27, 10, 5);
      final t09 = DateTime.utc(2026, 11, 27, 9);
      // Device X changed the style at 10:05; the modules were last
      // changed at 09:00. Device Y changed its modules offline at 10:00.
      final plan = planPlaySettingsSync(
        remoteSettings: {
          'helpStyle': {'level': 'peek', 'hints': 3},
          'helpModules': {'evalBar': true},
          kPlaySettingsSectionTimesKey: {
            'helpStyle': t1005.toIso8601String(),
            'helpModules': t09.toIso8601String(),
          },
        },
        remoteAt: t1005,
        styleLocalAt: t09,
        modulesLocalAt: t10,
        foreignOwner: false,
      );
      expect(plan.style, PlaySettingsSectionAction.adopt);
      expect(plan.remoteStyleAt, t1005);
      expect(plan.modules, PlaySettingsSectionAction.push);
    });

    test('a section without its own time falls back to the row time', () {
      final plan = planPlaySettingsSync(
        remoteSettings: {
          'helpModules': {'evalBar': true},
        },
        remoteAt: t1,
        styleLocalAt: null,
        modulesLocalAt: t0,
        foreignOwner: false,
      );
      expect(plan.modules, PlaySettingsSectionAction.adopt);
      expect(plan.remoteModulesAt, t1);
    });
  });

  group('document', () {
    test('keeps unknown keys at the top and inside sections', () {
      final remote = <String, dynamic>{
        'v': 1,
        'boardTheme': 'walnut',
        'helpStyle': {'level': 'hints', 'hints': 5, 'webOnly': true},
        'helpModules': {'evalBar': true, 'mobileGlow': 3},
      };
      final doc = buildPlaySettingsDocument(
        remoteSettings: remote,
        style: const PlayHelpStyle(level: PlayHelpLevel.peek).toJson(),
      );
      expect(doc['v'], kPlaySettingsVersion);
      expect(doc['boardTheme'], 'walnut');
      expect(doc['helpStyle'], {'level': 'peek', 'hints': 3, 'webOnly': true});
      // Not pushed: the server's section stays as it was.
      expect(doc['helpModules'], {'evalBar': true, 'mobileGlow': 3});
    });

    test('sections round-trip through the document', () {
      const style = PlayHelpStyle(level: PlayHelpLevel.hints, hints: 5);
      const modules = PlayHelpModules(
        evalBar: true,
        tobyBar: true,
        arrows: PlayHelpArrows.toby,
      );
      final doc =
          jsonDecode(
                jsonEncode(
                  buildPlaySettingsDocument(
                    remoteSettings: const {},
                    style: style.toJson(),
                    modules: modules.toJson(),
                  ),
                ),
              )
              as Map<String, dynamic>;
      final plan = planPlaySettingsSync(
        remoteSettings: doc,
        remoteAt: t0,
        styleLocalAt: null,
        modulesLocalAt: null,
        foreignOwner: false,
      );
      expect(PlayHelpStyle.fromJson(plan.remoteStyle!), style);
      expect(PlayHelpModules.fromJson(plan.remoteModules!), modules);
    });

    test('a sent section carries its time; a kept one keeps its own', () {
      final doc = buildPlaySettingsDocument(
        remoteSettings: {
          'helpStyle': {'level': 'peek', 'hints': 3},
          'helpModules': {'evalBar': true},
        },
        modules: const PlayHelpModules(explorer: true).toJson(),
        modulesAt: t1,
        rowAt: t0,
      );
      expect(doc[kPlaySettingsSectionTimesKey], {
        'helpStyle': t0.toIso8601String(),
        'helpModules': t1.toIso8601String(),
      });
      expect(doc['helpStyle'], {'level': 'peek', 'hints': 3});
    });

    test('reads settings_updated_at', () {
      expect(parsePlaySettingsTime('2026-11-02T00:00:00.000Z'), t1);
      expect(parsePlaySettingsTime('2026-11-02T01:00:00+01:00'), t1);
      expect(parsePlaySettingsTime(null), isNull);
      expect(parsePlaySettingsTime('soon'), isNull);
    });
  });

  group('sync', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('adopts newer server settings on start', () async {
      SharedPreferences.setMockInitialValues({
        'desktop.play.helpStyle.v1': jsonEncode(const PlayHelpStyle().toJson()),
        'desktop.play.helpStyle.v1.updatedAt': t0.toIso8601String(),
      });
      final remote =
          _FakeRemote()
            ..row = _row({
              'v': 1,
              'helpStyle': {'level': 'peek', 'hints': 1},
              'helpModules': {'evalBar': true},
            }, t1);
      final container = await _container(remote);
      expect(
        container.read(playHelpStyleProvider),
        const PlayHelpStyle(level: PlayHelpLevel.peek, hints: 1),
      );
      expect(container.read(playHelpModulesProvider).evalBar, isTrue);
      expect(container.read(playHelpStyleProvider.notifier).updatedAt, t1);
      expect(remote.saves, isEmpty);
    });

    test('pushes newer local settings, keeping unknown keys', () async {
      SharedPreferences.setMockInitialValues({
        'desktop.play.helpModules.v1': jsonEncode(
          const PlayHelpModules(explorer: true).toJson(),
        ),
        'desktop.play.helpModules.v1.updatedAt': t1.toIso8601String(),
      });
      final remote =
          _FakeRemote()
            ..row = _row({
              'v': 1,
              'theme': 'dark',
              'helpModules': {'evalBar': true, 'futureKey': 'x'},
            }, t0);
      await _container(remote);
      expect(remote.saves, hasLength(1));
      final saved = remote.saves.single;
      expect(saved.at, t1);
      expect(saved.settings['theme'], 'dark');
      expect(saved.settings['helpModules']['explorer'], isTrue);
      expect(saved.settings['helpModules']['evalBar'], isFalse);
      expect(saved.settings['helpModules']['futureKey'], 'x');
      // Never chosen here and missing on the server: not written.
      expect(saved.settings.containsKey('helpStyle'), isFalse);
    });

    test('changes go up once, after the debounce', () async {
      final remote = _FakeRemote();
      final container = await _container(remote);
      expect(remote.saves, isEmpty);
      final modules = container.read(playHelpModulesProvider.notifier);
      modules.set(const PlayHelpModules(evalBar: true));
      modules.set(const PlayHelpModules(evalBar: true, moveMarks: true));
      container
          .read(playHelpStyleProvider.notifier)
          .set(const PlayHelpStyle(level: PlayHelpLevel.hints, hints: 1));
      await Future<void>.delayed(
        kPlaySettingsPushDelay + const Duration(milliseconds: 300),
      );
      expect(remote.saves, hasLength(1));
      final settings = remote.saves.single.settings;
      expect(settings['helpModules']['moveMarks'], isTrue);
      expect(settings['helpStyle'], {'level': 'hints', 'hints': 1});
    });

    test('a change made offline is sent once the server answers', () async {
      final remote = _FakeRemote()..failSave = true;
      final container = await _container(remote);
      container
          .read(playHelpStyleProvider.notifier)
          .set(const PlayHelpStyle(level: PlayHelpLevel.peek));
      await container.read(playSettingsCloudProvider).syncNow();
      expect(remote.saves, isEmpty);
      expect(container.read(playHelpStyleProvider).level, PlayHelpLevel.peek);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('desktop.play.helpStyle.v1.updatedAt'), isNotNull);

      remote.failSave = false;
      await container.read(playSettingsCloudProvider).syncNow();
      expect(remote.saves, hasLength(1));
      expect(remote.saves.single.settings['helpStyle']['level'], 'peek');
    });

    test('a failed read never overwrites the server', () async {
      SharedPreferences.setMockInitialValues({
        'desktop.play.helpStyle.v1': jsonEncode(
          const PlayHelpStyle(level: PlayHelpLevel.peek).toJson(),
        ),
        'desktop.play.helpStyle.v1.updatedAt': t1.toIso8601String(),
      });
      final remote = _FakeRemote()..failFetch = true;
      await _container(remote);
      expect(remote.saves, isEmpty);
    });

    test('another account signing in gets its own settings', () async {
      SharedPreferences.setMockInitialValues({
        'desktop.play.helpStyle.v1': jsonEncode(
          const PlayHelpStyle(level: PlayHelpLevel.peek).toJson(),
        ),
        'desktop.play.helpStyle.v1.updatedAt': t1.toIso8601String(),
      });
      final remote = _FakeRemote();
      final container = await _container(remote);
      // Account A received this device's choice and now owns it.
      expect(remote.saves, hasLength(1));

      remote.row = _row({
        'v': 1,
        'helpStyle': {'level': 'always', 'hints': 5},
      }, t0);
      remote.signIn(const PlaySettingsUser(id: 'user-b', isAnonymous: false));
      await Future<void>.delayed(Duration.zero);
      await container.read(playSettingsCloudProvider).syncNow();
      expect(
        container.read(playHelpStyleProvider),
        const PlayHelpStyle(hints: 5),
      );
      expect(remote.saves, hasLength(1));
    });

    test('an offline edit to one section survives an edit to the other '
        'on another device', () async {
      final t09 = DateTime.utc(2026, 11, 27, 9);
      final t10 = DateTime.utc(2026, 11, 27, 10);
      final t1005 = DateTime.utc(2026, 11, 27, 10, 5);
      SharedPreferences.setMockInitialValues({
        'desktop.play.helpModules.v1': jsonEncode(
          const PlayHelpModules(explorer: true).toJson(),
        ),
        'desktop.play.helpModules.v1.updatedAt': t10.toIso8601String(),
      });
      // Device X pushed a style change at 10:05; modules date from 09:00.
      final remote =
          _FakeRemote()
            ..row = _row({
              'v': 1,
              'helpStyle': {'level': 'peek', 'hints': 3},
              'helpModules': {'evalBar': true},
              kPlaySettingsSectionTimesKey: {
                'helpStyle': t1005.toIso8601String(),
                'helpModules': t09.toIso8601String(),
              },
            }, t1005);
      final container = await _container(remote);
      expect(container.read(playHelpStyleProvider).level, PlayHelpLevel.peek);
      expect(
        container.read(playHelpModulesProvider.notifier).chosen.explorer,
        isTrue,
      );
      expect(remote.saves, hasLength(1));
      final saved = remote.saves.single;
      expect(saved.settings['helpModules']['explorer'], isTrue);
      expect(saved.settings['helpStyle']['level'], 'peek');
      expect(saved.settings[kPlaySettingsSectionTimesKey], {
        'helpStyle': t1005.toIso8601String(),
        'helpModules': t10.toIso8601String(),
      });
      // The row time never goes backwards.
      expect(saved.at.isAfter(t1005), isTrue);
    });

    test('a new account without settings never gets the previous '
        'account\'s choices', () async {
      SharedPreferences.setMockInitialValues({
        'desktop.play.helpStyle.v1': jsonEncode(
          const PlayHelpStyle(level: PlayHelpLevel.peek).toJson(),
        ),
        'desktop.play.helpStyle.v1.updatedAt': t1.toIso8601String(),
      });
      final remote = _FakeRemote();
      final container = await _container(remote);
      expect(remote.saves, hasLength(1)); // account A owns it now

      remote.row = null; // B has no profile row
      remote.signIn(const PlaySettingsUser(id: 'user-b', isAnonymous: false));
      await Future<void>.delayed(Duration.zero);
      await container.read(playSettingsCloudProvider).syncNow();
      expect(remote.saves, hasLength(1));
      expect(container.read(playHelpStyleProvider), const PlayHelpStyle());
      expect(container.read(playHelpStyleProvider.notifier).updatedAt, isNull);

      // B's own later choice goes up normally.
      container
          .read(playHelpStyleProvider.notifier)
          .set(const PlayHelpStyle(level: PlayHelpLevel.hints));
      await container.read(playSettingsCloudProvider).syncNow();
      expect(remote.saves, hasLength(2));
      expect(remote.saves.last.settings['helpStyle']['level'], 'hints');
    });

    test('a guest\'s choices go up to the account it becomes', () async {
      SharedPreferences.setMockInitialValues({
        'desktop.play.helpStyle.v1': jsonEncode(
          const PlayHelpStyle(level: PlayHelpLevel.hints).toJson(),
        ),
        'desktop.play.helpStyle.v1.updatedAt': t1.toIso8601String(),
      });
      final remote =
          _FakeRemote()
            ..user = const PlaySettingsUser(id: 'guest', isAnonymous: true)
            ..failSave = true;
      final container = await _container(remote);
      remote
        ..failSave = false
        ..row = _row({
          'v': 1,
          'helpStyle': {'level': 'always', 'hints': 3},
        }, t0);
      remote.signIn(const PlaySettingsUser(id: 'user-a', isAnonymous: false));
      await Future<void>.delayed(Duration.zero);
      await container.read(playSettingsCloudProvider).syncNow();
      expect(container.read(playHelpStyleProvider).level, PlayHelpLevel.hints);
      expect(remote.saves.single.settings['helpStyle']['level'], 'hints');
    });
  });
}
