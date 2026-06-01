import 'package:chessever/desktop/services/desktop_changelog.dart';
import 'package:chessever/providers/app_version_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final desktopChangelogReleaseProvider =
    FutureProvider<DesktopChangelogRelease>((ref) async {
  final version = await ref.watch(appVersionProvider.future);
  return loadDesktopChangelogRelease(version);
});

class DesktopWhatsNewHomePane extends ConsumerWidget {
  const DesktopWhatsNewHomePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncRelease = ref.watch(desktopChangelogReleaseProvider);
    final version =
        ref.watch(appVersionProvider).valueOrNull ?? '';
    final release = asyncRelease.maybeWhen(
      data: (release) => release,
      orElse: () => fallbackDesktopChangelogRelease(version),
    );
    return _DesktopWhatsNewContent(release: release);
  }
}

class _DesktopWhatsNewContent extends StatelessWidget {
  const _DesktopWhatsNewContent({required this.release});

  final DesktopChangelogRelease release;

  @override
  Widget build(BuildContext context) {
    final entries = release.visibleEntries;
    return Container(
      color: kBackgroundColor,
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                release.resolvedTitle(fallbackVersion: release.version),
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                release.resolvedSubtitle(),
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              for (var i = 0; i < entries.length; i++) ...[
                _ChangelogEntryCard(entry: entries[i]),
                if (i != entries.length - 1) const SizedBox(height: 10),
              ],
              const SizedBox(height: 24),
              const Text(
                'Open a tab from the sidebar to start.',
                style: TextStyle(
                  color: kLightGreyColor,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChangelogEntryCard extends StatelessWidget {
  const _ChangelogEntryCard({required this.entry});

  final DesktopChangelogEntry entry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TypeBadge(type: entry.type),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.title,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (entry.shortcut != null) ...[
                      const SizedBox(width: 12),
                      _ShortcutPill(shortcut: entry.shortcut!),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  entry.summary,
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.type});

  final String type;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 88),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: _backgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _borderColor),
      ),
      child: Text(
        type,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: _textColor,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Color get _textColor {
    switch (type.toLowerCase()) {
      case 'new':
        return const Color(0xFF93C5FD);
      case 'fixed':
        return const Color(0xFFFCA5A5);
      case 'performance':
        return const Color(0xFF86EFAC);
      default:
        return const Color(0xFFC4B5FD);
    }
  }

  Color get _backgroundColor => _textColor.withValues(alpha: 0.12);

  Color get _borderColor => _textColor.withValues(alpha: 0.26);
}

class _ShortcutPill extends StatelessWidget {
  const _ShortcutPill({required this.shortcut});

  final String shortcut;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: kBackgroundColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: kDividerColor),
      ),
      child: Text(
        shortcut,
        style: const TextStyle(
          color: kLightGreyColor,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
