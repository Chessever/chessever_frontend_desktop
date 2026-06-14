import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/motion_card.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/repository/supabase/calendar_event/calendar_event.dart';
import 'package:chessever/repository/supabase/calendar_event/calendar_event_repository.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_tour_repository.dart';
import 'package:chessever/screens/calendar/calendar_event_detail_screen.dart';
import 'package:chessever/screens/calendar/calendar_screen.dart';
import 'package:chessever/screens/calendar/provider/calendar_screen_provider.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart';
import 'package:chessever/theme/app_theme.dart';

/// Desktop calendar pane.
///
/// Layered navigation — year shuttle on top, month pill bar below it, then
/// a two-pane body with a month grid on the left and a per-day / per-month
/// event list on the right. Replaces the previous infinite vertical scroll
/// of every month, which made it impossible to jump quickly between e.g.
/// March and October.
class CalendarPane extends ConsumerStatefulWidget {
  const CalendarPane({super.key});

  @override
  ConsumerState<CalendarPane> createState() => _CalendarPaneState();
}

class _CalendarPaneState extends ConsumerState<CalendarPane> {
  /// `null` means "show every event in the active month". Tapping a day
  /// in the grid drills into just that day; tap again to clear.
  int? _selectedDay;
  String? _selectedEventId;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Restore the last query so navigating away and back keeps the filter.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchController.text = ref.read(calendarSearchQueryProvider);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncMonths = ref.watch(calendarScreenProvider);
    final selectedYear = ref.watch(selectedYearProvider);
    final selectedMonth = ref.watch(selectedMonthProvider);

