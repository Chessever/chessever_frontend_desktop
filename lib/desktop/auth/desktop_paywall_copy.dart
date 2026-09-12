/// User-facing copy for desktop access decisions.
///
/// Keyed off [DesktopAccessReason.code], never a free-form feature string, so
/// every surface that hits the same rule says the same specific thing. Pure:
/// no widgets, no providers, fully unit-testable.
///
/// Copy rules: name the specific feature or the specific exhausted limit, no
/// em dashes, say less.
library;

import 'package:flutter/foundation.dart' show immutable;

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';

@immutable
class DesktopPaywallCopy {
  const DesktopPaywallCopy({
    required this.title,
    required this.body,
    this.capacityLine,
  });

  /// Short, names the locked thing.
  final String title;

  /// One or two sentences.
  final String body;

  /// "10 of 10 saved games used" for quota decisions, else null.
  final String? capacityLine;
}

/// What Premium adds. Reports and storage are UNLIMITED; Botvinnik is a
/// larger DAILY allowance, not unlimited. Keep the two distinct.
const List<String> desktopPremiumIncludes = <String>[
  'Unlimited game reports, saved games, databases and favourite players',
  'Full games from Countrymen, player profiles, TWIC and the ChessEver database',
  'Explorer past move 10, player scope and exact position search',
  'Prepare, opening trees and engine tournaments',
  'A larger daily Botvinnik allowance',
];

String _plural(int count, String singular, [String? plural]) =>
    count == 1 ? singular : (plural ?? '${singular}s');

String? desktopCapacityLine(DesktopQuotaCapacity? capacity) {
  if (capacity == null) return null;
  final used = capacity.used;
  final limit = capacity.limit;
  switch (capacity.quota) {
    case DesktopQuota.favoritePlayers:
      return '$used of $limit favourite ${_plural(limit, 'player')} used';
    case DesktopQuota.cloudDatabases:
      return '$used of $limit ${_plural(limit, 'database')} used';
    case DesktopQuota.cloudSavedGames:
      return '$used of $limit saved ${_plural(limit, 'game')} used';
    case DesktopQuota.gameReportsPerUtcDay:
      return '$used of $limit ${_plural(limit, 'report')} used today';
    case DesktopQuota.none:
      return null;
  }
}

/// Copy for [decision]. [context] refines paid-source copy (which source)
/// and is optional.
DesktopPaywallCopy desktopPaywallCopyFor(
  DesktopAccessDecision decision, {
  DesktopAccessContext? context,
}) {
  final capacityLine = desktopCapacityLine(decision.capacity);
  switch (decision.outcome) {
    case DesktopAccess.allowed:
      return const DesktopPaywallCopy(
        title: 'Premium is active',
        body: 'You can continue where you left off.',
      );
    case DesktopAccess.checking:
      return const DesktopPaywallCopy(
        title: 'Checking your membership',
        body: 'This usually takes a moment.',
      );
    case DesktopAccess.temporarilyUnavailable:
      return _unavailableCopy(decision.reason, capacityLine);
    case DesktopAccess.accountRequired:
      return decision.reason == DesktopAccessReason.accountRequiredForBotvinnik
          ? const DesktopPaywallCopy(
            title: 'Sign in to talk to Botvinnik',
            body:
                'Botvinnik needs an account so your conversations and daily '
                'allowance follow you across devices.',
          )
          : const DesktopPaywallCopy(
            title: 'Sign in to purchase Premium',
            body:
                'Premium is tied to your account, so it works on every device '
                'you sign in to. Your guest work stays on this computer.',
          );
    case DesktopAccess.premiumRequired:
    case DesktopAccess.quotaExceeded:
      return _premiumCopy(decision.reason, context, capacityLine);
  }
}

