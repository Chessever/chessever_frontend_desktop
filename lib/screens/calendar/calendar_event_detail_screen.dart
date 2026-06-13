import 'package:cached_network_image/cached_network_image.dart';
import 'package:chessever/e2e/e2e_ids.dart';
import 'package:chessever/repository/supabase/calendar_event/calendar_event.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/app_typography.dart';
import 'package:chessever/utils/png_asset.dart';
import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

class CalendarEventDetailScreen extends StatefulWidget {
  const CalendarEventDetailScreen({
    super.key,
    required this.event,
    this.navigationEvents = const <CalendarEvent>[],
    this.initialEventIndex,
  });

  final CalendarEvent event;
  final List<CalendarEvent> navigationEvents;
  final int? initialEventIndex;

  @override
  State<CalendarEventDetailScreen> createState() =>
      _CalendarEventDetailScreenState();
}

class _CalendarEventDetailScreenState extends State<CalendarEventDetailScreen> {
  late CalendarEvent event;
  late int _currentIndex;

  List<CalendarEvent> get _navigationEvents => widget.navigationEvents;
  bool get _canNavigate => _navigationEvents.length > 1;
  bool get _hasPrevious => _canNavigate && _currentIndex > 0;
  bool get _hasNext =>
      _canNavigate && _currentIndex < _navigationEvents.length - 1;

  @override
  void initState() {
    super.initState();
    event = widget.event;
    _currentIndex =
        widget.initialEventIndex ??
        _navigationEvents.indexWhere(
          (candidate) =>
              candidate.name == widget.event.name &&
              candidate.startDate == widget.event.startDate &&
              candidate.endDate == widget.event.endDate,
        );
    if (_currentIndex < 0 && _navigationEvents.isNotEmpty) {
      _currentIndex = 0;
    }
  }