    return Container(
      color: kBackgroundColor,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: DesktopSearchField(
              controller: _searchController,
              hintText: 'Search calendar (event, location, country)',
              onChanged: (q) {
                ref.read(calendarSearchQueryProvider.notifier).state = q;
              },
              onClear: () {
                ref.read(calendarSearchQueryProvider.notifier).state = '';
              },
            ),
          ),
          _YearBar(
            year: selectedYear,
            onPrev: () => _setYear(selectedYear - 1),
            onNext: () => _setYear(selectedYear + 1),
            onToday: () {
              final now = DateTime.now();
              ref.read(selectedYearProvider.notifier).state = now.year;
              ref.read(selectedMonthProvider.notifier).state = now.month;
              setState(() {
                _selectedDay = now.day;
                _selectedEventId = null;
              });
            },
          ),
          _MonthPills(
            selected: selectedMonth,
            onSelect: (month) {
              ref.read(selectedMonthProvider.notifier).state = month;
              setState(() {
                _selectedDay = null;
                _selectedEventId = null;
              });
            },
          ),
          const Divider(height: 1, color: kDividerColor),
          Expanded(
            child: asyncMonths.when(
              data: (months) {
                final monthSummary = _summaryFor(months, selectedMonth);
                return _Body(
                  year: selectedYear,
                  month: selectedMonth,
                  selectedDay: _selectedDay,
                  selectedEventId: _selectedEventId,
                  monthEvents: monthSummary?.events ?? const [],
                  onSelectDay: (day) => setState(() {
                    _selectedDay = day;
                    _selectedEventId = null;
                  }),
                  onSelectEvent: (event) =>
                      setState(() => _selectedEventId = event.id),
                  onOpenEvent: _openEvent,
                );
              },
              loading: () => const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                  ),
                ),
              ),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Could not load calendar: $e',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: kRedColor, fontSize: 13),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _setYear(int year) {
    ref.read(selectedYearProvider.notifier).state = year;
    setState(() {
      _selectedDay = null;
      _selectedEventId = null;
    });
  }

  Future<void> _openEvent(GroupEventCardModel event) async {
    try {
      if (event.eventSource == EventSource.communityEvent) {
        final match = await _resolveCalendarEvent(event);
        if (!mounted) return;
        if (match == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Event details not found')),
          );
          return;
        }

        final internalTournament = await _findInternalTournamentFor(match);
        if (!mounted) return;
        if (internalTournament != null) {
          setActiveTournament(ref, internalTournament);
          return;
        }

        final navigationEvents = await _calendarEventsForCurrentYear();
        if (!mounted) return;
        final initialIndex = _indexOfCalendarEvent(navigationEvents, match);
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => CalendarEventDetailScreen(
              event: match,
              navigationEvents: navigationEvents,
              initialEventIndex: initialIndex < 0 ? null : initialIndex,
            ),
          ),
        );
        return;
      }

      final broadcast = await ref
          .read(groupBroadcastRepositoryProvider)
          .getGroupBroadcastById(event.id);
      ref.read(selectedBroadcastModelProvider.notifier).state = broadcast;

      if (!mounted) return;
      setActiveTournament(
        ref,
        GroupEventCardModel.fromGroupBroadcast(broadcast, const <String>[]),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Unable to open event')));
    }
  }

  Future<CalendarEvent?> _resolveCalendarEvent(
    GroupEventCardModel event,
  ) async {
    final yearEvents = await _calendarEventsForCurrentYear();
    final byId = <String, CalendarEvent>{
      for (final calendarEvent in yearEvents)
        _sanitizeCalendarEventId(calendarEvent.name): calendarEvent,
    };
    CalendarEvent? match = byId[event.id];

    if (match == null) {
      final results = await ref
          .read(calendarEventRepositoryProvider)
          .searchCalendarEvents(event.title);
      for (final calendarEvent in results) {
        if (_sanitizeCalendarEventId(calendarEvent.name) == event.id) {
          match = calendarEvent;
          break;
        }
      }
      match ??= results.isNotEmpty ? results.first : null;
    }
    return match;
  }

  Future<List<CalendarEvent>> _calendarEventsForCurrentYear() async {
    final events = await ref
        .read(calendarEventRepositoryProvider)
        .getCalendarEventsForYear(
          year: ref.read(selectedYearProvider),
          limit: 1000,
        );
    events.sort((a, b) {
      final byDate = (a.startDate ?? DateTime(9999)).compareTo(
        b.startDate ?? DateTime(9999),
      );
      if (byDate != 0) return byDate;
      return a.name.compareTo(b.name);
    });
    return events;
  }

  Future<GroupEventCardModel?> _findInternalTournamentFor(
    CalendarEvent calendarEvent,
  ) async {
    if (!_isActiveOrFuture(calendarEvent)) return null;
    final broadcasts = await ref
        .read(groupBroadcastRepositoryProvider)
        .searchGroupBroadcastsFromSupabase(calendarEvent.name);
    if (broadcasts.isEmpty) return null;

    for (final broadcast in broadcasts) {
      if (_isLikelySameEvent(
        calendarEvent,
        broadcast.name,
        broadcast.dateStart,
        broadcast.dateEnd,
      )) {
        return GroupEventCardModel.fromGroupBroadcast(
          broadcast,
          const <String>[],
        );
      }
    }
    return null;
  }

  bool _isActiveOrFuture(CalendarEvent event) {
    final now = DateTime.now();
    final end = event.endDate ?? event.startDate;
    return end == null ||
        !DateTime(end.year, end.month, end.day, 23, 59, 59).isBefore(now);
  }

  bool _isLikelySameEvent(
    CalendarEvent calendarEvent,
    String tournamentName,
    DateTime? tournamentStart,
    DateTime? tournamentEnd,
  ) {
    if (!_dateRangesOverlap(
      calendarEvent.startDate,
      calendarEvent.endDate,
      tournamentStart,
      tournamentEnd,
    )) {
      return false;
    }

    final calendarTitle = _normalizeEventTitle(calendarEvent.name);
    final tournamentTitle = _normalizeEventTitle(tournamentName);
    if (calendarTitle.isEmpty || tournamentTitle.isEmpty) return false;
    if (calendarTitle.contains(tournamentTitle) ||
        tournamentTitle.contains(calendarTitle)) {
      return true;
    }

    final calendarTokens = _eventTitleTokens(calendarEvent.name);
    final tournamentTokens = _eventTitleTokens(tournamentName);
    if (calendarTokens.isEmpty || tournamentTokens.isEmpty) return false;
    final overlap = calendarTokens.intersection(tournamentTokens).length;
    return overlap >= 2 && overlap >= (calendarTokens.length * 0.45).ceil();
  }

  bool _dateRangesOverlap(
    DateTime? aStart,
    DateTime? aEnd,
    DateTime? bStart,
    DateTime? bEnd,
  ) {
    if (aStart == null || bStart == null) return true;
    final aFrom = DateTime(aStart.year, aStart.month, aStart.day);
    final aToRaw = aEnd ?? aStart;
    final aTo = DateTime(aToRaw.year, aToRaw.month, aToRaw.day);
    final bFrom = DateTime(bStart.year, bStart.month, bStart.day);
    final bToRaw = bEnd ?? bStart;
    final bTo = DateTime(bToRaw.year, bToRaw.month, bToRaw.day);
    return !aTo.isBefore(bFrom) && !bTo.isBefore(aFrom);
  }

  String _normalizeEventTitle(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  Set<String> _eventTitleTokens(String value) {
    const stopWords = {
      'chess',
      'championship',
      'championships',
      'tournament',
      'festival',
      'open',
      'fide',
      'the',
      'of',
      'and',
    };
    return _normalizeEventTitle(value)
        .split(' ')
        .where((token) => token.length > 2 && !stopWords.contains(token))
        .toSet();
  }

  int _indexOfCalendarEvent(List<CalendarEvent> events, CalendarEvent target) {
    return events.indexWhere(
      (event) =>
          event.name == target.name &&
          event.startDate == target.startDate &&
          event.endDate == target.endDate,
    );
  }

  String _sanitizeCalendarEventId(String name) {
    final sanitizedName = name
        .replaceAll(' ', '_')
        .replaceAll(RegExp(r'[^\w\-]'), '')
        .toLowerCase();
    return 'cal_event_$sanitizedName';
  }

  MonthEventsSummary? _summaryFor(List<MonthEventsSummary> months, int month) {
    for (final summary in months) {
      if (summary.monthNumber == month) return summary;
    }
    return null;
  }
}

