import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chessever/desktop/shell/desktop_pane.dart';

@immutable
class DesktopMainRoute {
  const DesktopMainRoute({
    required this.pane,
    required this.label,
    required this.paletteTitle,
    required this.icon,
    this.paletteSubtitle,
  });

  final DesktopPane pane;
  final String label;
  final String paletteTitle;
  final String? paletteSubtitle;
  final IconData icon;
}

const List<DesktopMainRoute> desktopMainRoutes = [
  DesktopMainRoute(
    pane: DesktopPane.tournaments,
    label: 'Events',
    paletteTitle: 'Open Events',
    paletteSubtitle: 'Live broadcasts and recent events',
    icon: Icons.emoji_events_outlined,
  ),
  DesktopMainRoute(
    pane: DesktopPane.library,
    label: 'Library',
    paletteTitle: 'Open Library',
    paletteSubtitle: 'Search games, players, openings',
    icon: Icons.menu_book_outlined,
  ),
  DesktopMainRoute(
    pane: DesktopPane.favorites,
    label: 'Favorites',
    paletteTitle: 'Open Favorites',
    icon: Icons.favorite_outline,
  ),
  DesktopMainRoute(
    pane: DesktopPane.players,
    label: 'Prepare',
    paletteTitle: 'Open Prepare',
    paletteSubtitle: 'Prep a player from ChessEver, Lichess, and Chess.com',
    icon: Icons.person_search_outlined,
  ),
  DesktopMainRoute(
    pane: DesktopPane.rankings,
    label: 'Rankings',
    paletteTitle: 'Open Rankings',
    paletteSubtitle: 'Search the ChessEver player index',
    icon: Icons.groups_outlined,
  ),
  DesktopMainRoute(
    pane: DesktopPane.calendar,
    label: 'Calendar',
    paletteTitle: 'Open Calendar',
    icon: Icons.calendar_today_outlined,
  ),
  DesktopMainRoute(
    pane: DesktopPane.countrymen,
    label: 'Countrymen',
    paletteTitle: 'Open Countrymen',
    icon: Icons.public_outlined,
  ),
  DesktopMainRoute(
    pane: DesktopPane.board,
    label: 'Board',
    paletteTitle: 'Open Board',
    paletteSubtitle: 'Analysis board and notation',
    icon: Icons.grid_4x4,
  ),
  DesktopMainRoute(
    pane: DesktopPane.play,
    label: 'Play',
    paletteTitle: 'Open Play',
    paletteSubtitle: 'Play the engine and manage local tournaments',
    icon: Icons.sports_esports_outlined,
  ),
];

const List<LogicalKeyboardKey> desktopMainRouteShortcutKeys = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

String desktopPrimaryShortcutLabel(String key, {bool? isMacOS}) {
  final usesMacOS = isMacOS ?? Platform.isMacOS;
  return usesMacOS ? '⌘$key' : 'Ctrl+$key';
}

int? desktopMainRouteShortcutNumber(DesktopPane pane) {
  final index = desktopMainRoutes.indexWhere((route) => route.pane == pane);
  if (index < 0 || index >= desktopMainRouteShortcutKeys.length) return null;
  return index + 1;
}

String? desktopMainRouteShortcutLabel(DesktopPane pane, {bool? isMacOS}) {
  final number = desktopMainRouteShortcutNumber(pane);
  if (number == null) return null;
  return desktopPrimaryShortcutLabel('$number', isMacOS: isMacOS);
}

Iterable<({LogicalKeyboardKey key, DesktopPane pane})>
desktopMainRouteShortcutBindings() sync* {
  for (var i = 0; i < desktopMainRoutes.length; i++) {
    if (i >= desktopMainRouteShortcutKeys.length) break;
    yield (
      key: desktopMainRouteShortcutKeys[i],
      pane: desktopMainRoutes[i].pane,
    );
  }
}
