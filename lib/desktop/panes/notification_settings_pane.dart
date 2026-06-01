import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/providers/notification_preferences_provider.dart';
import 'package:chessever/providers/notifications_settings_provider.dart';
import 'package:chessever/theme/app_theme.dart';

/// Desktop notification preferences. Drives the same providers as the
/// mobile page (`notificationsSettingsProvider`,
/// `notificationPreferencesProvider`) but with desktop chrome — full-width
/// section cards, forui FSwitch for toggles, segmented controls for lead
/// time, and the master push toggle as a status row at the top.
class NotificationSettingsPane extends ConsumerWidget {
  const NotificationSettingsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pushSettings = ref.watch(notificationsSettingsProvider);
    final prefsAsync = ref.watch(notificationPreferencesProvider);
    final prefs = prefsAsync.valueOrNull ?? NotificationPreferences.defaults;
    final prefsLoading = prefsAsync.isLoading;
    final pushEnabled = pushSettings.enabled;
    final interactive = pushEnabled && !prefsLoading;

    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        color: kBackgroundColor,
        child: SingleChildScrollView(
          physics: const DesktopScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Header(),
                  const SizedBox(height: 24),
                  _MasterPushCard(
                    enabled: pushEnabled,
                    onChanged: (value) => ref
                        .read(notificationsSettingsProvider.notifier)
                        .setEnabled(value),
                  ),
                  const SizedBox(height: 16),
                  _CategoryCard(
                    icon: Icons.star_border_rounded,
                    title: 'Favourite players',
                    subtitle:
                        'Get notified when players you have starred are paired or finish a game.',
                    enabled: prefs.favoritePlayerAlerts,
                    interactive: interactive,
                    onParentToggle: (value) => ref
                        .read(notificationPreferencesProvider.notifier)
                        .setFavoritePlayerAlerts(value),
                    timeControls: _TimeControls(
                      classical: prefs.fpClassical,
                      rapid: prefs.fpRapid,
                      blitz: prefs.fpBlitz,
                      onClassical: (v) => ref
                          .read(notificationPreferencesProvider.notifier)
                          .setFpClassical(v),
                      onRapid: (v) => ref
                          .read(notificationPreferencesProvider.notifier)
                          .setFpRapid(v),
                      onBlitz: (v) => ref
                          .read(notificationPreferencesProvider.notifier)
                          .setFpBlitz(v),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _CategoryCard(
                    icon: Icons.bookmark_outline_rounded,
                    title: 'Starred events',
                    subtitle:
                        'Updates from tournaments you have starred — round starts, leaderboard shifts.',
                    enabled: prefs.favoriteEventAlerts,
                    interactive: interactive,
                    onParentToggle: (value) => ref
                        .read(notificationPreferencesProvider.notifier)
                        .setFavoriteEventAlerts(value),
                    timeControls: _TimeControls(
                      classical: prefs.seClassical,
                      rapid: prefs.seRapid,
                      blitz: prefs.seBlitz,
                      onClassical: (v) => ref
                          .read(notificationPreferencesProvider.notifier)
                          .setSeClassical(v),
                      onRapid: (v) => ref
                          .read(notificationPreferencesProvider.notifier)
                          .setSeRapid(v),
                      onBlitz: (v) => ref
                          .read(notificationPreferencesProvider.notifier)
                          .setSeBlitz(v),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _HeadsUpCard(
                    enabled: prefs.headsUpAlerts,
                    leadMinutes: prefs.headsUpLeadMinutes,
                    interactive: interactive,
                    onToggle: (v) => ref
                        .read(notificationPreferencesProvider.notifier)
                        .setHeadsUpAlerts(v),
                    onLeadChanged: (m) => ref
                        .read(notificationPreferencesProvider.notifier)
                        .setHeadsUpLeadMinutes(m),
                  ),
                  const SizedBox(height: 16),
                  _SimpleCard(
                    icon: Icons.library_books_outlined,
                    title: 'Library',
                    subtitle:
                        'Notify when subscribed databases gain new games or are revised.',
                    items: [
                      _SwitchItem(
                        label: 'Database updates',
                        description:
                            'Get notified when games are added, updated, or removed in your subscribed databases.',
                        value: prefs.bookUpdateAlerts,
                        interactive: interactive,
                        onChange: (v) => ref
                            .read(notificationPreferencesProvider.notifier)
                            .setBookUpdateAlerts(v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _SimpleCard(
                    icon: Icons.public_rounded,
                    title: 'Updates',
                    subtitle:
                        'Highlights and announcements from the chess world.',
                    items: [
                      _SwitchItem(
                        label: 'Chess World',
                        description:
                            'Occasional curated highlights from the broader chess scene.',
                        value: prefs.callToActionAlerts,
                        interactive: interactive,
                        onChange: (v) => ref
                            .read(notificationPreferencesProvider.notifier)
                            .setCallToActionAlerts(v),
                      ),
                    ],
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

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Notifications',
          style: TextStyle(
            color: kWhiteColor,
            fontSize: 24,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
        ),
        SizedBox(height: 4),
        Text(
          'Master push toggle and per-category alert preferences',
          style: TextStyle(color: kWhiteColor70, fontSize: 13),
        ),
      ],
    );
  }
}

// ─── Master push card ────────────────────────────────────────────────────────

class _MasterPushCard extends StatelessWidget {
  const _MasterPushCard({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: enabled
              ? kPrimaryColor.withValues(alpha: 0.45)
              : kDividerColor,
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: enabled
                  ? kPrimaryColor.withValues(alpha: 0.15)
                  : kBlack3Color,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(
              enabled
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_off_outlined,
              size: 18,
              color: enabled ? kPrimaryColor : kWhiteColor70,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Push notifications',
                      style: TextStyle(
                        color: kWhiteColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 10),
                    _StatusPill(
                      label: enabled ? 'Enabled' : 'Disabled',
                      color: enabled ? kGreenColor : kLightGreyColor,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  enabled
                      ? 'Per-category preferences below decide what gets delivered.'
                      : 'Turn this on to enable any notifications. Categories are disabled while this is off.',
                  style: const TextStyle(color: kWhiteColor70, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          FSwitch(value: enabled, onChange: onChanged),
        ],
      ),
    );
  }
}

// ─── Category card with parent toggle + time-control sub-toggles ────────────

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.interactive,
    required this.onParentToggle,
    required this.timeControls,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final bool interactive;
  final ValueChanged<bool> onParentToggle;
  final _TimeControls timeControls;

  @override
  Widget build(BuildContext context) {
    final dim = !interactive;
    return Opacity(
      opacity: dim ? 0.55 : 1.0,
      child: IgnorePointer(
        ignoring: dim,
        child: Container(
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kDividerColor),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: kWhiteColor70),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  FSwitch(value: enabled, onChange: onParentToggle),
                ],
              ),
              if (enabled) ...[
                const SizedBox(height: 16),
                const Divider(color: kDividerColor, height: 1),
                const SizedBox(height: 16),
                _TimeControlRow(
                  controls: timeControls,
                  enabled: enabled,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TimeControls {
  const _TimeControls({
    required this.classical,
    required this.rapid,
    required this.blitz,
    required this.onClassical,
    required this.onRapid,
    required this.onBlitz,
  });

  final bool classical;
  final bool rapid;
  final bool blitz;
  final ValueChanged<bool> onClassical;
  final ValueChanged<bool> onRapid;
  final ValueChanged<bool> onBlitz;
}

class _TimeControlRow extends StatelessWidget {
  const _TimeControlRow({required this.controls, required this.enabled});

  final _TimeControls controls;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Time controls',
          style: TextStyle(
            color: kWhiteColor,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          'Choose which formats are noisy enough to be worth a ping.',
          style: TextStyle(color: kWhiteColor70, fontSize: 11),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ToggleChip(
                label: 'Classical',
                value: controls.classical,
                onChange: controls.onClassical,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ToggleChip(
                label: 'Rapid',
                value: controls.rapid,
                onChange: controls.onRapid,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ToggleChip(
                label: 'Blitz',
                value: controls.blitz,
                onChange: controls.onBlitz,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ToggleChip extends StatefulWidget {
  const _ToggleChip({
    required this.label,
    required this.value,
    required this.onChange,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChange;

  @override
  State<_ToggleChip> createState() => _ToggleChipState();
}

class _ToggleChipState extends State<_ToggleChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.value;
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: () => widget.onChange(!widget.value),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? kPrimaryColor.withValues(alpha: 0.14)
                  : (_hovered ? kBlack3Color : kBlackColor),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected
                    ? kPrimaryColor
                    : (_hovered ? kDividerColor : kDividerColor),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 14,
                  color: selected ? kPrimaryColor : kWhiteColor70,
                ),
                const SizedBox(width: 8),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: selected ? kWhiteColor : kWhiteColor70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
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

// ─── Heads-up alerts card with lead-time selector ───────────────────────────

class _HeadsUpCard extends StatelessWidget {
  const _HeadsUpCard({
    required this.enabled,
    required this.leadMinutes,
    required this.interactive,
    required this.onToggle,
    required this.onLeadChanged,
  });

  final bool enabled;
  final int leadMinutes;
  final bool interactive;
  final ValueChanged<bool> onToggle;
  final ValueChanged<int> onLeadChanged;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: interactive ? 1.0 : 0.55,
      child: IgnorePointer(
        ignoring: !interactive,
        child: Container(
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kDividerColor),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.alarm_rounded,
                    size: 16,
                    color: kWhiteColor70,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Heads-up alerts',
                          style: TextStyle(
                            color: kWhiteColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'A heads-up before rounds start so you can settle in.',
                          style: TextStyle(
                            color: kWhiteColor70,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  FSwitch(value: enabled, onChange: onToggle),
                ],
              ),
              if (enabled) ...[
                const SizedBox(height: 16),
                const Divider(color: kDividerColor, height: 1),
                const SizedBox(height: 16),
                const Text(
                  'Notify me before the round',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _LeadTimeOption(
                        label: '10 minutes before',
                        value: 10,
                        selected: leadMinutes == 10,
                        onTap: () => onLeadChanged(10),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _LeadTimeOption(
                        label: '30 minutes before',
                        value: 30,
                        selected: leadMinutes == 30,
                        onTap: () => onLeadChanged(30),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LeadTimeOption extends StatefulWidget {
  const _LeadTimeOption({
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int value;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_LeadTimeOption> createState() => _LeadTimeOptionState();
}

class _LeadTimeOptionState extends State<_LeadTimeOption> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: selected
                  ? kPrimaryColor.withValues(alpha: 0.14)
                  : (_hovered ? kBlack3Color : kBlackColor),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? kPrimaryColor : kDividerColor,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 16,
                  color: selected ? kPrimaryColor : kWhiteColor70,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      color: selected ? kWhiteColor : kWhiteColor70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
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

// ─── Generic single-toggle card ──────────────────────────────────────────────

class _SimpleCard extends StatelessWidget {
  const _SimpleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.items,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<_SwitchItem> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: kWhiteColor70),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(color: kWhiteColor70, fontSize: 12),
          ),
          const SizedBox(height: 12),
          const Divider(color: kDividerColor, height: 1),
          const SizedBox(height: 16),
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(color: kDividerColor, height: 1),
            items[i],
          ],
        ],
      ),
    );
  }
}

class _SwitchItem extends StatelessWidget {
  const _SwitchItem({
    required this.label,
    required this.description,
    required this.value,
    required this.interactive,
    required this.onChange,
  });

  final String label;
  final String description;
  final bool value;
  final bool interactive;
  final ValueChanged<bool> onChange;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: interactive ? 1.0 : 0.55,
      child: IgnorePointer(
        ignoring: !interactive,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              FSwitch(value: value, onChange: onChange),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Status pill (mirrors settings_pane.dart styling) ───────────────────────

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
