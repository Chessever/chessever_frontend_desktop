import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/widgets/desktop_access_gate.dart';

/// Admission belongs to a game/document lifetime, not every entitlement poll.
/// Once admitted, keep the board's private edits and exports alive on expiry.
/// New database/tree requests still use the live access policy individually.
class DesktopBoardAccessGate extends ConsumerStatefulWidget {
  const DesktopBoardAccessGate({
    super.key,
    required this.builder,
    this.requiresPremium = true,
    this.personalRecovery = false,
  });
  final WidgetBuilder builder;
  final bool requiresPremium;
  final bool personalRecovery;
  @override
  ConsumerState<DesktopBoardAccessGate> createState() =>
      _DesktopBoardAccessGateState();
}

class _DesktopBoardAccessGateState
    extends ConsumerState<DesktopBoardAccessGate> {
  bool _admitted = false;
  @override
  Widget build(BuildContext context) {
    if (!widget.requiresPremium ||
        widget.personalRecovery ||
        ref.watch(desktopPremiumAccessProvider) == DesktopAccess.allowed) {
      _admitted = true;
    }
    if (_admitted) return widget.builder(context);
    return const Center(
      child: SingleChildScrollView(
        child: DesktopLockedFeature(feature: 'Database games'),
      ),
    );
  }
}
