import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GroupEventCardModel.getCategory', () {
    final now = DateTime.now();

    test('returns live when the strict live resolver marks the event live', () {
      final result = GroupEventCardModel.getCategory(
        groupId: 'event-1',
        groupName: 'Event One',
        startDate: now.subtract(const Duration(days: 2)),
        endDate: now.subtract(const Duration(hours: 6)),
        liveGroupIds: const ['event-1'],
      );

      expect(result, TourEventCategory.live);
    });

    test('returns ongoing when now sits inside the calendar window', () {
      final result = GroupEventCardModel.getCategory(
        groupId: 'event-1',
        startDate: now.subtract(const Duration(days: 30)),
        endDate: now.add(const Duration(days: 60)),
        liveGroupIds: const [],
      );

      expect(result, TourEventCategory.ongoing);
    });

    test('returns completed after date_end', () {
      final result = GroupEventCardModel.getCategory(
        groupId: 'event-1',
        startDate: now.subtract(const Duration(days: 10)),
        endDate: now.subtract(const Duration(days: 1)),
        liveGroupIds: const [],
      );

      expect(result, TourEventCategory.completed);
    });
  });

  group('GroupEventCardModel.asCompleted', () {
    GroupEventCardModel card(TourEventCategory category) {
      final now = DateTime.now();
      return GroupEventCardModel(
        id: 'league',
        title: 'Swiss National League A',
        dates: 'Mar 15 – 11 Oct 2026',
        maxAvgElo: 2512,
        timeUntilStart: '',
        tourEventCategory: category,
        timeControl: 'Standard',
        endDate: now.add(const Duration(days: 60)),
        startDate: now.subtract(const Duration(days: 180)),
      );
    }

    test('overrides ongoing, live, and upcoming for Past-tab cards', () {
      expect(
        card(TourEventCategory.ongoing).asCompleted().tourEventCategory,
        TourEventCategory.completed,
      );
      expect(
        card(TourEventCategory.live).asCompleted().tourEventCategory,
        TourEventCategory.completed,
      );
      expect(
        card(TourEventCategory.upcoming).asCompleted().tourEventCategory,
        TourEventCategory.completed,
      );
    });

    test('is a no-op when the event is already completed', () {
      final completed = card(TourEventCategory.completed);
      expect(identical(completed.asCompleted(), completed), isTrue);
    });
  });
}
