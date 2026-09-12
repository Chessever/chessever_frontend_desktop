import 'package:flutter/foundation.dart' show immutable;

import 'package:chessever/desktop/auth/desktop_access_policy.dart';

/// The product surface a request belongs to.
///
/// Values up to [sharedBook] are the shared freemium contract every desktop
/// entry point speaks. Two additions: [openingTree] (building and exploring
/// local, player and combined trees, including the local-files opening-tree
/// tools) and [purchase] (buying or restoring Premium is itself a request,
/// and one of only two that need a permanent account).
enum DesktopFeature {
  broadcast,
  favorites,
  countrymen,
  smartCollection,
  playerProfile,
  gamebase,
  twic,
  miniatures,
  likes,
  ownedDocument,
  openingExplorer,
  gameReport,
  prepare,
  engineTournament,
  botvinnik,
  localFiles,
  sharedBook,
  openingTree,
  purchase,
}

/// Where the user discovered the content a request acts on.
///
/// Provenance, not game identity, decides access: the same game is free when
/// it was reached through an ordinary [broadcast] and gated when it was
/// reached through [countrymen], a [smartCollection] or a [playerProfile].
/// Carry it through tabs, rails, drag payloads, detached windows and restored
/// state; that is why [DesktopAccessContext] round-trips through JSON.
enum DesktopDiscoveryOrigin {
  broadcast,
  favorites,
  countrymen,
  smartCollection,
  playerProfile,
  gamebase,
  twic,
  miniatures,
  likes,
  ownedDocument,
  localFile,
  sharedBook,
  deepLink,
}

/// What the request wants to do.
enum DesktopAction {
  view,
  openContent,
  previewNavigate,
  fetchPgn,
  insertMove,
  copy,
  save,
  share,
  export,
  create,
  acquireSource,
  recompute,
  sort,
  filter,
  bulkSelect,

  /// In-place, quota-neutral change to retained work: rename, annotate, edit
  /// moves.
  edit,

  /// Remove a record. Never gated.
  remove,

  /// Stop an active run or operation, or recover files. Never gated.
  cancel,

  /// Write a metadata tag. Never gated.
  tag,
}

/// A free-tier allowance a request can spend.
enum DesktopQuota {
  /// Explicitly spends nothing: a folder is not a database, a favourite event
  /// is not a favourite player, a Likes row is not a saved game, an in-place
  /// update is not a new slot.
  none,
  favoritePlayers,
  cloudDatabases,
  cloudSavedGames,
  gameReportsPerUtcDay,
}

/// Actions no surface ever gates. A downgrade must never block removing,
/// tagging, stopping or recovering the user's own data.
const Set<DesktopAction> desktopNeverGatedActions = {
  DesktopAction.remove,
  DesktopAction.cancel,
  DesktopAction.tag,
};

/// Actions that reach back to the ORIGIN of a game rather than to a retained
/// copy of it. Owning a copy never covers these.
const Set<DesktopAction> desktopSourceReachingActions = {
  DesktopAction.fetchPgn,
  DesktopAction.insertMove,
  DesktopAction.acquireSource,
};

/// Everything an access decision needs to know about one request.
///
/// Immutable, value-equal and JSON round-trippable: it crosses the detached
/// board-window boundary and is persisted inside restored tab state, so a
/// board reopened tomorrow is judged by where its game came from, not by what
/// the tab happens to be showing.
///
/// Ownership invariant: [ownedDocument] + [retainedSaveId] make THAT retained
/// row free to view, edit, copy, share and export. They say nothing about the
/// [origin]. Asking the paid source for the next game of an owned document is
/// a fresh request whose origin is still the paid source; see
/// [ownershipCovers].
@immutable
class DesktopAccessContext {
  const DesktopAccessContext({
    required this.feature,
    required this.action,
    required this.origin,
    this.ownedDocument = false,
    this.retainedSaveId,
    this.contentDate,
    this.playedPlies,
    this.filterCriteriaCount = 0,
    this.sortKeyCount = 0,
    this.playerScoped = false,
    this.accountId,
    this.entitlementGeneration = desktopUnassertedGeneration,
    this.quota,
    this.additions = 1,
  }) : assert(filterCriteriaCount >= 0),
       assert(sortKeyCount >= 0),
       assert(additions >= 0);

  final DesktopFeature feature;
  final DesktopAction action;
  final DesktopDiscoveryOrigin origin;

  /// The user owns the document this request acts on (a personal PGN, a
  /// cloud row they saved, a copy they made).
  final bool ownedDocument;

  /// Identity of the retained personal row the request acts on. Ownership
  /// only applies when this is set: it scopes the free pass to one row.
  final String? retainedSaveId;

  /// The date that decides date-bound access. For [DesktopFeature.likes] this
  /// is when the game was liked.
  final DateTime? contentDate;

  /// Played plies from the start position, for explorer depth decisions.
  final int? playedPlies;

