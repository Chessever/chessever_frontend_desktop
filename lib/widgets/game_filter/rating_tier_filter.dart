/// The Level (minimum-Elo tier) vocabulary shared by smart events and the
/// filter surfaces.
///
/// Ported from the phone's `RatingTierFilter` without its chip widget: the
/// desktop draws its own tier control, but the tier table, the normalization
/// and the labels must stay byte-identical to mobile because saved smart
/// events are named from them.
///
/// Every tier is an open-ended FLOOR on the two-player game average. There is
/// no ceiling: `kFilterMaxElo` (3200) is a UI bound, not a cap.
abstract final class RatingTierFilter {
  static const tiers = <RatingTier>[
    RatingTier(label: 'GM', subtitle: '+2500', minRating: 2500),
    RatingTier(label: 'IM', subtitle: '+2400', minRating: 2400),
    RatingTier(label: 'FM', subtitle: '+2300', minRating: 2300),
    RatingTier(label: 'CM', subtitle: '+2200', minRating: 2200),
  ];

  static int? normalizeMinRating(int? minRating) {
    if (minRating == null) return null;

    for (final tier in tiers) {
      if (minRating >= tier.minRating) return tier.minRating;
    }

    return null;
  }

  static String? labelForMinRating(int? minRating) {
    final normalized = normalizeMinRating(minRating);
    if (normalized == null) return null;

    for (final tier in tiers) {
      if (tier.minRating == normalized) {
        return '${tier.label} ${tier.subtitle}';
      }
    }

    return null;
  }
}

class RatingTier {
  const RatingTier({
    required this.label,
    required this.subtitle,
    required this.minRating,
  });

  final String label;
  final String subtitle;
  final int minRating;
}
