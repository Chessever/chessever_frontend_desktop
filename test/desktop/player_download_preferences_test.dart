import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/models/player_download_preferences.dart';
import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/panes/player_workspace_pane.dart';

void main() {
  test('old profiles retain unrestricted downloads', () {
    final account =
        PlayerWorkspaceAccount.fromJson({
          'source': 'lichess',
          'username': 'prep-player',
          'pgnPath': '/games/player.pgn',
          'gameCount': 12,
        })!;
    expect(account.downloadPreferences.isFiltered, isFalse);
    expect(account.appliedDownloadPreferences.isFiltered, isFalse);
  });

  test(
    'profile persistence retains desired and successfully imported options separately',
    () {
      final desired = PlayerDownloadPreferences(
        timeControls: const {PlayerDownloadTimeControl.blitz},
        fromDate: DateTime.utc(2026, 6, 1),
      );
      final account = PlayerWorkspaceAccount(
        source: PlayerWorkspaceSource.lichess,
        username: 'prep-player',
        downloadPreferences: desired,
      );
      final restored = PlayerWorkspaceAccount.fromJson(account.toJson())!;
      expect(restored.downloadPreferences, desired);
      expect(
        restored.appliedDownloadPreferences,
        const PlayerDownloadPreferences(),
      );
      final imported = restored.copyWith(appliedDownloadPreferences: desired);
      expect(
        PlayerWorkspaceAccount.fromJson(
          imported.toJson(),
        )!.appliedDownloadPreferences,
        desired,
      );
    },
  );

  test('an interrupted Combined refresh remains pending after restart', () {
    const player = PlayerWorkspacePlayer(
      id: 'prep-player',
      displayName: 'Prep Player',
      createdAtMs: 1,
      combinedDownloadOptionsChanged: true,
    );
    expect(
      PlayerWorkspacePlayer.fromJson(
        player.toJson(),
      )!.combinedDownloadOptionsChanged,
      isTrue,
    );
    final legacy = player.toJson()..remove('combinedDownloadOptionsChanged');
    expect(
      PlayerWorkspacePlayer.fromJson(legacy)!.combinedDownloadOptionsChanged,
      isFalse,
    );
  });

  test(
    'inclusive end day and calendar dates do not shift with timezone or DST',
    () {
      final preferences = PlayerDownloadPreferences(
        fromDate: DateTime(2026, 3, 29, 18),
        toDate: DateTime(2026, 3, 29),
      );
      expect(
        preferences.fromMs,
        DateTime.utc(2026, 3, 29).millisecondsSinceEpoch,
      );
      expect(
        preferences.untilMs,
        DateTime.utc(2026, 3, 30).millisecondsSinceEpoch,
      );
      expect(preferences.validationError, isNull);
      expect(
        PlayerDownloadPreferences(
          fromDate: DateTime.utc(2026, 3, 30),
          toDate: DateTime.utc(2026, 3, 29),
        ).validationError,
        isNotNull,
      );
    },
  );

  test(
    'selection equality ignores ordering and dates reject impossible persisted values',
    () {
      expect(
        const PlayerDownloadPreferences(
          timeControls: {
            PlayerDownloadTimeControl.blitz,
            PlayerDownloadTimeControl.rapid,
          },
        ),
        const PlayerDownloadPreferences(
          timeControls: {
            PlayerDownloadTimeControl.rapid,
            PlayerDownloadTimeControl.blitz,
          },
        ),
      );
      expect(
        PlayerDownloadPreferences.fromJson({'fromDate': '2026-02-30'}).fromDate,
        isNull,
      );
    },
  );

  test(
    'a selected subset does not show the whole-profile count as missing games',
    () {
      const preferences = PlayerDownloadPreferences(
        timeControls: {PlayerDownloadTimeControl.blitz},
      );
      const account = PlayerWorkspaceAccount(
        source: PlayerWorkspaceSource.lichess,
        username: 'prep-player',
        availableGameCount: 1000,
        gameCount: 20,
        pgnPath: '/games/player.pgn',
        downloadPreferences: preferences,
        appliedDownloadPreferences: preferences,
      );
      expect(playerWorkspaceAccountGamesLabel(account), '20 downloaded games');
      expect(playerWorkspaceShowsIdleDownloadProgress(account), isFalse);
      expect(
        playerWorkspaceAccountGamesLabel(account.copyWith(gameCount: 0)),
        '0 downloaded games',
      );
    },
  );
}
