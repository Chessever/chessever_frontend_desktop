import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Zen-style board focus for the active desktop Board tab.
///
/// The board pane owns the visible toggle, while the shell watches this to
/// remove global chrome when the foreground tab is a board.
final boardFocusModeProvider = StateProvider<bool>((ref) => false);
