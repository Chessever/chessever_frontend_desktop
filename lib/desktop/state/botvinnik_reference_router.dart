import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/chat/chat_api.dart';
import 'package:chessever/chat/chat_references.dart';
import 'package:chessever/desktop/services/desktop_deep_link_router.dart';
import 'package:chessever/desktop/state/active_player.dart';

/// Opens an opening (ECO code such as `B14`) in the desktop Smart Events
/// destination.
typedef BotvinnikOpeningReferenceOpener =
    Future<void> Function(WidgetRef ref, String ecoCode);

/// Seam for opening references.
///
/// Desktop Smart Events is being rebuilt separately. Until that destination
/// overrides this provider it stays null, and opening references render as
/// plain text: an answer never shows a link that would do nothing.
final botvinnikOpeningReferenceOpenerProvider =
    Provider<BotvinnikOpeningReferenceOpener?>((ref) => null);

/// Decides which answer references are links and where each one goes.
abstract class BotvinnikReferenceRouter {
  /// Only references that return true are linkified in an answer.
  bool canOpen(ChatReference reference);

  Future<void> open(WidgetRef ref, ChatReference reference);
}

/// Routes references through the same coordinator that handles shared
/// chessever.com links, so a Botvinnik link lands exactly where a pasted
/// link would.
class DesktopBotvinnikReferenceRouter implements BotvinnikReferenceRouter {
  const DesktopBotvinnikReferenceRouter({this.openingOpener});

  final BotvinnikOpeningReferenceOpener? openingOpener;

  @override
  bool canOpen(ChatReference reference) {
    if (reference.type == 'opening') {
      return openingOpener != null && isChatOpeningReferenceId(reference.id);
    }
    if (reference.type == 'player') {
      return reference.id.isNotEmpty && reference.label.trim().isNotEmpty;
    }
    return botvinnikReferenceDeepLink(reference) != null;
  }

  @override
  Future<void> open(WidgetRef ref, ChatReference reference) async {
    if (!canOpen(reference)) return;
    final container = ProviderScope.containerOf(ref.context, listen: false);
    switch (reference.type) {
      case 'opening':
        await openingOpener!(
          ref,
          normalizeChatOpeningReferenceId(reference.id),
        );
        return;
      case 'player':
        openPlayerProfile(
          ref,
          PlayerProfileArgs(
            playerName: reference.label,
            fideId: int.tryParse(reference.id),
            title: reference.title,
            federation: reference.federation,
            rating: reference.rating,
          ),
        );
        return;
    }
    final uri = botvinnikReferenceDeepLink(reference);
    if (uri == null) return;
    await DesktopDeepLinkRouter.instance.handle(uri, container);
  }
}

/// The chessever.com link a reference is equivalent to, or null when the
/// desktop coordinator has no destination for it.
///
/// Rounds have no desktop route of their own, so they open the tournament
/// they belong to when the answer names it.
@visibleForTesting
Uri? botvinnikReferenceDeepLink(ChatReference reference) {
  final id = reference.id.trim();
  if (id.isEmpty) return null;
  List<String>? segments;
  switch (reference.type) {
    case 'game':
      segments = ['games', id];
    case 'event':
    case 'tournament':
      segments = ['broadcast', id];
    case 'round':
      final tourId = reference.tourId?.trim() ?? '';
      if (tourId.isNotEmpty) segments = ['broadcast', tourId];
  }
  if (segments == null) return null;
  return Uri(scheme: 'https', host: 'chessever.com', pathSegments: segments);
}

final botvinnikReferenceRouterProvider = Provider<BotvinnikReferenceRouter>(
  (ref) => DesktopBotvinnikReferenceRouter(
    openingOpener: ref.watch(botvinnikOpeningReferenceOpenerProvider),
  ),
);
