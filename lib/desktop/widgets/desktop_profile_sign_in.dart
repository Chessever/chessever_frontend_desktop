import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/services/auth/desktop_auth_browser.dart';
import 'package:chessever/desktop/services/auth/desktop_guest_upgrade.dart';
import 'package:chessever/desktop/widgets/desktop_icon.dart';
import 'package:chessever/desktop/widgets/play_forui_styles.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/svg_asset.dart';

/// The first action on a guest's profile, independent of local profile loading.
class DesktopProfileSignIn extends StatelessWidget {
  const DesktopProfileSignIn({
    super.key,
    required this.onSignIn,
    this.busyProvider,
    this.error,
  });

  final ValueChanged<DesktopAccountProvider> onSignIn;
  final DesktopAccountProvider? busyProvider;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sign in to your ChessEver account',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              "You're browsing as a guest. Sign in to sync your favorites, "
              'library and settings across devices.',
              style: TextStyle(color: kWhiteColor70, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 20),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final google = _button(DesktopAccountProvider.google);
                  final apple = _button(DesktopAccountProvider.apple);
                  if (constraints.maxWidth <
                      MediaQuery.textScalerOf(context).scale(480)) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [google, const SizedBox(height: 10), apple],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: google),
                      const SizedBox(width: 12),
                      Expanded(child: apple),
                    ],
                  );
                },
              ),
            ),
            if (busyProvider != null || error != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  error ??
                      switch ((busyProvider, DesktopAuthBrowser.inApp)) {
                        (DesktopAccountProvider.google, _) when kIsWeb =>
                          'Taking you to Google…',
                        (_, _) when kIsWeb => 'Taking you to Apple…',
                        (DesktopAccountProvider.google, false) =>
                          'Finish signing in with Google in your browser.',
                        (DesktopAccountProvider.google, true) =>
                          'Finish signing in with Google in the sign-in window.',
                        (_, false) =>
                          'Finish signing in with Apple in your browser.',
                        (_, true) => 'Finish signing in with Apple.',
                      },
                  style: TextStyle(
                    color: error == null ? kWhiteColor70 : kRedColor,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _button(DesktopAccountProvider provider) {
    final isGoogle = provider == DesktopAccountProvider.google;
    final label = isGoogle ? 'Sign in with Google' : 'Sign in with Apple';
    return FButton(
      style: playPrimaryActionButtonStyle(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        radius: 8,
      ),
      onPress: busyProvider == null ? () => onSignIn(provider) : null,
      prefix: DesktopIcon(
        isGoogle ? SvgAsset.googleColorIcon : SvgAsset.appleIcon,
        size: 18,
        color: isGoogle ? null : kWhiteColor,
      ),
      child: Flexible(
        child: Text(
          busyProvider == provider ? 'Signing in…' : label,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
