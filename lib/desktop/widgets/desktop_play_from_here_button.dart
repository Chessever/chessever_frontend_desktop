import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/play_forui_styles.dart';

class DesktopPlayFromHereButton extends StatelessWidget {
  const DesktopPlayFromHereButton({
    super.key,
    required this.onPress,
    this.label = 'Play from here',
  });

  final VoidCallback? onPress;
  final String label;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FButton(
        style: playPrimaryActionButtonStyle(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          radius: 7,
        ),
        prefix: const Icon(FIcons.play),
        onPress: onPress,
        child: Text(label, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
