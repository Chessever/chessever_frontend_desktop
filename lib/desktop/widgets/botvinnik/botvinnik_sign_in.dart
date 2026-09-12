import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/auth/desktop_auth_service.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/desktop_modal.dart';
import 'package:chessever/theme/app_theme.dart';

/// Desktop sign-in for Botvinnik, one of the two places a permanent account
/// is required. Uses the same loopback OAuth as the Welcome screen, so it
/// works inside the shell without any mobile route. Returns true once a
/// non-anonymous session exists.
Future<bool> showBotvinnikSignIn(BuildContext context) async {
  await showDesktopModal<bool>(
    context,
    maxWidth: 400,
    title: 'Sign in to use Botvinnik',
    builder: (_) => const _BotvinnikSignInBody(),
  );
  return botvinnikHasPermanentSession();
}

bool botvinnikHasPermanentSession() {
  try {
    final user = Supabase.instance.client.auth.currentUser;
    return user != null && !user.isAnonymous;
  } catch (_) {
    return false;
  }
}

class _BotvinnikSignInBody extends StatefulWidget {
  const _BotvinnikSignInBody();

  @override
  State<_BotvinnikSignInBody> createState() => _BotvinnikSignInBodyState();
}

enum _Provider { google, apple }

class _BotvinnikSignInBodyState extends State<_BotvinnikSignInBody> {
  _Provider? _busy;
  String? _error;

  Future<void> _signIn(_Provider provider) async {
    setState(() {
      _busy = provider;
      _error = null;
    });
    try {
      if (provider == _Provider.google) {
        await DesktopAuthService.instance.signInWithGoogle();
      } else {
        await DesktopAuthService.instance.signInWithApple();
      }
      if (!mounted) return;
      if (botvinnikHasPermanentSession()) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() => _error = 'Sign-in did not finish. Try again.');
    } catch (error) {
      if (kDebugMode) debugPrint('[Botvinnik] sign-in failed: $error');
      if (mounted) {
        setState(() => _error = 'Sign-in did not finish. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Chats and your daily allowance live on your ChessEver account. '
            'Your draft stays in the composer.',
            style: TextStyle(color: kWhiteColor70, fontSize: 13, height: 1.45),
          ),
          const SizedBox(height: 20),
          _ProviderButton(
            asset: 'assets/svgs/google_g_color.svg',
            label:
                _busy == _Provider.google
                    ? 'Opening browser'
                    : 'Continue with Google',
            onPress: _busy == null ? () => _signIn(_Provider.google) : null,
          ),
          const SizedBox(height: 10),
          _ProviderButton(
            asset: 'assets/svgs/apple_logo.svg',
            tint: kWhiteColor,
            label:
                _busy == _Provider.apple
                    ? 'Opening Apple sign-in'
                    : 'Continue with Apple',
            onPress: _busy == null ? () => _signIn(_Provider.apple) : null,
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: const TextStyle(color: kRedColor, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProviderButton extends StatefulWidget {
  const _ProviderButton({
    required this.asset,
    required this.label,
    required this.onPress,
    this.tint,
  });

  final String asset;
  final String label;
  final VoidCallback? onPress;
  final Color? tint;

  @override
  State<_ProviderButton> createState() => _ProviderButtonState();
}

class _ProviderButtonState extends State<_ProviderButton>
    with DeferredPointerStateMixin<_ProviderButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPress != null;
    final hovered = enabled && _hovered;
    return CursorAware(
      mode: enabled ? CursorMode.hover : CursorMode.pointer,
      child: MouseRegion(
        onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
        onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPress,
          child: Semantics(
            button: true,
            enabled: enabled,
            label: widget.label,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: hovered ? kBlack3Color : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      hovered
                          ? kWhiteColor.withValues(alpha: 0.18)
                          : kDividerColor,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SvgPicture.asset(
                    widget.asset,
                    width: 18,
                    height: 18,
                    colorFilter:
                        widget.tint == null
                            ? null
                            : ColorFilter.mode(widget.tint!, BlendMode.srcIn),
                    excludeFromSemantics: true,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: enabled ? kWhiteColor : kLightGreyColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
