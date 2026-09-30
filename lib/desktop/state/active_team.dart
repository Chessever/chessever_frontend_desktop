import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';

/// Args for a Team Score Card tab.
@immutable
class TeamScoreCardTabArgs {
  const TeamScoreCardTabArgs({required this.teamName, this.selectedBroadcast});

  final String teamName;

  /// Event the team plays in. The pane re-scopes the shared tournament
  /// providers to it while the tab is foregrounded, the same way a player
  /// score card tab restores its event.
  final GroupBroadcast? selectedBroadcast;

  bool sameTeam(TeamScoreCardTabArgs other) =>
      teamName.trim().toLowerCase() == other.teamName.trim().toLowerCase() &&
      selectedBroadcast?.id == other.selectedBroadcast?.id;
}

/// Per-tab team score card args, keyed by `DesktopTab.id`.
final teamScoreCardByTabIdProvider =
    StateProvider<Map<String, TeamScoreCardTabArgs>>(
      (_) => const <String, TeamScoreCardTabArgs>{},
    );

/// Opens (or reactivates) a Team Score Card tab for [args].
String openTeamScoreCard(
  WidgetRef ref,
  TeamScoreCardTabArgs args, {
  bool focus = true,
}) => _openTeamScoreCard(ref.read, args, focus: focus);

/// Container variant of [openTeamScoreCard] for code without a widget, such
/// as the deep link router.
String openTeamScoreCardFromContainer(
  ProviderContainer container,
  TeamScoreCardTabArgs args, {
  bool focus = true,
}) => _openTeamScoreCard(container.read, args, focus: focus);

String _openTeamScoreCard(
  T Function<T>(ProviderListenable<T> provider) read,
  TeamScoreCardTabArgs args, {
  required bool focus,
}) {
  final tabsNotifier = read(desktopTabsProvider.notifier);
  final tabsState = read(desktopTabsProvider);
  final byTab = read(teamScoreCardByTabIdProvider);

  for (final entry in byTab.entries) {
    if (!entry.value.sameTeam(args)) continue;
    final stillHosted = tabsState.tabs.any(
      (tab) => tab.id == entry.key && tab.kind == TabKind.teamScoreCard,
    );
    if (!stillHosted) continue;
    if (focus) tabsNotifier.activate(entry.key);
    return entry.key;
  }

  final name = args.teamName.trim();
  final tabId = tabsNotifier.open(
    TabKind.teamScoreCard,
    title: name.isEmpty ? TabKind.teamScoreCard.defaultTitle : name,
    subtitle: args.selectedBroadcast?.name,
    reuseExisting: false,
    focus: focus,
  );
  read(teamScoreCardByTabIdProvider.notifier).update(
    (existing) => <String, TeamScoreCardTabArgs>{...existing, tabId: args},
  );
  return tabId;
}