  /// Active STRUCTURED filter criteria on a filtered surface.
  ///
  /// What counts differs by surface, deliberately:
  /// * Cloud databases, shared books and local files: structured filters
  ///   only. Plain text search and tags are free, so callers pass 0 for them.
  /// * Player profiles: every active criterion, text search included; one is
  ///   free, two or more combined are Premium.
  /// * Opening explorer: ignored. General rating/year/result/time-control
  ///   filters are free; player scope is carried by [playerScoped].
  final int filterCriteriaCount;

  /// Sort keys in effect. Callers only evaluate a NON-default sort. Local
  /// files allow one key free; cloud databases and shared books gate any
  /// non-default sort.
  final int sortKeyCount;

  /// The request is scoped to a player: player filters, player-scoped
  /// exploration, player-profile opening exploration.
  final bool playerScoped;

  /// Account this context was built for. Only compared when
  /// [entitlementGeneration] is asserted.
  final String? accountId;

  /// Entitlement generation this context was built against, or
  /// [desktopUnassertedGeneration]. When asserted, a decision against a
  /// different generation or account is rejected as stale.
  final int entitlementGeneration;

  /// Allowance this request spends, or null to derive it from [feature] and
  /// [action] (see [effectiveQuota]).
  final DesktopQuota? quota;

  /// New records this request would create against [effectiveQuota]. Zero for
  /// an in-place update; N for a bulk save where every destination copy counts.
  final int additions;

  /// Whether ownership of a retained row covers this request.
  bool get ownershipCovers =>
      ownedDocument &&
      retainedSaveId != null &&
      !desktopSourceReachingActions.contains(action);

  /// The allowance this request spends.
  ///
  /// The implied default errs toward CHARGING: saving is assumed to create a
  /// saved game, creating an owned document is assumed to create a database,
  /// creating a favourite is assumed to favourite a player. Exemptions (a
  /// folder, a favourite event) must be stated explicitly with
  /// [DesktopQuota.none] or `additions: 0`, so a forgotten argument can never
  /// hand out free capacity.
  ///
  /// Fixed rules that no argument overrides:
  /// * [desktopNeverGatedActions] and [DesktopAction.edit] spend nothing.
  /// * Local files have no capacity limits.
  /// * The Likes collection itself never spends quota (liking, tagging,
  ///   removing). MOVING a like into a regular database with
  ///   [DesktopAction.save] creates a regular saved game and is charged.
  DesktopQuota get effectiveQuota {
    if (desktopNeverGatedActions.contains(action) ||
        action == DesktopAction.edit ||
        feature == DesktopFeature.localFiles) {
      return DesktopQuota.none;
    }
    if (feature == DesktopFeature.likes) {
      return action == DesktopAction.save
          ? quota ?? DesktopQuota.cloudSavedGames
          : DesktopQuota.none;
    }
    final explicit = quota;
    if (explicit != null) return explicit;
    switch (feature) {
      case DesktopFeature.favorites:
        return action == DesktopAction.create || action == DesktopAction.save
            ? DesktopQuota.favoritePlayers
            : DesktopQuota.none;
      case DesktopFeature.gameReport:
        return action == DesktopAction.create ||
                action == DesktopAction.recompute
            ? DesktopQuota.gameReportsPerUtcDay
            : DesktopQuota.none;
      case DesktopFeature.ownedDocument:
        if (action == DesktopAction.create) return DesktopQuota.cloudDatabases;
        if (action == DesktopAction.save) return DesktopQuota.cloudSavedGames;
        return DesktopQuota.none;
      default:
        return action == DesktopAction.save
            ? DesktopQuota.cloudSavedGames
            : DesktopQuota.none;
    }
  }

  DesktopAccessContext copyWith({
    DesktopFeature? feature,
    DesktopAction? action,
    DesktopDiscoveryOrigin? origin,
    bool? ownedDocument,
    String? retainedSaveId,
    bool clearRetainedSaveId = false,
    DateTime? contentDate,
    int? playedPlies,
    int? filterCriteriaCount,
    int? sortKeyCount,
    bool? playerScoped,
    String? accountId,
    bool clearAccountId = false,
    int? entitlementGeneration,
    DesktopQuota? quota,
    int? additions,
  }) {
    return DesktopAccessContext(
      feature: feature ?? this.feature,
      action: action ?? this.action,
      origin: origin ?? this.origin,
      ownedDocument: ownedDocument ?? this.ownedDocument,
      retainedSaveId: clearRetainedSaveId
          ? null
          : retainedSaveId ?? this.retainedSaveId,
      contentDate: contentDate ?? this.contentDate,
      playedPlies: playedPlies ?? this.playedPlies,
      filterCriteriaCount: filterCriteriaCount ?? this.filterCriteriaCount,
      sortKeyCount: sortKeyCount ?? this.sortKeyCount,
      playerScoped: playerScoped ?? this.playerScoped,
      accountId: clearAccountId ? null : accountId ?? this.accountId,
      entitlementGeneration:
          entitlementGeneration ?? this.entitlementGeneration,
      quota: quota ?? this.quota,
      additions: additions ?? this.additions,
    );
  }

