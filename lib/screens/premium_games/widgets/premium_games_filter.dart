import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/app_typography.dart';
import 'package:chessever/utils/haptic_feedback_service.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:chessever/widgets/back_drop_filter_widget.dart';
import 'package:chessever/widgets/game_filter/eco_filter_dropdown.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Shows the premium games filter dialog.
Future<PremiumGamesFilter?> showPremiumGamesFilterDialog({
  required BuildContext context,
  required PremiumGamesType type,
  required PremiumGamesFilter currentFilter,
}) async {
  return showDialog<PremiumGamesFilter>(
    context: context,
    barrierColor: Colors.transparent,
    builder:
        (_) =>
            PremiumGamesFilterDialog(type: type, initialFilter: currentFilter),
  );
}

/// Filter dialog for premium games.
class PremiumGamesFilterDialog extends ConsumerStatefulWidget {
  const PremiumGamesFilterDialog({
    required this.type,
    required this.initialFilter,
    super.key,
  });

  final PremiumGamesType type;
  final PremiumGamesFilter initialFilter;

  @override
  ConsumerState<PremiumGamesFilterDialog> createState() =>
      _PremiumGamesFilterDialogState();
}

class _PremiumGamesFilterDialogState
    extends ConsumerState<PremiumGamesFilterDialog> {
  late PremiumGamesDateRange _dateRange;
  late PremiumGamesResult _result;
  late GameTimeControlFilter _timeControl;
  late GameEcoFilter _eco;
  late GameFinishFilter _finish;
  late int? _selectedMinElo;

  @override
  void initState() {
    super.initState();
    _dateRange = widget.initialFilter.dateRange;
    _result = widget.initialFilter.result;
    _timeControl = widget.initialFilter.timeControl;
    _eco = widget.initialFilter.eco;
    _finish = widget.initialFilter.finish;
    _selectedMinElo = _normalizeRatingPreset(widget.initialFilter.minElo);
  }

  @override
  Widget build(BuildContext context) {
    final dialogWidth = 300.w;
    final horizontalPadding = 20.w;
    final verticalPadding = 16.h;

    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Stack(
        children: [
          const Positioned.fill(child: BackDropFilterWidget()),
          GestureDetector(
            onTap: () {},
            child: Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: EdgeInsets.zero,
              child: Container(
                width: dialogWidth,
                constraints: BoxConstraints(maxHeight: 520.h),
                decoration: BoxDecoration(
                  color: kBlackColor,
                  borderRadius: BorderRadius.circular(12.br),
                  border: Border.all(
                    color: kDarkGreyColor.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: EdgeInsets.only(
                          left: horizontalPadding,
                          right: horizontalPadding,
                          top: verticalPadding,
                          bottom: 0,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Header
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Filters',
                                  style: AppTypography.textMdBold.copyWith(
                                    color: kWhiteColor,
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () => Navigator.pop(context),
                                  child: Icon(
                                    Icons.close_rounded,
                                    color: kWhiteColor.withValues(alpha: 0.6),
                                    size: 20.ic,
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: 20.h),

                            // Standard smart-game filter order.
                            _SectionTitle(title: 'Time control'),
                            SizedBox(height: 8.h),
                            _ChipGrid(
                              items: GameTimeControlFilter.values,
                              selectedItem: _timeControl,
                              getLabel:
                                  (item) =>
                                      item == GameTimeControlFilter.all
                                          ? 'All'
                                          : item.displayText,
                              onSelected: (item) {
                                HapticFeedbackService.selection();
                                setState(() => _timeControl = item);
                              },
                            ),
                            SizedBox(height: 20.h),

                            _SectionTitle(title: 'Avg. Rating'),
                            SizedBox(height: 8.h),
                            _RatingPresetGrid(
                              selectedMinElo: _selectedMinElo,
                              onSelected: (value) {
                                HapticFeedbackService.selection();
                                setState(() => _selectedMinElo = value);
                              },
                            ),
                            SizedBox(height: 20.h),

                            _SectionTitle(title: 'ECO / Opening'),
                            SizedBox(height: 8.h),
                            EcoFilterDropdown(
                              value: _eco,
                              onChanged: (value) {
                                HapticFeedbackService.selection();
                                setState(() => _eco = value);
                              },
                            ),
                            SizedBox(height: 20.h),

                            _SectionTitle(title: 'Finish'),
                            SizedBox(height: 8.h),
                            _ChipGrid(
                              items: GameFinishFilter.values,
                              selectedItem: _finish,
                              getLabel: (item) => item.displayText,
                              onSelected: (item) {
                                HapticFeedbackService.selection();
                                setState(() => _finish = item);
                              },
                            ),
                            SizedBox(height: 20.h),

                            _SectionTitle(title: 'Result'),
                            SizedBox(height: 8.h),
                            _ChipGrid(
                              items: PremiumGamesResult.values,
                              selectedItem: _result,
                              getLabel: (item) => item.displayText,
                              onSelected: (item) {
                                HapticFeedbackService.selection();
                                setState(() => _result = item);
                              },
                            ),
                            SizedBox(height: 20.h),

                            _SectionTitle(title: 'Date range'),
                            SizedBox(height: 8.h),
                            _ChipGrid(
                              items: PremiumGamesDateRange.values,
                              selectedItem: _dateRange,
                              getLabel: (item) => item.displayText,
                              onSelected: (item) {
                                HapticFeedbackService.selection();
                                setState(() => _dateRange = item);
                              },
                            ),
                            SizedBox(height: 16.h),
                          ],
                        ),
                      ),

                      // Buttons
                      Padding(
                        padding: EdgeInsets.all(20.sp),
                        child: Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 44.h,
                                child: OutlinedButton(
                                  onPressed: _resetFilters,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: kWhiteColor,
                                    backgroundColor: kBlack2Color,
                                    side: BorderSide.none,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8.br),
                                    ),
                                  ),
                                  child: Text(
                                    'Reset',
                                    style: AppTypography.textSmMedium.copyWith(
                                      color: kWhiteColor,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(width: 12.sp),
                            Expanded(
                              child: SizedBox(
                                height: 44.h,
                                child: ElevatedButton(
                                  onPressed: _applyFilters,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: kPrimaryColor,
                                    foregroundColor: kBlackColor,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8.br),
                                    ),
                                  ),
                                  child: Text(
                                    'Apply',
                                    style: AppTypography.textSmMedium.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _resetFilters() {
    HapticFeedbackService.buttonPress();
    setState(() {
      _dateRange = PremiumGamesDateRange.allTime;
      _result = PremiumGamesResult.all;
      _timeControl = GameTimeControlFilter.all;
      _eco = GameEcoFilter.all;
      _finish = GameFinishFilter.all;
      _selectedMinElo = null;
    });
  }

  void _applyFilters() {
    HapticFeedbackService.buttonPress();
    final filter = PremiumGamesFilter(
      dateRange: _dateRange,
      result: _result,
      timeControl: _timeControl,
      eco: _eco,
      finish: _finish,
      minElo: _selectedMinElo,
      maxElo: null,
    );
    Navigator.pop(context, filter);
  }
}

int? _normalizeRatingPreset(int? minElo) {
  if (minElo == null) return null;
  for (final preset in _ratingPresets.reversed) {
    if (minElo >= preset) return preset;
  }
  return null;
}

const _ratingPresets = <int>[2200, 2300, 2400, 2500];

class _RatingPresetGrid extends StatelessWidget {
  const _RatingPresetGrid({
    required this.selectedMinElo,
    required this.onSelected,
  });

  final int? selectedMinElo;
  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    final items = <int?>[null, ..._ratingPresets];
    return _ChipGrid<int?>(
      items: items,
      selectedItem: selectedMinElo,
      getLabel: (item) => item == null ? 'Any' : '$item+',
      onSelected: (item) => onSelected(item),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: AppTypography.textXsMedium.copyWith(
        color: kWhiteColor.withValues(alpha: 0.8),
        letterSpacing: 0.3,
      ),
    );
  }
}

class _ChipGrid<T> extends StatelessWidget {
  const _ChipGrid({
    required this.items,
    required this.selectedItem,
    required this.getLabel,
    required this.onSelected,
  });

  final List<T> items;
  final T selectedItem;
  final String Function(T) getLabel;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8.sp,
        crossAxisSpacing: 8.sp,
        childAspectRatio: 3.2,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final isSelected = item == selectedItem;

        return GestureDetector(
          onTap: () => onSelected(item),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isSelected ? kPrimaryColor : kBlack2Color,
              borderRadius: BorderRadius.circular(8.br),
              border: Border.all(
                color:
                    isSelected
                        ? kPrimaryColor
                        : kDarkGreyColor.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Text(
              getLabel(item),
              style: AppTypography.textXsMedium.copyWith(
                color: isSelected ? kBlackColor : kWhiteColor,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        );
      },
    );
  }
}
