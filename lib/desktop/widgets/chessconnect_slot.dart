import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:chessever/desktop/services/chessconnect/chessconnect_bridge.dart';
import 'package:chessever/web/chessconnect_adapter.dart';

/// Room under a board for Chessconnect's connect button (`#chessconnect-root`,
/// adapter spec section 6).
///
/// Takes no space at all until Chessconnect has announced itself on this page
/// (its first `onConnectionChange` call), which only happens after the user
/// has turned Chessconnect on for the site. Only the board that owns the
/// bridge renders it, so the page never holds two roots. If Chessconnect
/// leaves the element empty (its phone apps show their own status), the
/// slot shrinks back to a single pixel after a short grace period.
class ChessconnectSlot extends StatefulWidget {
  const ChessconnectSlot({super.key, required this.owner});

  /// The board surface this slot sits under; see [ChessconnectBridge.attach].
  final Object owner;

  @override
  State<ChessconnectSlot> createState() => _ChessconnectSlotState();
}

class _ChessconnectSlotState extends State<ChessconnectSlot> {
  static const double _width = 240;
  static const double _height = 44;
  static const Duration _emptyGrace = Duration(seconds: 3);

  Timer? _graceTimer;
  bool _graceOver = false;

  @override
  void dispose() {
    _graceTimer?.cancel();
    super.dispose();
  }

  void _startGrace() {
    if (_graceTimer != null) return;
    _graceTimer = Timer(_emptyGrace, () {
      if (mounted) setState(() => _graceOver = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!chessconnectRootSupported) return const SizedBox.shrink();
    final bridge = ChessconnectBridge.instance;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        bridge.activeOwner,
        bridge.connection,
        chessconnectRootHasContent,
      ]),
      builder: (context, _) {
        if (!identical(bridge.activeOwner.value, widget.owner) ||
            bridge.connection.value == null) {
          return const SizedBox.shrink();
        }
        _startGrace();
        final roomy = chessconnectRootHasContent.value || !_graceOver;
        return Center(
          child: SizedBox(
            width: _width,
            height: roomy ? _height : 1,
            child: buildChessconnectRootView(),
          ),
        );
      },
    );
  }
}
