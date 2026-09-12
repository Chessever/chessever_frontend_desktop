import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/screens/group_event/smart_event/smart_aggregate_event_provider.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';

/// Smart game collection selected for each desktop tab.
final desktopSmartGamesTypeByTabIdProvider =
    StateProvider<Map<String, PremiumGamesType>>((ref) => const {});

/// What a criteria-driven smart-event tab is showing.
///
/// [request] is the live criteria the tab queries with; editing criteria
/// replaces it immediately. [savedCriteriaKey] is the criteria key of the
/// favourite row this tab is attached to, or null when the tab is unsaved. It
/// only advances after a save is confirmed written, so `request.criteriaKey !=
/// savedCriteriaKey` is exactly "this saved smart event has unsaved edits".
@immutable
class DesktopSmartEventTabState {
  const DesktopSmartEventTabState({
    required this.request,
    this.savedCriteriaKey,
  });

  final SmartEventRequest request;
  final String? savedCriteriaKey;

  bool get hasUnsavedCriteria =>
      savedCriteriaKey != null && savedCriteriaKey != request.criteriaKey;

  DesktopSmartEventTabState withRequest(SmartEventRequest next) =>
      DesktopSmartEventTabState(
        request: next,
        savedCriteriaKey: savedCriteriaKey,
      );

  DesktopSmartEventTabState attachedTo(String? criteriaKey) =>
      DesktopSmartEventTabState(
        request: request,
        savedCriteriaKey: criteriaKey,
      );
}

/// Criteria-driven smart events by tab id. A `TabKind.smartGames` tab with an
/// entry here renders the smart-event pane; one without keeps the fixed
/// collection from [desktopSmartGamesTypeByTabIdProvider].
final desktopSmartEventTabStateByTabIdProvider =
    StateProvider<Map<String, DesktopSmartEventTabState>>((ref) => const {});

final RegExp _smartEventOpeningCodePattern = RegExp(r'^[A-E][0-9]{2}$');

/// Upper-cases an opening reference and accepts it only when it is an exact
/// three-character ECO code (`A00`..`E99`). Returns null otherwise.
String? normalizeSmartEventOpeningCode(String raw) {
  final code = raw.trim().toUpperCase();
  return _smartEventOpeningCodePattern.hasMatch(code) ? code : null;
}

/// Opens smart events in desktop tabs. Callable from any `Ref`, `WidgetRef` or
/// `ProviderContainer` through `read(desktopSmartEventOpenerProvider)`.
final desktopSmartEventOpenerProvider = Provider<DesktopSmartEventOpener>(
  DesktopSmartEventOpener.new,
);

class DesktopSmartEventOpener {
  DesktopSmartEventOpener(this._ref);

  final Ref _ref;

  /// Opens [request] in a new smart-games tab and returns its tab id.
  ///
  /// [savedCriteriaKey] attaches the tab to an existing favourite row (pass
  /// the saved request's criteria key when opening a saved card).
  String open(
    SmartEventRequest request, {
    String? savedCriteriaKey,
    bool focus = true,
  }) {
    // A request whose criteria are already saved attaches to that row, so a
    // later criteria edit re-keys it instead of saving a second copy.
    final attachedKey =
        savedCriteriaKey ??
        (_ref.read(smartEventSavedFavoriteProvider(request.criteriaKey)) == null
            ? null
            : request.criteriaKey);
    final tabs = _ref.read(desktopTabsProvider.notifier);
    final tabId = tabs.open(
      TabKind.smartGames,
      title: request.displayName,
      reuseExisting: false,
      focus: focus,
    );
    final liveTabIds = {
      for (final tab in _ref.read(desktopTabsProvider).tabs) tab.id,
    };
    _ref
        .read(desktopSmartEventTabStateByTabIdProvider.notifier)
        .update(
          (states) => {
            for (final entry in states.entries)
              if (liveTabIds.contains(entry.key)) entry.key: entry.value,
            tabId: DesktopSmartEventTabState(
              request: request,
              savedCriteriaKey: attachedKey,
            ),
          },
        );
    return tabId;
  }

  /// The opening navigation seam: opens the global smart event for one ECO
  /// code, e.g. from an `opening` chat reference.
  ///
  /// [code] is trimmed and upper-cased; anything that is not an exact
  /// `^[A-E][0-9]{2}$` code is rejected and returns null without opening a
  /// tab. Otherwise opens
  /// `SmartEventRequest.forOpening(GameEcoFilter.forCode(code))` and returns
  /// the new tab id. Browsing a smart event is free; game content inside it
  /// stays gated by smart-collection provenance.
  String? openOpeningCode(String code, {bool focus = true}) {
    final normalized = normalizeSmartEventOpeningCode(code);
    if (normalized == null) return null;
    return open(
      SmartEventRequest.forOpening(GameEcoFilter.forCode(normalized)),
      focus: focus,
    );
  }
}