class _YearBar extends StatelessWidget {
  const _YearBar({
    required this.year,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
  });

  final int year;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Row(
        children: [
          _IconBtn(icon: Icons.chevron_left_rounded, onTap: onPrev),
          const SizedBox(width: 6),
          Text(
            '$year',
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 6),
          _IconBtn(icon: Icons.chevron_right_rounded, onTap: onNext),
          const Spacer(),
          _PillBtn(label: 'Today', icon: Icons.today_rounded, onTap: onToday),
        ],
      ),
    );
  }
}

class _MonthPills extends StatelessWidget {
  const _MonthPills({required this.selected, required this.onSelect});

  final int selected;
  final ValueChanged<int> onSelect;

  static const _names = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const DesktopScrollPhysics(),
        child: Row(
          children: [
            for (var i = 0; i < 12; i++)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _MonthPill(
                  label: _names[i],
                  selected: selected == i + 1,
                  onTap: () => onSelect(i + 1),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MonthPill extends StatefulWidget {
  const _MonthPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_MonthPill> createState() => _MonthPillState();
}

class _MonthPillState extends State<_MonthPill> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          behavior: HitTestBehavior.opaque,
          child: SingleMotionBuilder(
            value: _pressed ? 0.94 : (_hovered ? 1.05 : 1.0),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
            builder: (context, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? kPrimaryColor
                    : (_hovered ? kBlack3Color : kBlack2Color),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: selected ? kPrimaryColor : kDividerColor,
                ),
              ),
              child: Text(
                widget.label,
                style: TextStyle(
                  color: selected ? kBackgroundColor : kWhiteColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IconBtn extends StatefulWidget {
  const _IconBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _hovered ? kBlack3Color : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: kDividerColor),
            ),
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 16, color: kWhiteColor70),
          ),
        ),
      ),
    );
  }
}

