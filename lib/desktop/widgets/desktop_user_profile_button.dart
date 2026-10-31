import 'dart:math' as math;
import 'package:chessever/desktop/widgets/editorial/inbox_unread_anchor.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/providers/auth_state_provider.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/theme/app_theme.dart';

class DesktopUserProfileButton extends ConsumerWidget {
  const DesktopUserProfileButton({
    super.key,
    required this.onPress,
    this.size = 34,
    this.showLabel = false,
    this.tooltip = 'Open my player profile',
  });

  final VoidCallback? onPress;
  final double size;
  final bool showLabel;
  final String tooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = _resolveDisplayName(ref);
    final button = FButton.raw(
      style: _profileButtonStyle(showLabel: showLabel),
      onPress: onPress,
      child: Padding(
        padding:
            showLabel
                ? const EdgeInsets.fromLTRB(5, 4, 10, 4)
                : const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DesktopInboxUnreadAnchor(
              child: DesktopUserAvatar(size: size, displayName: name),
            ),
            if (showLabel) ...[
              const SizedBox(width: 9),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              const Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: kWhiteColor70,
              ),
            ],
          ],
        ),
      ),
    );

    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(message: tooltip, child: button),
    );
  }
}

class DesktopUserAvatar extends HookConsumerWidget {
  const DesktopUserAvatar({
    super.key,
    this.size = 40,
    this.displayName,
    this.avatarUrl,
    this.showPremiumBorder = true,
    this.borderRadius,
  });

  final double size;
  final String? displayName;
  final String? avatarUrl;
  final bool showPremiumBorder;
  final double? borderRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final playProfile = ref.watch(playUserProfileProvider).valueOrNull;
    final subscription = ref.watch(subscriptionProvider);
    final effectiveName =
        _clean(displayName) ??
        _clean(playProfile?.displayName) ??
        _clean(user?.displayName) ??
        _emailName(user?.email) ??
        'ChessEver Player';
    // Auth re-emits on every token refresh and sign-in step, and the user can
    // be briefly null in between. Hold the last photo for the same account so
    // those blips do not swap the photo for initials and fade it back in.
    final lastAvatar = useRef<(String?, String)?>(null);
    final resolvedAvatarUrl = _clean(avatarUrl) ?? _clean(user?.avatarUrl);
    if (resolvedAvatarUrl != null) {
      lastAvatar.value = (user?.id, resolvedAvatarUrl);
    } else if (user != null && lastAvatar.value?.$1 != user.id) {
      lastAvatar.value = null;
    }
    final effectiveAvatarUrl = resolvedAvatarUrl ?? lastAvatar.value?.$2;
    final initials = _initials(effectiveName);
    final premium = showPremiumBorder && subscription.isSubscribed;
    final radius = borderRadius ?? size / 2;
    final avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: effectiveAvatarUrl == null ? kPrimaryColor : kBlack3Color,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: kWhiteColor.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: kPrimaryColor.withValues(alpha: 0.10),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child:
          effectiveAvatarUrl == null
              ? _Initials(initials: initials, size: size)
              : CachedNetworkImage(
                imageUrl: effectiveAvatarUrl,
                fit: BoxFit.cover,
                // The browser build has no disk cache, so a re-resolve would
                // otherwise replay the placeholder and a 500ms fade each time.
                fadeInDuration: Duration.zero,
                fadeOutDuration: Duration.zero,
                placeholderFadeInDuration: Duration.zero,
                useOldImageOnUrlChange: true,
                memCacheWidth:
                    (size * MediaQuery.devicePixelRatioOf(context)).round(),
                memCacheHeight:
                    (size * MediaQuery.devicePixelRatioOf(context)).round(),
                placeholder:
                    (_, _) => _Initials(initials: initials, size: size),
                errorWidget:
                    (_, _, _) => _Initials(initials: initials, size: size),
              ),
    );

    if (!premium) return avatar;

    final borderWidth = math.max(2.0, size * 0.055);
    // A static ring. It used to sit in a repeating 4 s AnimationController
    // whose value the painter never read, which kept a frame scheduled at the
    // display's refresh rate for every subscriber, on every screen.
    return CustomPaint(
      painter: _PremiumAvatarRingPainter(
        radius: radius,
        strokeWidth: borderWidth,
      ),
      child: Padding(padding: EdgeInsets.all(borderWidth + 2), child: avatar),
    );
  }
}

class _Initials extends StatelessWidget {
  const _Initials({required this.initials, required this.size});

  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        initials.isEmpty ? 'CE' : initials,
        style: TextStyle(
          color: kBlack2Color,
          fontSize: math.max(11, size * 0.34),
          fontWeight: FontWeight.w900,
          height: 1,
        ),
      ),
    );
  }
}

class _PremiumAvatarRingPainter extends CustomPainter {
  const _PremiumAvatarRingPainter({
    required this.radius,
    required this.strokeWidth,
  });

  final double radius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = kPrimaryColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          strokeWidth / 2,
          strokeWidth / 2,
          size.width - strokeWidth,
          size.height - strokeWidth,
        ),
        Radius.circular(radius + strokeWidth),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _PremiumAvatarRingPainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.strokeWidth != strokeWidth;
}

FBaseButtonStyle Function(FButtonStyle style) _profileButtonStyle({
  required bool showLabel,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: kBlack3Color,
          borderRadius: BorderRadius.circular(showLabel ? 999 : 8),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.45)),
          boxShadow: [
            BoxShadow(
              color: kPrimaryColor.withValues(alpha: 0.12),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        WidgetState.focused: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(showLabel ? 999 : 8),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.70)),
        ),
        WidgetState.any: BoxDecoration(
          color: showLabel ? kBlack2Color : Colors.transparent,
          borderRadius: BorderRadius.circular(showLabel ? 999 : 8),
          border: Border.all(
            color: showLabel ? kDividerColor : Colors.transparent,
          ),
        ),
      }),
    ),
  );
}

String _resolveDisplayName(WidgetRef ref) {
  final user = ref.watch(currentUserProvider);
  final profile = ref.watch(playUserProfileProvider).valueOrNull;
  return _clean(profile?.displayName) ??
      _clean(user?.displayName) ??
      _emailName(user?.email) ??
      'ChessEver Player';
}

String? _clean(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}

String? _emailName(String? email) {
  final text = _clean(email);
  if (text == null) return null;
  return text.split('@').first;
}

String _initials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) return '';
  if (parts.length == 1) {
    return parts.first
        .substring(0, math.min(2, parts.first.length))
        .toUpperCase();
  }
  return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
}