DesktopPaywallCopy _unavailableCopy(
  DesktopAccessReason reason,
  String? capacityLine,
) {
  switch (reason) {
    case DesktopAccessReason.usageUnknown:
      return DesktopPaywallCopy(
        title: 'Could not check your free allowance',
        body: 'Nothing was changed. Check your connection and retry.',
        capacityLine: capacityLine,
      );
    case DesktopAccessReason.contentDateUnknown:
      return const DesktopPaywallCopy(
        title: 'Could not read when this game was liked',
        body: 'Nothing was changed. Retry in a moment.',
      );
    case DesktopAccessReason.explorerDepthUnknown:
      return const DesktopPaywallCopy(
        title: 'Could not read this position',
        body: 'Nothing was changed. Retry in a moment.',
      );
    case DesktopAccessReason.staleEntitlement:
      return const DesktopPaywallCopy(
        title: 'Your account changed',
        body: 'Start the action again from where you left off.',
      );
    default:
      return DesktopPaywallCopy(
        title: 'Membership could not be verified',
        body:
            'Your saved work is unchanged. Check your connection and retry.',
        capacityLine: capacityLine,
      );
  }
}

String _sourceName(DesktopAccessContext? context) {
  final origin = context?.origin;
  switch (origin) {
    case DesktopDiscoveryOrigin.countrymen:
      return 'Countrymen';
    case DesktopDiscoveryOrigin.smartCollection:
      return 'smart collections';
    case DesktopDiscoveryOrigin.playerProfile:
      return 'player profiles';
    case DesktopDiscoveryOrigin.twic:
      return 'TWIC';
    case DesktopDiscoveryOrigin.gamebase:
      return 'the ChessEver database';
    default:
      break;
  }
  switch (context?.feature) {
    case DesktopFeature.countrymen:
      return 'Countrymen';
    case DesktopFeature.smartCollection:
      return 'smart collections';
    case DesktopFeature.playerProfile:
      return 'player profiles';
    case DesktopFeature.twic:
      return 'TWIC';
    default:
      return 'the ChessEver database';
  }
}

String _contentVerb(DesktopAccessContext? context) {
  switch (context?.action) {
    case DesktopAction.previewNavigate:
      return 'Stepping through games';
    case DesktopAction.fetchPgn:
    case DesktopAction.insertMove:
      return 'Loading moves from games';
    case DesktopAction.copy:
      return 'Copying games';
    case DesktopAction.save:
      return 'Saving games';
    case DesktopAction.share:
      return 'Sharing games';
    case DesktopAction.export:
      return 'Exporting games';
    default:
      return 'Opening games';
  }
}