  Map<String, Object?> toJson() => {
    'feature': feature.name,
    'action': action.name,
    'origin': origin.name,
    'ownedDocument': ownedDocument,
    'retainedSaveId': retainedSaveId,
    'contentDate': contentDate?.toIso8601String(),
    'playedPlies': playedPlies,
    'filterCriteriaCount': filterCriteriaCount,
    'sortKeyCount': sortKeyCount,
    'playerScoped': playerScoped,
    'accountId': accountId,
    'entitlementGeneration': entitlementGeneration,
    'quota': quota?.name,
    'additions': additions,
  };

  /// Decodes a context written by [toJson], tolerating payloads from older or
  /// newer builds.
  ///
  /// An unrecognised or missing feature/origin decodes as a PAID source
  /// ([DesktopFeature.gamebase] / [DesktopDiscoveryOrigin.gamebase]) and an
  /// unrecognised action as [DesktopAction.openContent]. A decode gap must
  /// never be the thing that hands out Premium content; the worst case is a
  /// member being asked to re-verify.
  factory DesktopAccessContext.fromJson(Map<String, Object?> json) {
    return DesktopAccessContext(
      feature: _decode(
        DesktopFeature.values,
        json['feature'],
        DesktopFeature.gamebase,
      ),
      action: _decode(
        DesktopAction.values,
        json['action'],
        DesktopAction.openContent,
      ),
      origin: _decode(
        DesktopDiscoveryOrigin.values,
        json['origin'],
        DesktopDiscoveryOrigin.gamebase,
      ),
      ownedDocument: json['ownedDocument'] == true,
      retainedSaveId: json['retainedSaveId'] as String?,
      contentDate: _decodeDate(json['contentDate']),
      playedPlies: (json['playedPlies'] as num?)?.toInt(),
      filterCriteriaCount: _nonNegative(json['filterCriteriaCount'], 0),
      sortKeyCount: _nonNegative(json['sortKeyCount'], 0),
      playerScoped: json['playerScoped'] == true,
      accountId: json['accountId'] as String?,
      entitlementGeneration:
          (json['entitlementGeneration'] as num?)?.toInt() ??
          desktopUnassertedGeneration,
      quota: _decodeQuota(json['quota']),
      additions: _nonNegative(json['additions'], 1),
    );
  }

  static T _decode<T extends Enum>(List<T> values, Object? raw, T fallback) {
    if (raw is String) {
      for (final value in values) {
        if (value.name == raw) return value;
      }
    }
    return fallback;
  }

  /// A missing quota stays null (derive it). An unrecognised one decodes as
  /// [DesktopQuota.cloudSavedGames] so a decode gap charges rather than frees.
  static DesktopQuota? _decodeQuota(Object? raw) {
    if (raw == null) return null;
    return _decode(DesktopQuota.values, raw, DesktopQuota.cloudSavedGames);
  }

  /// Local dates encode without an offset and decode as local, so the local
  /// calendar day (what the Likes window compares) survives exactly; UTC dates
  /// keep their `Z` and decode as UTC.
  static DateTime? _decodeDate(Object? raw) {
    if (raw is! String) return null;
    return DateTime.tryParse(raw);
  }

  static int _nonNegative(Object? raw, int fallback) {
    final value = (raw as num?)?.toInt();
    return value == null || value < 0 ? fallback : value;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopAccessContext &&
          other.feature == feature &&
          other.action == action &&
          other.origin == origin &&
          other.ownedDocument == ownedDocument &&
          other.retainedSaveId == retainedSaveId &&
          other.contentDate == contentDate &&
          other.playedPlies == playedPlies &&
          other.filterCriteriaCount == filterCriteriaCount &&
          other.sortKeyCount == sortKeyCount &&
          other.playerScoped == playerScoped &&
          other.accountId == accountId &&
          other.entitlementGeneration == entitlementGeneration &&
          other.quota == quota &&
          other.additions == additions;

  @override
  int get hashCode => Object.hash(
    feature,
    action,
    origin,
    ownedDocument,
    retainedSaveId,
    contentDate,
    playedPlies,
    filterCriteriaCount,
    sortKeyCount,
    playerScoped,
    accountId,
    entitlementGeneration,
    quota,
    additions,
  );

  @override
  String toString() =>
      'DesktopAccessContext(${feature.name}/${action.name} '
      'via ${origin.name}, owned: $ownedDocument, '
      'filters: $filterCriteriaCount, sortKeys: $sortKeyCount, '
      'playerScoped: $playerScoped, plies: $playedPlies, '
      'quota: ${effectiveQuota.name} x$additions)';
}
