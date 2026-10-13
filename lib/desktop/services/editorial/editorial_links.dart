import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/services/desktop_deep_link_router.dart';
import 'package:chessever/desktop/services/desktop_web_link_launcher.dart';
import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';

Uri? editorialLink(String? value) {
  final uri = Uri.tryParse(value ?? '');
  return uri != null &&
          uri.scheme == 'https' &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty
      ? uri
      : null;
}

Uri? editorialImage(String? value) {
  final uri = editorialLink(value);
  return uri?.host == 'oelbsuggrzyqwzmvidju.supabase.co' &&
          uri!.path.startsWith('/storage/v1/object/public/editorial-inbox/')
      ? uri
      : null;
}

Future<void> openDesktopEditorialLink(
  BuildContext context,
  Uri uri, {
  VoidCallback? beforeNavigate,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final internal = isChesseverWebUri(uri);
  final path = uri.path.replaceAll(RegExp(r'/+$'), '');
  final destination =
      internal
          ? switch (path) {
            '/board' => DesktopPane.board,
            '/library' => DesktopPane.library,
            '/prep' => DesktopPane.players,
            '/events' => DesktopPane.tournaments,
            '/collections' => DesktopPane.collections,
            '/calendar' => DesktopPane.calendar,
            '/rankings' => DesktopPane.rankings,
            '/favorites' => DesktopPane.favorites,
            '/countrymen' => DesktopPane.countrymen,
            '/settings' => DesktopPane.settings,
            _ => null,
          }
          : null;
  final feature =
      internal
          ? switch (path) {
            '/prep' => DesktopFeature.prepare,
            '/countrymen' => DesktopFeature.countrymen,
            '/miniatures' => DesktopFeature.miniatures,
            '/likes' => DesktopFeature.likes,
            _ => null,
          }
          : null;
  if (feature != null) {
    final request = DesktopAccessContext(
      feature: feature,
      action: DesktopAction.openContent,
      origin: DesktopDiscoveryOrigin.deepLink,
    );
    final decision = readDesktopAccess(container.read, request);
    if (!await presentDesktopAccessDecision(
      container,
      decision,
      context: request,
      surface: 'editorial_link',
    )) {
      return;
    }
  }
  beforeNavigate?.call();
  if (destination != null) {
    container
        .read(desktopTabsProvider.notifier)
        .open(tabKindForPane(destination));
    return;
  }
  if (internal && await DesktopDeepLinkRouter.instance.handle(uri, container)) {
    return;
  }
  await launchDesktopWebUrl(uri);
}
