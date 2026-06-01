import 'package:flutter/widgets.dart';

import 'package:chessever/desktop/widgets/spring_tokens.dart';

/// Default scroll physics for free-scrolling desktop lists (sidebar,
/// game lists, ladder notation, library folders, settings sections).
///
/// Replaces the Flutter default with [DesktopSprings.scrollEdge]: edge
/// rubber-band feels intentional rather than rubbery. There's no snap
/// behaviour — these are continuous lists, not pagers.
class DesktopScrollPhysics extends BouncingScrollPhysics {
  const DesktopScrollPhysics({super.parent});

  @override
  DesktopScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return DesktopScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  SpringDescription get spring => DesktopSprings.scrollEdge;
}

/// Snap-to-page physics for `PageView` / `TabBarView` / carousel-style
/// surfaces. Pages settle with a tiny bounce — feels intentional, not
/// stiff. Applied to surfaces where the user expects each gesture to
/// land on a discrete index (e.g. the right-rail two-page panel: ladder
/// vs opening explorer).
class DesktopPagePhysics extends PageScrollPhysics {
  const DesktopPagePhysics({super.parent});

  @override
  DesktopPagePhysics applyTo(ScrollPhysics? ancestor) {
    return DesktopPagePhysics(parent: buildParent(ancestor));
  }

  @override
  SpringDescription get spring => DesktopSprings.pageSnap;
}
