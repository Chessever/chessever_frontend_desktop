import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class BotvinnikIcon extends StatelessWidget {
  static const _asset = 'assets/svgs/botvinnik_icon.svg';

  const BotvinnikIcon({
    required this.size,
    this.showShadow = false,
    this.color,
    super.key,
  });

  final double size;
  final bool showShadow;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: size,
      height: size,
      decoration:
          showShadow
              ? BoxDecoration(
                borderRadius: BorderRadius.circular(size * 0.2),
                boxShadow: [
                  BoxShadow(
                    color: effectiveColor.withValues(alpha: 0.2),
                    blurRadius: size * 0.28,
                    offset: Offset(0, size * 0.1),
                  ),
                ],
              )
              : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.2),
        child: SvgPicture.asset(
          _asset,
          width: size,
          height: size,
          fit: BoxFit.contain,
          colorFilter: ColorFilter.mode(effectiveColor, BlendMode.modulate),
          excludeFromSemantics: true,
        ),
      ),
    );
  }
}

class BotvinnikAnimatedIcon extends StatefulWidget {
  const BotvinnikAnimatedIcon({required this.size, super.key});

  final double size;

  @override
  State<BotvinnikAnimatedIcon> createState() => _BotvinnikAnimatedIconState();
}

class _BotvinnikAnimatedIconState extends State<BotvinnikAnimatedIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final wave = math.sin(_controller.value * math.pi * 2);
        return Transform.translate(
          offset: Offset(0, -1.8 * wave),
          child: Transform.rotate(angle: wave * 0.025, child: child),
        );
      },
      child: BotvinnikIcon(size: widget.size, showShadow: true),
    );
  }
}
