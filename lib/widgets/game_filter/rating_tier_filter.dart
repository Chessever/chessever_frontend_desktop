import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';

class RatingTier {
  const RatingTier({required this.label, required this.minRating});

  final String label;
  final int minRating;
}

class RatingTierFilter extends StatelessWidget {
  const RatingTierFilter({
    super.key,
    required this.selectedMinRating,
    required this.onChanged,
  });

  final int? selectedMinRating;
  final ValueChanged<int> onChanged;

  static const List<RatingTier> tiers = [
    RatingTier(label: 'GM', minRating: 2500),
    RatingTier(label: 'IM', minRating: 2400),
    RatingTier(label: 'FM', minRating: 2300),
    RatingTier(label: 'CM', minRating: 2200),
  ];

  static int? normalizeMinRating(num? minRating) {
    if (minRating == null) return null;
    final rounded = minRating.round();
    for (final tier in tiers) {
      if (rounded == tier.minRating) return tier.minRating;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final tier in tiers)
          ChoiceChip(
            label: Text('${tier.label} ${tier.minRating}+'),
            selected: selectedMinRating == tier.minRating,
            onSelected: (_) => onChanged(tier.minRating),
            selectedColor: kPrimaryColor.withValues(alpha: 0.22),
            backgroundColor: kBlack2Color,
            labelStyle: TextStyle(
              color:
                  selectedMinRating == tier.minRating
                      ? kWhiteColor
                      : kSecondaryTextColor,
              fontWeight: FontWeight.w700,
            ),
            side: BorderSide(
              color:
                  selectedMinRating == tier.minRating
                      ? kPrimaryColor
                      : kDividerColor,
            ),
          ),
      ],
    );
  }
}
