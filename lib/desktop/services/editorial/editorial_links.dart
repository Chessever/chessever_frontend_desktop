import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/collections_reader.dart';
import 'package:chessever/desktop/services/desktop_deep_link_router.dart';
import 'package:chessever/desktop/services/desktop_web_link_launcher.dart';
import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/shell/desktop_pane_navigation.dart';
import 'package:chessever/desktop/state/library_destination.dart';
import 'package:chessever/desktop/state/desktop_smart_games.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/desktop/widgets/collections/collection_actions.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/library/my_likes/my_likes_view.dart'
    show kMyLikesDestinationId;

Uri? editorialLink(String? value) {
  final text = value?.trim() ?? '';
  final uri = Uri.tryParse(
    text.startsWith('/') && !text.startsWith('//')
        ? 'https://chessever.com$text'
        : text,
  );
  return uri != null &&
          (uri.scheme == 'https' || uri.scheme == 'http') &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty
      ? uri
      : null;
}

/// Matches mobile's article/Inbox image contract using production Storage.
/// Untrusted remote images never load automatically when a message is opened.
Uri? editorialImage(String? value) {
  final uri = editorialLink(value);
  if (uri == null || uri.scheme != 'https' || uri.port != 443) return null;
  if (uri.host == 'oelbsuggrzyqwzmvidju.supabase.co') {
    return uri.path.startsWith('/storage/v1/object/public/') ||
            uri.path.startsWith('/storage/v1/render/image/public/')
        ? uri
        : null;
  }
  return const {
        'chessever.com',
        'www.chessever.com',
        'i.ytimg.com',
      }.contains(uri.host)
      ? uri
      : null;
}

bool _internal(Uri uri) =>
    uri.scheme == 'https' &&
    uri.port == 443 &&
    uri.userInfo.isEmpty &&
    isChesseverWebUri(uri);

String _pagePath(Uri uri) => uri.path
    .replaceFirst(RegExp(r'^/app(?=/)'), '')
    .replaceAll(RegExp(r'/+$'), '');

DesktopPane? desktopEditorialPaneForUri(Uri uri) =>
    !_internal(uri)
        ? null
        : switch (_pagePath(uri)) {
          '/inbox' => DesktopPane.inbox,
          '/board' => DesktopPane.board,
          '/play' => DesktopPane.play,
          '/library' || '/my-likes' => DesktopPane.library,
          '/prep' || '/my-prep' => DesktopPane.players,
          '/events' => DesktopPane.tournaments,
          '/collections' => DesktopPane.collections,
          '/calendar' => DesktopPane.calendar,
          '/rankings' => DesktopPane.rankings,
          '/favorites' => DesktopPane.favorites,
          '/countrymen' => DesktopPane.countrymen,
          '/settings' => DesktopPane.settings,
          _ => null,
        };

/// Reports and Play are Premium; public hubs retain their content guards.
bool desktopEditorialPageRequiresPremium(Uri uri) =>
    _internal(uri) && const {'/reports', '/play'}.contains(_pagePath(uri));

typedef DesktopEditorialLinkOpener = Future<void> Function(BuildContext, Uri);
typedef DesktopEditorialPremiumRequest = Future<bool> Function(BuildContext);

final desktopEditorialPremiumRequestProvider =
    Provider<DesktopEditorialPremiumRequest>(
      (_) =>
          (context) =>
              showDesktopPremiumPaywall(context, surface: 'editorial_link'),
    );

final desktopEditorialNavigationProvider = Provider<DesktopEditorialLinkOpener>(
  (ref) => (context, uri) async {
    final container = ProviderScope.containerOf(context, listen: false);
    if (_internal(uri) && _pagePath(uri) == '/miniatures') {
      final types = container.read(desktopSmartGamesTypeByTabIdProvider);
      final tabs = container.read(desktopTabsProvider.notifier);
      for (final tab in container.read(desktopTabsProvider).tabs) {
        if (tab.kind == TabKind.smartGames &&
            types[tab.id] == PremiumGamesType.miniatures) {
          tabs.activate(tab.id);
          return;
        }
      }
      final id = tabs.open(
        TabKind.smartGames,
        title: 'Miniatures',
        reuseExisting: false,
      );
      container
          .read(desktopSmartGamesTypeByTabIdProvider.notifier)
          .update((types) => {...types, id: PremiumGamesType.miniatures});
      return;
    }
    final pane = desktopEditorialPaneForUri(uri);
    if (pane != null) {
      if (_pagePath(uri) == '/my-likes') {
        final request = container.read(
          libraryDestinationRequestProvider.notifier,
        );
        request.state = ((request.state?.$1 ?? 0) + 1, kMyLikesDestinationId);
      }
      openDesktopPaneFromContainer(container, pane);
      return;
    }
    if (_internal(uri) &&
        await DesktopDeepLinkRouter.instance.handle(uri, container)) {
      return;
    }
    // Desktop has no News/Discovery reader. Keep the complete web destination.
    final browserUri = _internal(uri) ? uri.replace(path: _pagePath(uri)) : uri;
    if (!await launchDesktopWebUrl(browserUri) && context.mounted) {
      showDesktopToast(
        context,
        "Couldn't open the link. Please try again.",
        error: true,
      );
    }
  },
);

final desktopEditorialCollectionOpenerProvider =
    Provider<DesktopEditorialLinkOpener>(
      (ref) => (context, uri) async {
        final container = ProviderScope.containerOf(context, listen: false);
        final slug = uri.pathSegments.last;
        final reader = container.read(collectionsReaderProvider);
        final release = reader.holdFreshAccess(slug);
        try {
          var collection = await reader.fetchCollection(slug);
          if (!context.mounted) return;
          if (collection.isPremium && collection.contentLocked != false) {
            if (!await container.read(desktopEditorialPremiumRequestProvider)(
                  context,
                ) ||
                !context.mounted) {
              return;
            }
            collection = await reader.fetchCollection(slug);
            if (!context.mounted) return;
            if (collection.contentLocked != false) {
              showDesktopToast(
                context,
                'This collection is still locked. Please try again.',
                error: true,
              );
              return;
            }
          }
          openCollectionWorkspaceTabFromContainer(
            container,
            slug: collection.slug,
            title: collection.title,
          );
        } finally {
          release();
        }
      },
    );

/// Markdown and buttons share one opener and one pending flow per window.
/// Canceling Premium consumes the click without opening a destination.
final desktopEditorialLinkOpenerProvider = Provider<DesktopEditorialLinkOpener>(
  (ref) {
    var opening = false;
    return (context, uri) async {
      if (opening ||
          !context.mounted ||
          editorialLink(uri.toString()) == null) {
        return;
      }
      opening = true;
      final container = ProviderScope.containerOf(context, listen: false);
      try {
        if (desktopEditorialPageRequiresPremium(uri) &&
            !await container.read(desktopEditorialPremiumRequestProvider)(
              context,
            )) {
          return;
        }
        if (!context.mounted) return;
        final path =
            _pagePath(uri).split('/').where((s) => s.isNotEmpty).toList();
        if (_internal(uri) && path.length == 2 && path.first == 'collections') {
          await container.read(desktopEditorialCollectionOpenerProvider)(
            context,
            uri,
          );
        } else {
          await container.read(desktopEditorialNavigationProvider)(
            context,
            uri,
          );
        }
      } catch (_) {
        if (context.mounted) {
          showDesktopToast(
            context,
            "Couldn't open the link. Please try again.",
            error: true,
          );
        }
      } finally {
        opening = false;
      }
    };
  },
);