class _PillBtn extends StatefulWidget {
  const _PillBtn({
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_PillBtn> createState() => _PillBtnState();
}

class _PillBtnState extends State<_PillBtn> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _hovered ? kBlack3Color : kBlack2Color,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: kDividerColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 13, color: kWhiteColor70),
                const SizedBox(width: 6),
                Text(
                  widget.label,
                  style: const TextStyle(
                    color: kWhiteColor,
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

class _Body extends StatelessWidget {
  const _Body({
    required this.year,
    required this.month,
    required this.selectedDay,
    required this.selectedEventId,
    required this.monthEvents,
    required this.onSelectDay,
    required this.onSelectEvent,
    required this.onOpenEvent,
  });

  final int year;
  final int month;
  final int? selectedDay;
  final String? selectedEventId;
  final List<GroupEventCardModel> monthEvents;
  final ValueChanged<int?> onSelectDay;
  final ValueChanged<GroupEventCardModel> onSelectEvent;
  final ValueChanged<GroupEventCardModel> onOpenEvent;

  @override
  Widget build(BuildContext context) {
    final filteredEvents = selectedDay == null
        ? monthEvents
        : monthEvents.where((e) {
            final start = e.startDate;
            final end = e.endDate;
            if (start == null) return false;
            final selected = DateTime(year, month, selectedDay!);
            // Inclusive range — show event on every day it spans.
            final startDay = DateTime(start.year, start.month, start.day);
            final endDay = end == null
                ? startDay
                : DateTime(end.year, end.month, end.day);
            return !selected.isBefore(startDay) && !selected.isAfter(endDay);
          }).toList();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: _MonthGrid(
            year: year,
            month: month,
            selectedDay: selectedDay,
            events: monthEvents,
            onSelectDay: onSelectDay,
          ),
        ),
        Container(width: 1, color: kDividerColor),
        Expanded(
          flex: 4,
          child: _EventsList(
            events: filteredEvents,
            heading: selectedDay == null
                ? '${_monthNames[month - 1]} $year'
                : '${_monthNames[month - 1]} $selectedDay, $year',
            selectedEventId: selectedEventId,
            onSelectEvent: onSelectEvent,
            onOpenEvent: onOpenEvent,
          ),
        ),
      ],
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.year,
    required this.month,
    required this.selectedDay,
    required this.events,
    required this.onSelectDay,
  });

  final int year;
  final int month;
  final int? selectedDay;
  final List<GroupEventCardModel> events;
  final ValueChanged<int?> onSelectDay;

  @override
  Widget build(BuildContext context) {
    final firstOfMonth = DateTime(year, month);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    // Monday=1..Sunday=7. Render Mon..Sun columns (Europe-default).
    final leadingBlanks = firstOfMonth.weekday - 1;
    // Map day-of-month to count of events that touch that day.
    final eventsByDay = <int, int>{};
    for (final e in events) {
      final start = e.startDate;
      if (start == null) continue;
      final end = e.endDate ?? start;
      // Clamp to the active month.
      final from = start.month == month && start.year == year
          ? start.day
          : (start.isBefore(firstOfMonth) ? 1 : 0);
      final to = end.month == month && end.year == year
          ? end.day
          : (end.isAfter(firstOfMonth) ? daysInMonth : 0);
      if (from == 0 || to == 0) continue;
      for (var d = from; d <= to; d++) {
        eventsByDay[d] = (eventsByDay[d] ?? 0) + 1;
      }
    }

    final today = DateTime.now();
    final isCurrentMonth = today.year == year && today.month == month;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _WeekdayHeader(),
          const SizedBox(height: 6),
          Expanded(
            child: GridView.builder(
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                childAspectRatio: 1.05,
              ),
              itemCount: leadingBlanks + daysInMonth,
              itemBuilder: (context, i) {
                if (i < leadingBlanks) return const SizedBox.shrink();
                final day = i - leadingBlanks + 1;
                return _DayCell(
                  day: day,
                  selected: selectedDay == day,
                  isToday: isCurrentMonth && today.day == day,
                  eventCount: eventsByDay[day] ?? 0,
                  onTap: () => onSelectDay(selectedDay == day ? null : day),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader();

  static const _labels = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final l in _labels)
          Expanded(
            child: Text(
              l,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ),
      ],
    );
  }
}

class _DayCell extends StatefulWidget {
  const _DayCell({
    required this.day,
    required this.selected,
    required this.isToday,
    required this.eventCount,
    required this.onTap,
  });

  final int day;
  final bool selected;
  final bool isToday;
  final int eventCount;
  final VoidCallback onTap;

  @override
  State<_DayCell> createState() => _DayCellState();
}

class _DayCellState extends State<_DayCell> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final isToday = widget.isToday;
    final hasEvents = widget.eventCount > 0;

