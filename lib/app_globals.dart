import 'package:flutter/material.dart';

/// Single shared route observer used by screens that want push/pop callbacks
/// (chess board, gamebase explorer).
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

/// Global navigator key for dialogs / upgrade flows that need the Navigator
/// without an in-hand BuildContext.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
