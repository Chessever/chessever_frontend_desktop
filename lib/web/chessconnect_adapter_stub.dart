import 'package:flutter/widgets.dart';

/// Native builds: Chessconnect only works with web pages.
void installChessconnectAdapter() {}

/// Whether this build can host the `#chessconnect-root` element.
const bool chessconnectRootSupported = false;

/// True once Chessconnect has put its connect button into the root element.
final ValueNotifier<bool> chessconnectRootHasContent = ValueNotifier<bool>(
  false,
);

Widget buildChessconnectRootView() => const SizedBox.shrink();
