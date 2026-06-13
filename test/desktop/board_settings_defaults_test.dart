import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/board_settings/models/board_settings_model.dart';
import 'package:chessever/utils/board_customization_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BoardSettings notation defaults', () {
    test(
      'new desktop users start blue with letters, inline notation, and no move nav',
      () {
        const settings = BoardSettingsNew();

        expect(settings.boardColorIndex, 6);
        expect(settings.boardThemeIndex, 1);
        expect(settings.boardTheme.name, 'Blue');
        expect(settings.useFigurine, isFalse);
        expect(settings.notationInline, isTrue);
        expect(settings.showMoveNavigation, isFalse);
      },
    );

    test(
      'move navigation can be enabled without changing notation defaults',
      () {
        final settings = const BoardSettingsNew().copyWith(
          showMoveNavigation: true,
        );

        expect(settings.showMoveNavigation, isTrue);
        expect(settings.boardTheme.name, 'Blue');
        expect(settings.notationInline, isTrue);
        expect(settings.useFigurine, isFalse);
      },
    );

    test('invalid board theme indices fall back to blue', () {
      expect(getBoardThemeByIndex(-1).name, 'Blue');
      expect(getBoardThemeByIndex(999).name, 'Blue');
    });

    test('default settings model uses blue board defaults', () {
      final model = BoardSettingsModel.defaultSettings('user-1');

      expect(model.boardColorIndex, 6);
      expect(model.boardThemeIndex, 1);
    });

    test('missing Supabase figurine preference falls back to letters', () {
      final model = BoardSettingsModel.fromSupabase({
        'id': 'settings-1',
        'user_id': 'user-1',
        'created_at': DateTime.utc(2026).toIso8601String(),
        'updated_at': DateTime.utc(2026).toIso8601String(),
      });

      expect(model.useFigurine, isFalse);
      expect(model.boardColorIndex, 6);
      expect(model.boardThemeIndex, 1);
    });

    test('existing saved figurine preference is preserved', () {
      final model = BoardSettingsModel.fromSupabase({
        'id': 'settings-1',
        'user_id': 'user-1',
        'use_figurine': true,
        'created_at': DateTime.utc(2026).toIso8601String(),
        'updated_at': DateTime.utc(2026).toIso8601String(),
      });

      expect(model.useFigurine, isTrue);
    });
  });

  group('Engine settings board overlay defaults', () {
    test('new desktop users start with PV arrows off on the board', () {
      const settings = EngineSettings();

      expect(settings.showPvArrows, isFalse);
    });

    test('explicit saved PV arrow choice is preserved', () {
      const settings = EngineSettings(showPvArrows: true);

      expect(settings.showPvArrows, isTrue);
    });
  });
}
