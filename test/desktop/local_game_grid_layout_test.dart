import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/state/local_game_grid_layout.dart';
import 'package:chessever/repository/sqlite/app_database.dart';

class Preferences implements AppDatabase {
  Object? value;
  Completer<void>? readGate;
  int active = 0;
  int maxActive = 0;
  @override
  Future<T?> getJson<T>(String key) async {
    final old = value;
    await readGate?.future;
    return old as T?;
  }

  @override
  Future<void> setJson(String key, Object value) async {
    expect(key, LocalGameGridLayoutNotifier.preferenceKey);
    active++;
    if (active > maxActive) maxActive = active;
    await Future<void>.delayed(Duration.zero);
    this.value = value;
    active--;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'one global layout restores widths order visibility and reset on reopen',
    () async {
      final db = Preferences();
      final first = LocalGameGridLayoutNotifier(db);
      await first.loaded;
      first.update(
        first.state.copyWith(
          order: ['date', 'annotator', 'white'],
          hidden: ['event'],
          widths: {'white': 333},
        ),
      );
      await first.save();
      first.dispose();
      final reopened = LocalGameGridLayoutNotifier(db);
      await reopened.loaded;
      expect(reopened.state.order.take(3), ['date', 'annotator', 'white']);
      expect(reopened.state.widths['white'], 333);
      expect(reopened.state.visible, isNot(contains('event')));
      reopened.reset();
      await reopened.save();
      reopened.dispose();
      final reset = LocalGameGridLayoutNotifier(db);
      await reset.loaded;
      expect(reset.state.order, localGameGridColumns);
      expect(reset.state.hidden, isEmpty);
      expect(reset.state.widths, isEmpty);
      reset.dispose();
    },
  );
  test(
    'late preference hydration cannot overwrite an interaction and writes serialize',
    () async {
      final db = Preferences()..readGate = Completer<void>();
      final n = LocalGameGridLayoutNotifier(db);
      n.update(n.state.copyWith(widths: {'event': 411}));
      final one = n.save();
      n.update(n.state.copyWith(widths: {'event': 512}));
      final two = n.save();
      db.readGate!.complete();
      await Future.wait([one, two]);
      expect(n.state.widths['event'], 512);
      expect(LocalGameGridLayout.fromJson(db.value).widths['event'], 512);
      expect(db.maxActive, 1);
      n.dispose();
    },
  );
  test('invalid saved values cannot remove all columns or poison geometry', () {
    final layout = LocalGameGridLayout.fromJson({
      'version': 1,
      'order': ['white', 'white', 'obsolete'],
      'hidden': localGameGridColumns,
      'widths': {'white': double.nan, 'black': -3, 'event': 99999},
    });
    expect(layout.order.length, localGameGridColumns.length);
    expect(layout.visible, ['originalOrder']);
    expect(layout.widths, {'event': 2400.0});
    expect(
      LocalGameGridLayout.fromJson({'version': 99}).visible,
      localGameGridColumns,
    );
  });
}