  @override
  void didUpdateWidget(CalendarEventDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event != widget.event ||
        oldWidget.navigationEvents != widget.navigationEvents) {
      event = widget.event;
      _currentIndex =
          widget.initialEventIndex ??
          _navigationEvents.indexWhere(
            (candidate) =>
                candidate.name == widget.event.name &&
                candidate.startDate == widget.event.startDate &&
                candidate.endDate == widget.event.endDate,
          );
      if (_currentIndex < 0 && _navigationEvents.isNotEmpty) {
        _currentIndex = 0;
      }
    }
  }

  void _showEventAt(int index) {
    if (index < 0 || index >= _navigationEvents.length) return;
    setState(() {
      _currentIndex = index;
      event = _navigationEvents[index];
    });
  }

  void _showPreviousEvent() => _showEventAt(_currentIndex - 1);
  void _showNextEvent() => _showEventAt(_currentIndex + 1);

  String _formatDateRange() {
    final dateFormat = DateFormat('MMM d, yyyy');
    if (event.startDate == null && event.endDate == null) return 'TBA';
    if (event.startDate != null && event.endDate != null) {
      return '${dateFormat.format(event.startDate!)} - ${dateFormat.format(event.endDate!)}';
    }
    return dateFormat.format(event.startDate ?? event.endDate!);
  }

  String get _sourceUrl {
    final fideId = event.fideEventId?.trim();
    if (fideId != null && fideId.isNotEmpty) {
      return 'https://calendar.fide.com/calendar.php?id=$fideId';
    }
    return event.website ?? event.websiteUrl ?? '';
  }

  List<String> _getTopPlayers() {
    if (event.players == null || event.players!.isEmpty) return [];

    final playerNames = <Map<String, dynamic>>[];
    for (final p in event.players!) {
      if (p is String && p.isNotEmpty) {
        playerNames.add({'name': p, 'rating': 0});
      } else if (p is Map) {
        final name = p['name']?.toString() ?? '';
        final rating = p['rating'] ?? 0;
        if (name.isNotEmpty) {
          playerNames.add({'name': name, 'rating': rating is int ? rating : 0});
        }
      }
    }

    playerNames.sort(
      (a, b) => (b['rating'] as int).compareTo(a['rating'] as int),
    );
    return playerNames.take(8).map((p) => p['name'] as String).toList();
  }

  Future<void> _launch(String? url) async {
    if (url == null || url.trim().isEmpty) return;
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _launchEmail(String? email) async {
    if (email == null || email.trim().isEmpty) return;
    final uri = Uri(scheme: 'mailto', path: email.trim());
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    final website = event.website ?? event.websiteUrl;
    final topPlayers = _getTopPlayers();
    final location = [
      event.city,
      event.location,
      event.country,
    ].where((v) => v != null && v.trim().isNotEmpty).join(' · ');

    return Scaffold(
      key: e2eKey(E2eIds.calendarEventDetailRoot),
      backgroundColor: kBlackColor,
      appBar: AppBar(
        title: Text(
          event.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTypography.textLgBold.copyWith(color: kWhiteColor),
        ),
        backgroundColor: kBlack2Color,
        iconTheme: const IconThemeData(color: kWhiteColor),
        actions: [
          if (_canNavigate) ...[
            IconButton(
              tooltip: 'Previous event',
              onPressed: _hasPrevious ? _showPreviousEvent : null,
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            IconButton(
              tooltip: 'Next event',
              onPressed: _hasNext ? _showNextEvent : null,
              icon: const Icon(Icons.chevron_right_rounded),
            ),
            const SizedBox(width: 4),
          ],
          if (_sourceUrl.isNotEmpty)
            TextButton.icon(
              onPressed: () => _launch(_sourceUrl),
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('Open source'),
              style: TextButton.styleFrom(foregroundColor: kPrimaryColor),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 22, 28, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _HeroHeader(
                      event: event,
                      dateRange: _formatDateRange(),
                      location: location.isEmpty
                          ? event.location ?? 'TBA'
                          : location,
                      onOpenSource: _sourceUrl.isEmpty
                          ? null
                          : () => _launch(_sourceUrl),
                    ),
                    const SizedBox(height: 18),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final wide = constraints.maxWidth >= 860;
                        final main = _MainDetails(
                          event: event,
                          topPlayers: topPlayers,
                          onLaunchWebsite: website == null
                              ? null
                              : () => _launch(website),
                          onLaunchEmail: event.email == null
                              ? null
                              : () => _launchEmail(event.email),
                        );
                        final summary = _SummaryRail(
                          event: event,
                          dateRange: _formatDateRange(),
                          sourceUrl: _sourceUrl,
                          onOpenSource: _sourceUrl.isEmpty
                              ? null
                              : () => _launch(_sourceUrl),
                          onCopyAddress: _copyableAddress(event).isEmpty
                              ? null
                              : () => Clipboard.setData(
                                  ClipboardData(text: _copyableAddress(event)),
                                ),
                        );
                        if (!wide) {
                          return Column(
                            children: [
                              main,
                              const SizedBox(height: 16),
                              summary,
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 7, child: main),
                            const SizedBox(width: 16),
                            Expanded(flex: 3, child: summary),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_canNavigate) ...[
            _EventSideArrow(
              alignment: Alignment.centerLeft,
              icon: Icons.chevron_left_rounded,
              tooltip: 'Previous event',
              enabled: _hasPrevious,
              onTap: _showPreviousEvent,
            ),
            _EventSideArrow(
              alignment: Alignment.centerRight,
              icon: Icons.chevron_right_rounded,
              tooltip: 'Next event',
              enabled: _hasNext,
              onTap: _showNextEvent,
            ),
          ],
        ],
      ),
    );
  }

  String _copyableAddress(CalendarEvent event) => [
    event.venue,
    event.address,
    event.city,
    event.country,
  ].where((v) => v != null && v.trim().isNotEmpty).join(', ');
}

class _EventSideArrow extends StatelessWidget {
  const _EventSideArrow({
    required this.alignment,
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final Alignment alignment;
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Tooltip(
          message: tooltip,
          child: Material(
            color: kBlack2Color.withValues(alpha: enabled ? 0.92 : 0.42),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: enabled ? onTap : null,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  icon,
                  color: enabled ? kWhiteColor : kWhiteColor.withValues(alpha: 0.3),
                  size: 30,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroHeader extends StatelessWidget {
  const _HeroHeader({
    required this.event,
    required this.dateRange,
    required this.location,
    required this.onOpenSource,
  });

  final CalendarEvent event;
  final String dateRange;
  final String location;
  final VoidCallback? onOpenSource;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kDividerColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: 230, child: _buildHeroImage(context)),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _Badge(icon: Icons.event_outlined, label: dateRange),
                    if ((event.timeControl ?? '').isNotEmpty)
                      _Badge(
                        icon: Icons.timer_outlined,
                        label: event.timeControl!,
                      ),
                    if (event.fideEventId != null &&
                        event.fideEventId!.isNotEmpty)
                      const _Badge(
                        icon: Icons.verified_outlined,
                        label: 'FIDE Calendar',
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                SelectableText(
                  event.name,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (event.countryCode != null &&
                        event.countryCode!.isNotEmpty) ...[
                      CountryFlag.fromCountryCode(
                        event.countryCode!,
                        theme: const ImageTheme(width: 18, height: 13),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        location,
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (onOpenSource != null)
                      TextButton.icon(
                        onPressed: onOpenSource,
                        icon: const Icon(Icons.open_in_new_rounded, size: 15),
                        label: const Text('Open FIDE page'),
                        style: TextButton.styleFrom(
                          foregroundColor: kPrimaryColor,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroImage(BuildContext context) {
    if (event.imageUrl != null && event.imageUrl!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: event.imageUrl!,
        fit: BoxFit.cover,
        memCacheWidth:
            (MediaQuery.sizeOf(context).width *
                    MediaQuery.devicePixelRatioOf(context))
                .toInt(),
        fadeInDuration: const Duration(milliseconds: 300),
        fadeOutDuration: const Duration(milliseconds: 200),
        alignment: Alignment.topCenter,
        placeholder: (_, __) => _buildPlaceholder(),
        errorWidget: (_, __, ___) => _buildPlaceholder(),
      );
    }
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    if (event.countryCode != null && event.countryCode!.isNotEmpty) {
      return Container(
        color: kLightBlack,
        alignment: Alignment.center,
        child: SizedBox(
          width: 140,
          height: 92,
          child: CountryFlag.fromCountryCode(
            event.countryCode!,
            theme: const ImageTheme(shape: RoundedRectangle(12)),
          ),
        ),
      );
    }
    return Container(
      color: kLightBlack,
      alignment: Alignment.center,
      child: Image.asset(
        PngAsset.premiumIcon,
        height: 100,
        fit: BoxFit.contain,
      ),
    );
  }
}

class _MainDetails extends StatelessWidget {
  const _MainDetails({
    required this.event,
    required this.topPlayers,
    required this.onLaunchWebsite,
    required this.onLaunchEmail,
  });

  final CalendarEvent event;
  final List<String> topPlayers;
  final VoidCallback? onLaunchWebsite;
  final VoidCallback? onLaunchEmail;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if ((event.description ?? '').trim().isNotEmpty)
          _SectionCard(
            title: 'About',
            children: [
              SelectableText(
                event.description!.trim(),
                style: const TextStyle(
                  color: kWhiteColor70,
                  height: 1.45,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        _SectionCard(
          title: 'Format',
          children: [
            _InfoGrid(
              items: [
                _InfoItem('Type of event', event.eventType),
                _InfoItem('Time control', event.timeControl ?? 'Standard'),
                _InfoItem(
                  'Time control description',
                  event.timeControlDescription,
                ),
                _InfoItem('Tournament system', event.tournamentSystem),
                _InfoItem('Number of rounds', event.numberOfRounds?.toString()),
                _InfoItem(
                  'Number of players',
                  event.numberOfPlayers?.toString(),
                ),
                _InfoItem('Total prize fund', event.totalPrizeFund),
              ],
            ),
          ],
        ),
        _SectionCard(
          title: 'Address',
          children: [
            _InfoGrid(
              items: [
                _InfoItem('Country', event.country),
                _InfoItem('City', event.city),
                _InfoItem('Venue', event.venue),
                _InfoItem('Address', event.address ?? event.location),
              ],
            ),
          ],
        ),
        _SectionCard(
          title: 'Contacts',
          children: [
            _LinkRow(
              label: 'Website',
              value: event.website ?? event.websiteUrl,
              onTap: onLaunchWebsite,
            ),
            _LinkRow(label: 'E-mail', value: event.email, onTap: onLaunchEmail),
          ],
        ),
        if (topPlayers.isNotEmpty)
          _SectionCard(
            title: 'Players',
            children: [
              SelectableText(
                topPlayers.join(', '),
                style: const TextStyle(
                  color: kWhiteColor70,
                  height: 1.4,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        _ListSection(title: 'Documents', values: _stringList(event.documents)),
        _ListSection(title: 'Arbiters', values: _stringList(event.arbiters)),
      ].where((w) => w is! _EmptySection).toList(),
    );
  }

  List<String> _stringList(List<dynamic>? raw) {
    if (raw == null) return const [];
    return raw
        .map((item) {
          if (item is String) return item;
          if (item is Map) {
            return (item['name'] ??
                    item['title'] ??
                    item['file'] ??
                    item['url'] ??
                    '')
                .toString();
          }
          return item.toString();
        })
        .where((value) => value.trim().isNotEmpty)
        .toList(growable: false);
  }
}

class _SummaryRail extends StatelessWidget {
  const _SummaryRail({
    required this.event,
    required this.dateRange,
    required this.sourceUrl,
    required this.onOpenSource,
    required this.onCopyAddress,
  });

  final CalendarEvent event;
  final String dateRange;
  final String sourceUrl;
  final VoidCallback? onOpenSource;
  final VoidCallback? onCopyAddress;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Summary',
      children: [
        _CompactFact(icon: Icons.event_outlined, label: dateRange),
        _CompactFact(
          icon: Icons.timer_outlined,
          label: event.timeControl ?? 'Standard',
        ),
        if ((event.location ?? '').isNotEmpty)
          _CompactFact(icon: Icons.place_outlined, label: event.location!),
        if (event.numberOfRounds != null)
          _CompactFact(
            icon: Icons.format_list_numbered_rounded,
            label: '${event.numberOfRounds} rounds',
          ),
        if (event.numberOfPlayers != null)
          _CompactFact(
            icon: Icons.people_alt_outlined,
            label: '${event.numberOfPlayers} players',
          ),
        if ((event.totalPrizeFund ?? '').isNotEmpty)
          _CompactFact(
            icon: Icons.emoji_events_outlined,
            label: event.totalPrizeFund!,
          ),
        if (sourceUrl.isNotEmpty) ...[
          const SizedBox(height: 12),
          _ActionButton(
            icon: Icons.open_in_new_rounded,
            label: event.fideEventId == null
                ? 'Open website'
                : 'Open FIDE page',
            onTap: onOpenSource,
          ),
        ],
        if (onCopyAddress != null) ...[
          const SizedBox(height: 8),
          _ActionButton(
            icon: Icons.copy_rounded,
            label: 'Copy address',
            onTap: onCopyAddress,
          ),
        ],
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final visible = children.where((child) => child is! _EmptySection).toList();
    if (visible.isEmpty) return const _EmptySection();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          ...visible,
        ],
      ),
    );
  }
}

class _InfoGrid extends StatelessWidget {
  const _InfoGrid({required this.items});

  final List<_InfoItem> items;

  @override
  Widget build(BuildContext context) {
    final visible = items
        .where((item) => item.value != null && item.value!.trim().isNotEmpty)
        .toList();
    if (visible.isEmpty) return const _EmptySection();
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final item in visible)
          SizedBox(
            width: 230,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  style: const TextStyle(color: kLightGreyColor, fontSize: 11),
                ),
                const SizedBox(height: 5),
                SelectableText(
                  item.value!,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _InfoItem {
  const _InfoItem(this.label, this.value);
  final String label;
  final String? value;
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (value == null || value!.trim().isEmpty) return const _EmptySection();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(color: kLightGreyColor, fontSize: 12),
            ),
          ),
          Expanded(
            child: SelectableText(
              value!,
              style: const TextStyle(color: kWhiteColor, fontSize: 13),
            ),
          ),
          IconButton(
            onPressed: onTap,
            icon: const Icon(
              Icons.open_in_new_rounded,
              color: kPrimaryColor,
              size: 17,
            ),
            tooltip: 'Open',
          ),
        ],
      ),
    );
  }
}

class _ListSection extends StatelessWidget {
  const _ListSection({required this.title, required this.values});

  final String title;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return const _EmptySection();
    return _SectionCard(
      title: title,
      children: [
        for (final value in values)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.description_outlined,
                  size: 15,
                  color: kLightGreyColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SelectableText(
                    value,
                    style: const TextStyle(color: kWhiteColor70, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: kPrimaryColor),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(color: kWhiteColor70, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _CompactFact extends StatelessWidget {
  const _CompactFact({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: kLightGreyColor, size: 15),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kDividerColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: kPrimaryColor),
            const SizedBox(width: 7),
            Text(
              label,
              style: const TextStyle(color: kWhiteColor, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptySection extends StatelessWidget {
  const _EmptySection();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
