import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/likes/community_likes_models.dart';
import 'package:chessever/desktop/state/community_likes_providers.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';

/// A shared Likes ranking, as the phone writes it
/// (`MostLikedShareUri`): `https://chessever.com/app/likes/<period>`
/// with optional `date=YYYY-MM-DD` (the period's first day) and
/// `view=games|players`. A bare `/app/likes` opens the default ranking.
@immutable
class CommunityLikesLink {
  const CommunityLikesLink({
    this.period = CommunityLikesPeriod.week,
    this.date,
    this.section = CommunityLikesSection.games,
  });

  final CommunityLikesPeriod period;

  /// A local calendar day inside the linked period, or null for the current
  /// one.
  final DateTime? date;
  final CommunityLikesSection section;

  @override
  bool operator ==(Object other) =>
      other is CommunityLikesLink &&
      other.period == period &&
      other.date == date &&
      other.section == section;

  @override
  int get hashCode => Object.hash(period, date, section);
}

/// Parses `/app/likes[/<period>]` and `/likes[/<period>]` on chessever.com
/// ([isWeb]) or `<scheme>://likes[/<period>]`, as strictly as the phone's
/// `parseAppDestination`: a bare `likes` takes no query; a period must be
/// `today|week|month|year` and may only carry `date=YYYY-MM-DD` and
/// `view=games|players`. Anything else is not a Likes link (null).
CommunityLikesLink? parseCommunityLikesLink(Uri uri, {required bool isWeb}) {
  if (uri.userInfo.isNotEmpty || uri.hasFragment) return null;
  final segs = [
    for (final s in uri.pathSegments)
      if (s.isNotEmpty) s,
  ];
  final List<String> rest;
  if (isWeb) {
    if (segs.length >= 2 && segs[0] == 'app' && segs[1] == 'likes') {
      rest = segs.sublist(2);
    } else if (segs.isNotEmpty && segs[0] == 'likes') {
      rest = segs.sublist(1);
    } else {
      return null;
    }
  } else {
    if (uri.host != 'likes') return null;
    rest = segs;
  }
  final query = uri.queryParameters;
  if (rest.isEmpty) {
    return query.isEmpty ? const CommunityLikesLink() : null;
  }
  if (rest.length != 1) return null;
  final period = CommunityLikesPeriod.values
      .where((p) => p.name == rest.first)
      .firstOrNull;
  if (period == null) return null;
  if (query.keys.any((k) => k != 'date' && k != 'view')) return null;

  DateTime? date;
  final rawDate = query['date'];
  if (rawDate != null) {
    final parsed =
        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(rawDate)
            ? DateTime.tryParse(rawDate)
            : null;
    // DateTime.tryParse rolls 2026-02-30 over to March; reject it instead.
    if (parsed == null ||
        '${parsed.year.toString().padLeft(4, '0')}-'
                '${parsed.month.toString().padLeft(2, '0')}-'
                '${parsed.day.toString().padLeft(2, '0')}' !=
            rawDate) {
      return null;
    }
    date = DateTime(parsed.year, parsed.month, parsed.day);
  }
  final view = query['view'];
  if (view != null && view != 'games' && view != 'players') return null;
  return CommunityLikesLink(
    period: period,
    date: date,
    section:
        view == 'players'
            ? CommunityLikesSection.players
            : CommunityLikesSection.games,
  );
}

/// Shows [link]'s ranking in the Likes tab. A date in the future, or one
/// before the first ranked day, falls back to the current period.
void openCommunityLikesLink(
  CommunityLikesLink link,
  ProviderContainer container, {
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  final date = link.date;
  final usable =
      date != null &&
      !date.isAfter(clock) &&
      !date.isBefore(communityLikesDay(kCommunityLikesFirstDay));
  final query = CommunityLikesQuery(link.period, usable ? date : clock);
  container.read(communityLikesPeriodProvider.notifier).state = link.period;
  container.read(communityLikesDayProvider.notifier).state =
      query.isCurrent(clock) ? null : query.start;
  container.read(communityLikesSectionProvider.notifier).state = link.section;
  container.read(desktopTabsProvider.notifier).open(TabKind.likes);
}
