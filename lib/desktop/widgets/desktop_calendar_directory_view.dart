import 'package:chessever/desktop/state/desktop_calendar_directory.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DesktopCalendarModeBar extends StatelessWidget {
  const DesktopCalendarModeBar({
    super.key,
    required this.selected,
    required this.eventCount,
    required this.onSelect,
  });

  final DesktopCalendarMode selected;
  final int eventCount;
  final ValueChanged<DesktopCalendarMode> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: DesktopSegmentedTabs<DesktopCalendarMode>(
              wrap: true,
              selected: selected,
              onChanged: onSelect,
              tabs: const [
                DesktopSegmentedTab(
                  value: DesktopCalendarMode.live,
                  label: 'Follow Live',
                  icon: Icons.sensors_rounded,
                ),
                DesktopSegmentedTab(
                  value: DesktopCalendarMode.major,
                  label: 'Major Events',
                  icon: Icons.workspace_premium_outlined,
                ),
                DesktopSegmentedTab(
                  value: DesktopCalendarMode.fide,
                  label: 'Full FIDE Calendar',
                  icon: Icons.calendar_month_outlined,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '$eventCount ${eventCount == 1 ? 'event' : 'events'}',
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class DesktopCalendarDirectoryBody extends StatelessWidget {
  const DesktopCalendarDirectoryBody({
    super.key,
    required this.mode,
    required this.year,
    required this.month,
    required this.listings,
    required this.selectedDay,
    required this.selectedEventId,
    required this.now,
    required this.onSelectDay,
    required this.onSelectEvent,
    required this.onOpenEvent,
    this.onPreviousMonth,
    this.onNextMonth,
    this.onToday,
  });

  final DesktopCalendarMode mode;
  final int year;
  final int month;
  final List<DesktopCalendarListing> listings;
  final int? selectedDay;
  final String? selectedEventId;
  final DateTime now;
  final ValueChanged<int?> onSelectDay;
  final ValueChanged<DesktopCalendarListing> onSelectEvent;
  final ValueChanged<DesktopCalendarListing> onOpenEvent;
  final VoidCallback? onPreviousMonth;
  final VoidCallback? onNextMonth;
  final VoidCallback? onToday;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final calendarWidth = (constraints.maxWidth * 0.28).clamp(280.0, 310.0);
        final list =
            mode == DesktopCalendarMode.live
                ? _LiveCalendarList(
                  key: const Key('desktop-calendar-live-list'),
                  listings: listings,
                  selectedEventId: selectedEventId,
                  onSelectEvent: onSelectEvent,
                  onOpenEvent: onOpenEvent,
                )
                : _AgendaList(
                  year: year,
                  month: month,
                  selectedDay: selectedDay,
                  listings: listings,
                  selectedEventId: selectedEventId,
                  now: now,
                  onSelectEvent: onSelectEvent,
                  onOpenEvent: onOpenEvent,
                );
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: kBackgroundColor,
                    border: Border.all(color: kDividerColor),
                  ),
                  child: SizedBox.expand(
                    key: const Key('desktop-calendar-directory-list-pane'),
                    child: list,
                  ),
                ),
              ),
              const SizedBox(width: 20),
              SizedBox(
                key: const Key('desktop-calendar-compact-month'),
                width: calendarWidth,
                child: _CompactMonthCalendar(
                  year: year,
                  month: month,
                  selectedDay:
                      mode == DesktopCalendarMode.live ? null : selectedDay,
                  listings: listings,
                  onSelectDay:
                      mode == DesktopCalendarMode.live ? null : onSelectDay,
                  onPreviousMonth: onPreviousMonth,
                  onNextMonth: onNextMonth,
                  onToday: onToday,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CompactMonthCalendar extends StatelessWidget {
  const _CompactMonthCalendar({
    required this.year,
    required this.month,
    required this.selectedDay,
    required this.listings,
    required this.onSelectDay,
    required this.onPreviousMonth,
    required this.onNextMonth,
    required this.onToday,
  });

  final int year;
  final int month;
  final int? selectedDay;
  final List<DesktopCalendarListing> listings;
  final ValueChanged<int?>? onSelectDay;
  final VoidCallback? onPreviousMonth;
  final VoidCallback? onNextMonth;
  final VoidCallback? onToday;

  @override
  Widget build(BuildContext context) {
    final firstOfMonth = DateTime(year, month);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final leadingBlanks = firstOfMonth.weekday - 1;
    final eventCounts = <int, int>{};
    for (var day = 1; day <= daysInMonth; day++) {
      final date = DateTime(year, month, day);
      final count =
          listings
              .where((event) => desktopCalendarOverlapsDay(event, date))
              .length;
      if (count > 0) eventCounts[day] = count;
    }
    final today = DateTime.now();
    final currentMonth = today.year == year && today.month == month;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: kBackgroundColor,
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _CompactCalendarNavButton(
                key: const Key('desktop-calendar-previous-month'),
                icon: Icons.chevron_left_rounded,
                onTap: onPreviousMonth,
              ),
              const Spacer(),
              Text(
                '${_monthNames[month - 1]} $year',
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              _CompactCalendarNavButton(
                key: const Key('desktop-calendar-next-month'),
                icon: Icons.chevron_right_rounded,
                onTap: onNextMonth,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              for (final label in ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
                Expanded(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          GridView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisExtent: 34,
            ),
            itemCount: leadingBlanks + daysInMonth,
            itemBuilder: (context, index) {
              if (index < leadingBlanks) return const SizedBox.shrink();
              final day = index - leadingBlanks + 1;
              return _CompactDayCell(
                day: day,
                selected: selectedDay == day,
                isToday: currentMonth && today.day == day,
                hasEvents: (eventCounts[day] ?? 0) > 0,
                onTap:
                    onSelectDay == null
                        ? null
                        : () => onSelectDay!(selectedDay == day ? null : day),
              );
            },
          ),
          const Divider(height: 17, color: kDividerColor),
          Align(
            alignment: Alignment.centerLeft,
            child: ClickCursor(
              child: GestureDetector(
                key: const Key('desktop-calendar-today'),
                behavior: HitTestBehavior.opaque,
                onTap: onToday,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    'Today',
                    style: TextStyle(
                      color: currentMonth ? kPrimaryColor : kWhiteColor70,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactCalendarNavButton extends StatefulWidget {
  const _CompactCalendarNavButton({
    super.key,
    required this.icon,
    required this.onTap,
  });

  final IconData icon;
  final VoidCallback? onTap;

  @override
  State<_CompactCalendarNavButton> createState() =>
      _CompactCalendarNavButtonState();
}

class _CompactCalendarNavButtonState extends State<_CompactCalendarNavButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: MouseRegion(
        onEnter:
            widget.onTap == null
                ? null
                : (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: _hovered ? kBlack3Color : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 17,
              color: widget.onTap == null ? kLightGreyColor : kWhiteColor70,
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactDayCell extends StatefulWidget {
  const _CompactDayCell({
    required this.day,
    required this.selected,
    required this.isToday,
    required this.hasEvents,
    required this.onTap,
  });

  final int day;
  final bool selected;
  final bool isToday;
  final bool hasEvents;
  final VoidCallback? onTap;

  @override
  State<_CompactDayCell> createState() => _CompactDayCellState();
}

class _CompactDayCellState extends State<_CompactDayCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final cell = MouseRegion(
      onEnter:
          widget.onTap == null ? null : (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          decoration: BoxDecoration(
            color: _hovered ? kBlack3Color : Colors.transparent,
            borderRadius: BorderRadius.circular(2),
            border: Border.all(
              color: selected ? kPrimaryColor : Colors.transparent,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${widget.day}',
                style: TextStyle(
                  color: widget.isToday ? kPrimaryColor : kWhiteColor,
                  fontSize: 10.5,
                  fontWeight:
                      selected || widget.isToday
                          ? FontWeight.w800
                          : FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 2),
              Container(
                width: 3.5,
                height: 3.5,
                decoration: BoxDecoration(
                  color: widget.hasEvents ? kPrimaryColor : Colors.transparent,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return widget.onTap == null ? cell : ClickCursor(child: cell);
  }
}

class _AgendaList extends StatelessWidget {
  const _AgendaList({
    required this.year,
    required this.month,
    required this.selectedDay,
    required this.listings,
    required this.selectedEventId,
    required this.now,
    required this.onSelectEvent,
    required this.onOpenEvent,
  });

  final int year;
  final int month;
  final int? selectedDay;
  final List<DesktopCalendarListing> listings;
  final String? selectedEventId;
  final DateTime now;
  final ValueChanged<DesktopCalendarListing> onSelectEvent;
  final ValueChanged<DesktopCalendarListing> onOpenEvent;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    void addDayGroup(DateTime date, Iterable<DesktopCalendarListing> events) {
      children.add(_DateGroupHeading(date));
      children.addAll(_eventRows(events, date));
    }

    if (selectedDay != null) {
      final date = DateTime(year, month, selectedDay!);
      final dayEvents = listings
          .where((event) => desktopCalendarOverlapsDay(event, date))
          .toList(growable: false);
      children.add(
        _AgendaHeading(
          title: '${_monthNames[month - 1]} $selectedDay, $year',
          count: dayEvents.length,
        ),
      );
      addDayGroup(date, dayEvents);
    } else {
      final agenda = buildDesktopCalendarAgenda(
        listings,
        year: year,
        month: month,
        now: now,
      );
      children.add(
        _AgendaHeading(
          title: '${_monthNames[month - 1]} $year',
          count: listings.length,
        ),
      );
      for (final group in agenda.upcoming) {
        addDayGroup(group.date, group.listings);
      }
      if (agenda.earlier.isNotEmpty) {
        children.add(_SectionTitle('Earlier in ${_monthNames[month - 1]}'));
        for (final group in agenda.earlier) {
          addDayGroup(group.date, group.listings);
        }
      }
      if (agenda.startedBeforeMonth.isNotEmpty) {
        children.add(_SectionTitle('Started before ${_monthNames[month - 1]}'));
        DateTime? previousDate;
        for (final listing in agenda.startedBeforeMonth) {
          final date = listing.startDate ?? listing.endDate ?? now;
          if (previousDate == null || !_sameCalendarDay(previousDate, date)) {
            children.add(_DateGroupHeading(date));
            previousDate = date;
          }
          children.add(_row(listing, date));
        }
      }
    }

    if (listings.isEmpty) {
      return const _EmptyCalendar(message: 'Nothing scheduled');
    }
    return ListView(
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
      children: children,
    );
  }

  Iterable<Widget> _eventRows(
    Iterable<DesktopCalendarListing> events,
    DateTime date,
  ) sync* {
    for (final listing in events) {
      yield _row(listing, date);
    }
  }

  Widget _row(DesktopCalendarListing listing, DateTime date) {
    return Padding(
      key: ValueKey(listing.id),
      padding: const EdgeInsets.only(bottom: 6),
      child: DesktopCalendarEventRow(
        listing: listing,
        date: date,
        selected: selectedEventId == listing.id,
        onSelect: () => onSelectEvent(listing),
        onOpen: () => onOpenEvent(listing),
      ),
    );
  }
}

class _LiveCalendarList extends StatelessWidget {
  const _LiveCalendarList({
    super.key,
    required this.listings,
    required this.selectedEventId,
    required this.onSelectEvent,
    required this.onOpenEvent,
  });

  final List<DesktopCalendarListing> listings;
  final String? selectedEventId;
  final ValueChanged<DesktopCalendarListing> onSelectEvent;
  final ValueChanged<DesktopCalendarListing> onOpenEvent;

  @override
  Widget build(BuildContext context) {
    if (listings.isEmpty) {
      return const _EmptyCalendar(message: 'No current broadcasts');
    }
    final liveCount = listings.where((listing) => listing.isLiveNow).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 10),
          child: Row(
            children: [
              const Expanded(
                child: Row(
                  children: [
                    Icon(Icons.sensors_rounded, size: 16, color: kPrimaryColor),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Follow Live',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: kWhiteColor,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (liveCount > 0) ...[
                    Text(
                      '$liveCount live now',
                      style: const TextStyle(
                        color: kPrimaryColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const Text(
                      ' · ',
                      style: TextStyle(color: kLightGreyColor, fontSize: 11),
                    ),
                  ],
                  Text(
                    '${listings.length} current',
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.custom(
            physics: const DesktopScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
            childrenDelegate: SliverChildBuilderDelegate(
              (context, index) {
                final listing = listings[index];
                return Padding(
                  key: ValueKey(listing.id),
                  padding: EdgeInsets.only(
                    bottom: index == listings.length - 1 ? 0 : 6,
                  ),
                  child: DesktopLiveBroadcastRow(
                    listing: listing,
                    selected: selectedEventId == listing.id,
                    onSelect: () => onSelectEvent(listing),
                    onOpen: () => onOpenEvent(listing),
                  ),
                );
              },
              childCount: listings.length,
              findChildIndexCallback: (key) {
                if (key is! ValueKey<String>) return null;
                final index = listings.indexWhere(
                  (listing) => listing.id == key.value,
                );
                return index < 0 ? null : index;
              },
            ),
          ),
        ),
      ],
    );
  }
}

class DesktopLiveBroadcastRow extends StatefulWidget {
  const DesktopLiveBroadcastRow({
    super.key,
    required this.listing,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
  });

  final DesktopCalendarListing listing;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onOpen;

  @override
  State<DesktopLiveBroadcastRow> createState() =>
      _DesktopLiveBroadcastRowState();
}

class _DesktopLiveBroadcastRowState extends State<DesktopLiveBroadcastRow> {
  final FocusNode _focusNode = FocusNode();
  bool _hovered = false;
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final listing = widget.listing;
    final active = widget.selected || _focused;
    final metadata = <String>[
      if (listing.timeControls.isNotEmpty) listing.timeControls.join(' · '),
      if (listing.endDate != null)
        'Ends ${_monthShort[listing.endDate!.month - 1]} ${listing.endDate!.day}',
      if (listing.sectionCount > 1) '${listing.sectionCount} sections',
      if (listing.maxAvgElo > 0) '${listing.maxAvgElo} top avg',
    ];
    void open() {
      _focusNode.requestFocus();
      widget.onSelect();
      widget.onOpen();
    }

    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
      },
      child: Actions(
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              open();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _focusNode,
          onFocusChange: (focused) {
            if (mounted) setState(() => _focused = focused);
          },
          child: Semantics(
            button: true,
            selected: widget.selected,
            label: listing.title,
            child: ClickCursor(
              child: MouseRegion(
                onEnter: (_) => setState(() => _hovered = true),
                onExit: (_) => setState(() => _hovered = false),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 90),
                  constraints: const BoxConstraints(minHeight: 68),
                  decoration: BoxDecoration(
                    color:
                        active
                            ? kPrimaryColor.withValues(alpha: 0.09)
                            : _hovered
                            ? kBlack3Color
                            : kPrimaryColor.withValues(alpha: 0.035),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color:
                          active
                              ? kPrimaryColor.withValues(alpha: 0.8)
                              : _hovered
                              ? kPrimaryColor.withValues(alpha: 0.3)
                              : kPrimaryColor.withValues(alpha: 0.14),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          key: ValueKey('calendar-event-${listing.id}'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            _focusNode.requestFocus();
                            widget.onSelect();
                          },
                          onDoubleTap: open,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        listing.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: kWhiteColor,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    if (listing.isLiveNow) ...[
                                      const SizedBox(width: 8),
                                      const Text(
                                        'LIVE',
                                        style: TextStyle(
                                          color: kPrimaryColor,
                                          fontSize: 9,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 0.6,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                if (metadata.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    metadata.join('  ·  '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: kLightGreyColor,
                                      fontSize: 10,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: _OpenBroadcastButton(onPressed: open),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OpenBroadcastButton extends StatefulWidget {
  const _OpenBroadcastButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_OpenBroadcastButton> createState() => _OpenBroadcastButtonState();
}

class _OpenBroadcastButtonState extends State<_OpenBroadcastButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: _hovered ? 0.16 : 0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kPrimaryColor.withValues(alpha: 0.35)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.open_in_new_rounded, size: 14, color: kPrimaryColor),
                SizedBox(width: 6),
                Text(
                  'Open broadcast',
                  style: TextStyle(
                    color: kPrimaryColor,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
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

class _AgendaHeading extends StatelessWidget {
  const _AgendaHeading({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: kBlack3Color,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 10,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 12, 2, 8),
      child: Text(
        label,
        style: const TextStyle(
          color: kLightGreyColor,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.7,
        ),
      ),
    );
  }
}

class _DateGroupHeading extends StatelessWidget {
  const _DateGroupHeading(this.date);

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 10, 2, 7),
      child: Text(
        '${_weekdayNames[date.weekday - 1]}, '
        '${_monthNames[date.month - 1]} ${date.day}, ${date.year}',
        style: const TextStyle(
          color: kWhiteColor70,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class DesktopCalendarEventRow extends StatefulWidget {
  const DesktopCalendarEventRow({
    super.key,
    required this.listing,
    required this.date,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
  });

  final DesktopCalendarListing listing;
  final DateTime date;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onOpen;

  @override
  State<DesktopCalendarEventRow> createState() =>
      _DesktopCalendarEventRowState();
}

class _DesktopCalendarEventRowState extends State<DesktopCalendarEventRow> {
  final FocusNode _focusNode = FocusNode();
  bool _hovered = false;
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final listing = widget.listing;
    final active = widget.selected || _focused;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
      },
      child: Actions(
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onSelect();
              widget.onOpen();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _focusNode,
          onFocusChange: (focused) {
            if (mounted) setState(() => _focused = focused);
          },
          child: Semantics(
            button: true,
            selected: widget.selected,
            label: listing.title,
            child: ClickCursor(
              child: MouseRegion(
                onEnter: (_) => setState(() => _hovered = true),
                onExit: (_) => setState(() => _hovered = false),
                child: GestureDetector(
                  key: ValueKey('calendar-event-${listing.id}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _focusNode.requestFocus();
                    widget.onSelect();
                  },
                  onDoubleTap: () {
                    _focusNode.requestFocus();
                    widget.onSelect();
                    widget.onOpen();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 90),
                    constraints: const BoxConstraints(minHeight: 68),
                    decoration: BoxDecoration(
                      color:
                          active
                              ? kPrimaryColor.withValues(alpha: 0.09)
                              : _hovered
                              ? kBlack3Color
                              : kBlack2Color,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color:
                            active
                                ? kPrimaryColor.withValues(alpha: 0.8)
                                : _hovered
                                ? kPrimaryColor.withValues(alpha: 0.3)
                                : kDividerColor,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 52,
                          height: 66,
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          decoration: BoxDecoration(
                            color:
                                active
                                    ? kPrimaryColor.withValues(alpha: 0.08)
                                    : kBackgroundColor.withValues(alpha: 0.35),
                            borderRadius: const BorderRadius.horizontal(
                              left: Radius.circular(5),
                            ),
                            border: const Border(
                              right: BorderSide(color: kDividerColor),
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _monthShort[widget.date.month - 1],
                                style: const TextStyle(
                                  color: kLightGreyColor,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                '${widget.date.day}',
                                style: const TextStyle(
                                  color: kWhiteColor,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        listing.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: kWhiteColor,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    if (listing.isLiveNow) ...[
                                      const SizedBox(width: 8),
                                      const Text(
                                        'LIVE',
                                        style: TextStyle(
                                          color: kPrimaryColor,
                                          fontSize: 9,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 0.6,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 5),
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    final compact = constraints.maxWidth < 300;
                                    final hasLocation =
                                        (listing.location ?? '').isNotEmpty;
                                    return Row(
                                      children: [
                                        if ((listing.countryCode ?? '')
                                            .isNotEmpty) ...[
                                          FederationFlag(
                                            federation: listing.countryCode,
                                            width: 17,
                                            height: 11,
                                            borderRadius: BorderRadius.circular(
                                              2,
                                            ),
                                          ),
                                          const SizedBox(width: 5),
                                        ],
                                        if (hasLocation)
                                          Expanded(
                                            child: Text(
                                              listing.location!,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: kLightGreyColor,
                                                fontSize: 10.5,
                                              ),
                                            ),
                                          ),
                                        if (listing
                                            .timeControls
                                            .isNotEmpty) ...[
                                          if (hasLocation)
                                            const SizedBox(width: 8),
                                          Flexible(
                                            child: Text(
                                              listing.timeControls.join(' · '),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: kWhiteColor70,
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ],
                                        if (!compact &&
                                            listing.endDate != null) ...[
                                          const SizedBox(width: 10),
                                          Text(
                                            'Ends ${_monthShort[listing.endDate!.month - 1]} ${listing.endDate!.day}',
                                            style: const TextStyle(
                                              color: kLightGreyColor,
                                              fontSize: 9.5,
                                              fontFeatures: [
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyCalendar extends StatelessWidget {
  const _EmptyCalendar({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.event_busy_outlined,
            size: 26,
            color: kLightGreyColor,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

bool _sameCalendarDay(DateTime first, DateTime second) =>
    first.year == second.year &&
    first.month == second.month &&
    first.day == second.day;

const _weekdayNames = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const _monthNames = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const _monthShort = <String>[
  'JAN',
  'FEB',
  'MAR',
  'APR',
  'MAY',
  'JUN',
  'JUL',
  'AUG',
  'SEP',
  'OCT',
  'NOV',
  'DEC',
];
