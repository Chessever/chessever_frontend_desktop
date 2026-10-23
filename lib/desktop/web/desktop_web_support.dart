import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/theme/app_theme.dart';

/// Panes the browser build (app.chessever.com) does not offer, because their
/// data or their work lives on the user's computer: local PGN and CBH
/// databases (Library), downloaded player databases and opening trees
/// (Prepare), and engine processes (Play).
const Set<DesktopPane> _desktopOnlyPanes = {
  DesktopPane.library,
  DesktopPane.players,
  DesktopPane.play,
};

/// Whether [pane] is offered in this build. Always true natively.
bool desktopPaneAvailable(DesktopPane pane) =>
    !kIsWeb || !_desktopOnlyPanes.contains(pane);

/// Whether a tab of [kind] can show its content in this build. Tabs whose
/// pane is desktop-only render [DesktopAppOnlyPane] in the browser, so every
/// way of reaching them (shortcuts, links, restored tabs) lands somewhere
/// that explains itself.
bool desktopTabKindAvailable(TabKind kind) => switch (kind) {
  TabKind.library || TabKind.players || TabKind.play => !kIsWeb,
  _ => true,
};

const String _desktopDownloadUrl = 'https://chessever.com/#download';

/// Stand-in for a desktop-only pane in the browser build.
class DesktopAppOnlyPane extends StatelessWidget {
  const DesktopAppOnlyPane({super.key, required this.kind});

  final TabKind kind;

  @override
  Widget build(BuildContext context) {
    final (title, reason) = switch (kind) {
      TabKind.library => (
        'Library',
        'Your databases are files on your computer, so the Library lives in '
            'the desktop app.',
      ),
      TabKind.players => (
        'Prepare',
        'Preparation downloads a player\'s games into a local database and '
            'builds opening trees from it on your computer.',
      ),
      TabKind.play => (
        'Play',
        'Games against the engine and local tournaments run Stockfish and '
            'other engines on your computer.',
      ),
      _ => ('This view', 'It needs the desktop app.'),
    };
    return ColoredBox(
      color: kBackgroundColor,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.desktop_windows_outlined,
                  size: 28,
                  color: kWhiteColor70,
                ),
                const SizedBox(height: 16),
                Text(
                  '$title is in the desktop app',
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  reason,
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 24),
                DesktopToolbarPillButton(
                  label: 'Get ChessEver for desktop',
                  icon: Icons.download_outlined,
                  tone: DesktopToolbarPillTone.primary,
                  onPress:
                      () => launchUrl(
                        Uri.parse(_desktopDownloadUrl),
                        webOnlyWindowName: '_blank',
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
