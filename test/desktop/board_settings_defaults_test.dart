import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/repository/board_settings/models/board_settings_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BoardSettings notation defaults', () {
    test(
      'new desktop users start with letters, inline notation, and no move nav',
      () {
        const settings = BoardSettingsNew();

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
        expect(settings.notationInline, isTrue);
        expect(settings.useFigurine, isFalse);
      },
    );

    test('missing Supabase figurine preference falls back to letters', () {
      final model = BoardSettingsModel.fromSupabase({
        'id': 'settings-1',
        'user_id': 'user-1',
        'created_at': DateTime.utc(2026).toIso8601String(),
        'updated_at': DateTime.utc(2026).toIso8601String(),
      });

      expect(model.useFigurine, isFalse);
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
}
