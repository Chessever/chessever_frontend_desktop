import 'package:flutter/material.dart';

import 'package:chessever/theme/app_theme.dart';

/// Lightweight stand-in shown while a feature pane is being ported.
///
/// Renders the pane title, a short description of what will live here, and a
/// hint that the underlying mobile widgets will be reused. Lets the shell run
/// end-to-end before each pane is wired up.
class PlaceholderPane extends StatelessWidget {
  const PlaceholderPane({
    super.key,
    required this.title,
    required this.description,
  });

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBackgroundColor,
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                description,
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: kBlack2Color,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: kDividerColor),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.construction_outlined,
                        size: 14, color: kLightGreyColor),
                    SizedBox(width: 8),
                    Text(
                      'pane porting in progress — wraps existing mobile screen',
                      style: TextStyle(color: kLightGreyColor, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
