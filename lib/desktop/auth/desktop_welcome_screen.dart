import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/services/auth/desktop_auth_service.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_icon.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/svg_asset.dart';

/// First-launch welcome for signed-out desktop users.
///
/// Minimal: brand logo + Google/Apple sign-in buttons. No copy.
class DesktopWelcomeScreen extends HookConsumerWidget {
  const DesktopWelcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signingIn = useState<bool>(false);
    final lastError = useState<String?>(null);

    Future<void> handleGoogleSignIn() async {
      lastError.value = null;
      signingIn.value = true;
      try {
        await DesktopAuthService.instance.signInWithGoogle();
      } catch (e, st) {
        ErrorReporter.report(e, stackTrace: st, tag: 'auth.google');
        lastError.value = _friendly(e);
      } finally {
        signingIn.value = false;
      }
    }

    Future<void> handleAppleSignIn() async {
      lastError.value = null;
      signingIn.value = true;
      try {
        await DesktopAuthService.instance.signInWithApple();
      } catch (e, st) {
        ErrorReporter.report(e, stackTrace: st, tag: 'auth.apple');
        lastError.value = _friendly(e);
      } finally {
        signingIn.value = false;
      }
    }

    return Scaffold(
      backgroundColor: kBackgroundColor,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(48),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: Image.asset(
                      'assets/pngs/new_app_logo.png',
                      width: 128,
                      height: 128,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                ),
                const SizedBox(height: 40),
                _AuthButton(
                  iconAsset: SvgAsset.googleColorIcon,
                  label:
                      signingIn.value
                          ? 'Opening browser…'
                          : 'Continue with Google',
                  primary: true,
                  disabled: signingIn.value,
                  onTap: handleGoogleSignIn,
                ),
                const SizedBox(height: 12),
                _AuthButton(
                  iconAsset: SvgAsset.appleIcon,
                  label:
                      signingIn.value
                          ? 'Opening Apple sign-in…'
                          : 'Continue with Apple',
                  primary: false,
                  disabled: signingIn.value,
                  onTap: handleAppleSignIn,
                ),
                if (lastError.value != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: kRedColor.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: kRedColor.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      lastError.value!,
                      style: const TextStyle(color: kRedColor, fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthButton extends StatefulWidget {
  const _AuthButton({
    required this.iconAsset,
    required this.label,
    required this.primary,
    required this.disabled,
    required this.onTap,
  });

  /// Path to a project SVG under `assets/svgs/` — the brand mark for the
  /// auth provider.
  final String iconAsset;
  final String label;
  final bool primary;
  final bool disabled;
  final VoidCallback? onTap;

  @override
  State<_AuthButton> createState() => _AuthButtonState();
}

class _AuthButtonState extends State<_AuthButton> {
  bool _hovered = false;
  bool _pressed = false;

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setState(() {
      _hovered = hovered;
      if (!hovered) _pressed = false;
    });
  }

  void _setStates(FWidgetStatesDelta delta) {
    final pressed = delta.current.contains(WidgetState.pressed);
    if (_pressed == pressed) return;
    setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final scale =
        widget.disabled ? 1.0 : (_pressed ? 0.97 : (_hovered ? 1.02 : 1.0));

    return FTheme(
      data: FThemes.zinc.dark,
      child: ClickCursor(
        enabled: !widget.disabled,
        child: SingleMotionBuilder(
          value: scale,
          motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
          builder:
              (context, value, child) =>
                  Transform.scale(scale: value, child: child),
          child: FButton(
            style: _welcomeAuthButtonStyle(primary: widget.primary),
            onPress: widget.disabled ? null : widget.onTap,
            onHoverChange: widget.disabled ? null : _setHovered,
            onStateChange: widget.disabled ? null : _setStates,
            mainAxisSize: MainAxisSize.max,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                DesktopIcon(
                  widget.iconAsset,
                  size: 20,
                  color: widget.primary ? null : kWhiteColor,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(widget.label, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _welcomeAuthButtonStyle({
  required bool primary,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.disabled: BoxDecoration(
          color: (primary ? kPrimaryColor : kBlack3Color).withValues(
            alpha: 0.40,
          ),
          borderRadius: BorderRadius.circular(10),
          border: primary ? null : Border.all(color: kDividerColor),
        ),
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: primary ? kPrimaryColor : kBlack2Color,
          borderRadius: BorderRadius.circular(10),
          border:
              primary
                  ? Border.all(color: kLightYellowColor.withValues(alpha: 0.55))
                  : Border.all(color: kWhiteColor.withValues(alpha: 0.22)),
          boxShadow: [
            BoxShadow(
              color:
                  primary
                      ? kPrimaryColor.withValues(alpha: 0.18)
                      : Colors.black.withValues(alpha: 0.22),
              blurRadius: 16,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        WidgetState.any: BoxDecoration(
          color: primary ? kPrimaryColor.withValues(alpha: 0.92) : kBlack3Color,
          borderRadius: BorderRadius.circular(10),
          border: primary ? null : Border.all(color: kDividerColor),
        ),
      }),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            spacing: 12,
            textStyle: FWidgetStateMap({
              WidgetState.disabled: TextStyle(
                color:
                    primary
                        ? kBackgroundColor.withValues(alpha: 0.48)
                        : kWhiteColor.withValues(alpha: 0.38),
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
              WidgetState.any: TextStyle(
                color: primary ? kBackgroundColor : kWhiteColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            }),
          ),
    ),
  );
}

String _friendly(Object error) {
  final str = error.toString();
  if (str.contains('GOOGLE_DESKTOP_CLIENT_ID') ||
      str.contains('GOOGLE_WEB_CLIENT_ID')) {
    return 'Google sign-in is not configured for this build. Pass '
        '--dart-define=GOOGLE_DESKTOP_CLIENT_ID=… and try again.';
  }
  if (str.contains('AuthorizationErrorCode.canceled') ||
      str.contains('canceled')) {
    return 'Sign-in was cancelled.';
  }
  if (str.contains('Apple sign-in is not available') ||
      str.contains('Sign in with Apple capability')) {
    return 'Apple sign-in is not available for this build. Make sure Apple '
        'OAuth is enabled in Supabase.';
  }
  if (str.contains('TimeoutException') || str.contains('timed out')) {
    return 'Sign-in timed out. Try again — the browser tab may have closed. '
        'For Apple, also check that Supabase allows '
        'http://127.0.0.1:*/auth/callback as a redirect URL.';
  }
  if (str.contains('CSRF')) {
    return 'Security check failed during sign-in. Please retry.';
  }
  if (str.contains('token exchange failed') || str.contains('invalid_client')) {
    return 'Google rejected the token exchange. Use a Desktop-app OAuth '
        'client ID and its matching client secret from Google Cloud Console.';
  }
  if (str.contains('Invalid API key')) {
    return 'Supabase rejected this build\'s API key. Check '
        'SUPABASE_ANON_KEY in the --dart-define command, then rebuild and '
        'retry.';
  }
  if (str.contains('signInWithIdToken') ||
      str.contains('exchangeCodeForSession') ||
      str.contains('AuthApiException') ||
      str.contains('Unable to validate JWT')) {
    return 'Supabase rejected the provider sign-in. Make sure Google OAuth '
        'uses the desktop client ID, and Apple OAuth is enabled with its '
        'Services ID and secret in the Supabase dashboard.';
  }
  return 'Sign-in failed. Please try again.';
}
