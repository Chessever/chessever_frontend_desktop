import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/desktop_tabs.dart';

String openCurrentUserProfileTab(WidgetRef ref, {bool focus = true}) {
  return ref
      .read(desktopTabsProvider.notifier)
      .open(
        TabKind.userProfile,
        title: 'My profile',
        reuseExisting: true,
        focus: focus,
      );
}