    final bg = selected
        ? kPrimaryColor
        : (_hovered ? kBlack3Color : kBlack2Color);
    final fg = selected
        ? kBackgroundColor
        : (isToday ? kPrimaryColor : kWhiteColor);

    return ClickCursor(
      enabled: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          behavior: HitTestBehavior.opaque,
          child: SingleMotionBuilder(
            value: _pressed ? 0.92 : (_hovered ? 1.04 : 1.0),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
            builder: (context, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: selected
                      ? kPrimaryColor
                      : (isToday ? kPrimaryColor : kDividerColor),
                  width: isToday && !selected ? 1.5 : 1,
                ),
              ),
              padding: const EdgeInsets.all(6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.day}',
                    style: TextStyle(
                      color: fg,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const Spacer(),
                  if (hasEvents)
                    Row(
                      children: [
                        for (
                          var i = 0;
                          i < widget.eventCount.clamp(1, 3);
                          i++
                        ) ...[
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: selected
                                  ? kBackgroundColor
                                  : kPrimaryColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          if (i < widget.eventCount.clamp(1, 3) - 1)
                            const SizedBox(width: 3),
                        ],
                        if (widget.eventCount > 3) ...[
                          const SizedBox(width: 3),
                          Text(
                            '+${widget.eventCount - 3}',
                            style: TextStyle(
                              color: selected
                                  ? kBackgroundColor
                                  : kLightGreyColor,
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
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

class _EventsList extends StatelessWidget {
  const _EventsList({
    required this.events,
    required this.heading,
    required this.selectedEventId,
    required this.onSelectEvent,
    required this.onOpenEvent,
  });
  final List<GroupEventCardModel> events;
  final String heading;
  final String? selectedEventId;
  final ValueChanged<GroupEventCardModel> onSelectEvent;
  final ValueChanged<GroupEventCardModel> onOpenEvent;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Row(
            children: [
              Text(
                heading,
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
                  events.length.toString(),
                  style: const TextStyle(
                    color: kLightGreyColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: events.isEmpty
              ? const _EmptyEvents()
              : ListView.separated(
                  physics: const DesktopScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  itemCount: events.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (context, i) {
                    final event = events[i];
                    return _EventCard(
                      event: event,
                      selected: selectedEventId == event.id,
                      onSelect: () => onSelectEvent(event),
                      onOpen: () => onOpenEvent(event),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _EventCard extends StatefulWidget {
  const _EventCard({
    required this.event,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
  });

  final GroupEventCardModel event;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onOpen;

  @override
  State<_EventCard> createState() => _EventCardState();
}

class _EventCardState extends State<_EventCard> {
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
    final e = widget.event;
    final active = widget.selected || _focused;
    final borderColor = active
        ? kPrimaryColor.withValues(alpha: 0.75)
        : (_hovered ? kPrimaryColor.withValues(alpha: 0.3) : kDividerColor);
    final background = active
        ? kPrimaryColor.withValues(alpha: 0.09)
        : (_hovered ? kBlack3Color : kBlack2Color);

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
          onFocusChange: (focused) => setState(() => _focused = focused),
          child: ClickCursor(
            child: MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: GestureDetector(
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
                child: MotionCard(
                  borderRadius: 6,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 80),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: background,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: borderColor),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                e.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: kWhiteColor,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (active) ...[
                              const SizedBox(width: 8),
                              const Icon(
                                Icons.keyboard_return_rounded,
                                size: 13,
                                color: kPrimaryColor,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(
                              Icons.event_outlined,
                              size: 11,
                              color: kLightGreyColor,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                e.dates,
                                style: const TextStyle(
                                  color: kLightGreyColor,
                                  fontSize: 11,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                            if (e.timeControl.isNotEmpty)
                              Text(
                                e.timeControl,
                                style: const TextStyle(
                                  color: kWhiteColor70,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                        if ((e.location ?? '').isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              const Icon(
                                Icons.place_outlined,
                                size: 11,
                                color: kLightGreyColor,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  e.location!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: kLightGreyColor,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
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

class _EmptyEvents extends StatelessWidget {
  const _EmptyEvents();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.event_busy_outlined, size: 24, color: kLightGreyColor),
            SizedBox(height: 8),
            Text(
              'Nothing scheduled',
              style: TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const List<String> _monthNames = [
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