DesktopPaywallCopy _premiumCopy(
  DesktopAccessReason reason,
  DesktopAccessContext? context,
  String? capacityLine,
) {
  switch (reason) {
    case DesktopAccessReason.premiumPaidSource when context == null:
      // Legacy shared guards that do not pass a request yet.
      return const DesktopPaywallCopy(
        title: 'This is part of Premium',
        body: 'Everything you already have stays available.',
      );
    case DesktopAccessReason.premiumPaidSource:
      return DesktopPaywallCopy(
        title:
            '${_contentVerb(context)} from ${_sourceName(context)} is Premium',
        body:
            'Browsing the list stays free. Games you already saved to your '
            'own library stay open to you.',
      );
    case DesktopAccessReason.premiumPrepareTarget:
      return const DesktopPaywallCopy(
        title: 'Adding preparation targets is Premium',
        body:
            'Players you already prepared stay here to browse, rename, remove '
            'and export.',
      );
    case DesktopAccessReason.premiumPrepareSource:
      return const DesktopPaywallCopy(
        title: 'Downloading and syncing prep games is Premium',
        body:
            'Connecting Lichess, Chess.com or ChessEver sources, refreshing '
            'and reinstalling them needs Premium. Files you already have stay '
            'available.',
      );
    case DesktopAccessReason.premiumPrepareComputed:
      return const DesktopPaywallCopy(
        title: 'Preparation statistics are Premium',
        body:
            'Computed stats, comparisons, drilldowns and the combined database '
            'need Premium. Your downloaded files are untouched.',
      );
    case DesktopAccessReason.premiumEngineTournament:
      return const DesktopPaywallCopy(
        title: 'Starting engine tournaments is Premium',
        body:
            'Results you already ran stay viewable and exportable, and a '
            'running tournament can always be stopped.',
      );
    case DesktopAccessReason.premiumOpeningTreeBuild:
      return const DesktopPaywallCopy(
        title: 'Building opening trees is Premium',
        body: 'Trees you already built stay on disk to export or remove.',
      );
    case DesktopAccessReason.premiumOpeningTreeExplore:
      return const DesktopPaywallCopy(
        title: 'Exploring opening trees is Premium',
        body: 'Tree files stay on disk to export or remove.',
      );
    case DesktopAccessReason.premiumExplorerDepth:
      return const DesktopPaywallCopy(
        title: 'Explorer statistics past move 10 are Premium',
        body:
            'The first 20 plies of every line are free. Your own board keeps '
            'working at any depth.',
      );
    case DesktopAccessReason.premiumExplorerPlayerScope:
      return const DesktopPaywallCopy(
        title: 'Player-scoped explorer is Premium',
        body:
            'Rating, year, result and time-control filters stay free. '
            'Filtering by player needs Premium.',
      );
    case DesktopAccessReason.premiumExplorerExactPosition:
      return const DesktopPaywallCopy(
        title: 'Exact position search is Premium',
        body: 'Explorer move statistics for the opening stay free.',
      );
    case DesktopAccessReason.premiumProfileFilterCombination:
      return const DesktopPaywallCopy(
        title: 'Combining player game filters is Premium',
        body: 'One filter at a time stays free.',
      );
    case DesktopAccessReason.premiumProfileBulkOperation:
      return const DesktopPaywallCopy(
        title: 'Bulk actions on player games are Premium',
        body: 'Browsing a player\'s games stays free.',
      );
    case DesktopAccessReason.premiumStructuredFilter:
      return const DesktopPaywallCopy(
        title: 'Structured database filters are Premium',
        body: 'Text search and tags stay free.',
      );
    case DesktopAccessReason.premiumStructuredSort:
      return const DesktopPaywallCopy(
        title: 'Sorting cloud databases is Premium',
        body: 'The default order and text search stay free.',
      );
    case DesktopAccessReason.premiumMultiKeySort:
      return const DesktopPaywallCopy(
        title: 'Sorting by more than one column is Premium',
        body: 'Sorting local files by a single column stays free.',
      );
    case DesktopAccessReason.premiumLocalPositionQuery:
      return const DesktopPaywallCopy(
        title: 'Position search in local files is Premium',
        body: 'Opening, editing and text search in your files stay free.',
      );
    case DesktopAccessReason.premiumLikesOutsideWindow:
      return const DesktopPaywallCopy(
        title: 'Likes older than 7 days are Premium',
        body: 'Every like stays in your list to view, tag and remove.',
      );
    case DesktopAccessReason.premiumMiniatureNotToday:
      return const DesktopPaywallCopy(
        title: 'Earlier Miniatures are Premium',
        body: 'Today\'s Miniatures are free.',
      );
    case DesktopAccessReason.quotaFavoritePlayers:
      return DesktopPaywallCopy(
        title: 'Favourite player limit reached',
        body:
            'Free accounts follow $desktopFreeFavoritePlayers players. '
            'Favourite events stay unlimited.',
        capacityLine: capacityLine,
      );
    case DesktopAccessReason.quotaCloudDatabases:
      return DesktopPaywallCopy(
        title: 'Database limit reached',
        body:
            'Free accounts keep $desktopFreeCloudDatabases cloud databases. '
            'Folders stay unlimited.',
        capacityLine: capacityLine,
      );
    case DesktopAccessReason.quotaCloudSavedGames:
      return DesktopPaywallCopy(
        title: 'Saved game limit reached',
        body:
            'Free accounts save $desktopFreeCloudSavedGames games to the '
            'cloud. Likes and local files do not count.',
        capacityLine: capacityLine,
      );
    case DesktopAccessReason.quotaGameReportsPerUtcDay:
      return DesktopPaywallCopy(
        title: 'Today\'s free game report is used',
        body: 'A new free report is available tomorrow (UTC).',
        capacityLine: capacityLine,
      );
    default:
      return DesktopPaywallCopy(
        title:
            '${_contentVerb(context)} from ${_sourceName(context)} is Premium',
        body: 'Browsing stays free.',
        capacityLine: capacityLine,
      );
  }
}
