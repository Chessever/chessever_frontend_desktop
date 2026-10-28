import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/collections_reader.dart';

/// How often the Collections pane re-reads its counts while it is shown.
const Duration collectionCountsRefreshInterval = Duration(seconds: 20);

/// Keeps the view and star counts of the pane that calls it current while it
/// is on screen: once when it appears, then on a short beat, and again when
/// the app returns. Hidden (another pane, a dialog over it, the app in the
/// background) it asks for nothing.
void useCollectionCountsRefresh(BuildContext context, WidgetRef ref) {
  useEffect(() {
    void refresh() {
      if (!context.mounted) return;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
      if (!TickerMode.valuesOf(context).enabled) return;
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      unawaited(ref.read(collectionEngagementProvider).refresh());
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
    final timer = Timer.periodic(
      collectionCountsRefreshInterval,
      (_) => refresh(),
    );
    final listener = AppLifecycleListener(onResume: refresh);
    return () {
      timer.cancel();
      listener.dispose();
    };
  }, const []);
}
