import 'package:chessever/desktop/state/desktop_calendar_directory.dart';
import 'package:chessever/desktop/state/desktop_calendar_directory_provider.dart';
import 'package:chessever/desktop/state/desktop_calendar_listing_mapper.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/screens/desktop_calendar_event_detail_screen.dart';

import 'package:chessever/desktop/widgets/desktop_calendar_directory_view.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';

import 'package:chessever/repository/supabase/calendar_event/calendar_event.dart';
import 'package:chessever/repository/supabase/calendar_event/calendar_event_repository.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/screens/calendar/calendar_screen.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Desktop-native Calendar directory.
///
/// All modes use an event-first directory with a compact month navigator.
class CalendarPane extends ConsumerStatefulWidget {
  const CalendarPane({super.key});

  @override
  ConsumerState<CalendarPane> createState() => _CalendarPaneState();
}

class _CalendarPaneState extends ConsumerState<CalendarPane> {
  final TextEditingController _searchController = TextEditingController();
  int? _selectedDay;
  String? _selectedEventId;
  int _activationGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchController.text = ref.read(desktopCalendarSearchQueryProvider);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(desktopCalendarModeProvider);
    final selectedYear = ref.watch(selectedYearProvider);
    final selectedMonth = ref.watch(selectedMonthProvider);
    final visibleListings = ref.watch(desktopCalendarVisibleListingsProvider);
    final eventCount = visibleListings.valueOrNull?.length ?? 0;

    return Container(
      color: kBackgroundColor,
      child: Column(
        children: [
          DesktopCalendarModeBar(
            selected: mode,
            eventCount: eventCount,
            onSelect: _selectMode,
          ),
          _SearchAndFilterBar(controller: _searchController),
          const Divider(height: 1, color: kDividerColor),
          Expanded(
            child: visibleListings.when(
              data:
                  (listings) => DesktopCalendarDirectoryBody(
                    mode: mode,
                    year: selectedYear,
                    month: selectedMonth,
                    listings: listings,
                    selectedDay: _selectedDay,
                    selectedEventId: _selectedEventId,
                    now: DateTime.now(),
                    onSelectDay:
                        (day) => setState(() {
                          _selectedDay = day;
                          _selectedEventId = null;
                        }),
                    onSelectEvent: _selectEvent,
                    onOpenEvent: _openEvent,
                    onPreviousMonth: () => _shiftMonth(-1),
                    onNextMonth: () => _shiftMonth(1),
                    onToday: _selectToday,
                  ),
              loading: () => const _CalendarLoading(),
              error: (_, _) => const _CalendarError(),
            ),
          ),
        ],
      ),
    );
  }

  void _selectMode(DesktopCalendarMode mode) {
    if (mode == ref.read(desktopCalendarModeProvider)) return;
    ref.read(desktopCalendarModeProvider.notifier).state = mode;
    _activationGeneration++;
    setState(() {
      _selectedDay = null;
      _selectedEventId = null;
    });
  }

  void _shiftMonth(int offset) {
    final current = DateTime.utc(
      ref.read(selectedYearProvider),
      ref.read(selectedMonthProvider) + offset,
    );
    ref.read(selectedYearProvider.notifier).state = current.year;
    ref.read(selectedMonthProvider.notifier).state = current.month;
    _activationGeneration++;
    setState(() {
      _selectedDay = null;
      _selectedEventId = null;
    });
  }

  void _selectToday() {
    final now = DateTime.now();
    ref.read(selectedYearProvider.notifier).state = now.year;
    ref.read(selectedMonthProvider.notifier).state = now.month;
    _activationGeneration++;
    setState(() {
      _selectedDay = now.day;
      _selectedEventId = null;
    });
  }

  void _selectEvent(DesktopCalendarListing listing) {
    if (_selectedEventId != listing.id) _activationGeneration++;
    setState(() => _selectedEventId = listing.id);
  }

  Future<void> _openEvent(DesktopCalendarListing listing) async {
    final activation = ++_activationGeneration;
    try {
      if (listing.source == DesktopCalendarSource.fide) {
        final directory =
            ref.read(desktopCalendarDirectoryProvider).valueOrNull;
        final orderedListings = buildDesktopCalendarNavigationSequence(
          ref.read(desktopCalendarVisibleListingsProvider).valueOrNull ??
              const <DesktopCalendarListing>[],
          mode: ref.read(desktopCalendarModeProvider),
          year: ref.read(selectedYearProvider),
          month: ref.read(selectedMonthProvider),
          selectedDay: _selectedDay,
          now: DateTime.now(),
        );
        var event = directory?.calendarEventsById[listing.id];
        event ??= await _findCalendarEventByStableIdentity(listing);
        if (!mounted ||
            activation != _activationGeneration ||
            _selectedEventId != listing.id) {
          return;
        }
        if (event == null) {
          showDesktopToast(context, 'Event details not found', error: true);
          return;
        }
        final eventSequence = <CalendarEvent>[];
        var initialEventIndex = -1;
        for (final sibling in orderedListings) {
          if (sibling.source != DesktopCalendarSource.fide) continue;
          final siblingEvent =
              sibling.id == listing.id
                  ? event
                  : directory?.calendarEventsById[sibling.id];
          if (siblingEvent == null) continue;
          if (sibling.id == listing.id) {
            initialEventIndex = eventSequence.length;
          }
          eventSequence.add(siblingEvent);
        }
        if (initialEventIndex < 0) {
          initialEventIndex = eventSequence.length;
          eventSequence.add(event);
        }
        Navigator.of(context).push(
          MaterialPageRoute(
            builder:
                (_) => DesktopCalendarEventDetailScreen(
                  event: event!,
                  eventSequence: eventSequence,
                  initialEventIndex: initialEventIndex,
                ),
          ),
        );
        return;
      }

      final broadcastId = listing.broadcastId;
      if (broadcastId == null || broadcastId.isEmpty) {
        if (mounted) {
          showDesktopToast(context, 'Event details not found', error: true);
        }
        return;
      }
      if (activation != _activationGeneration ||
          _selectedEventId != listing.id) {
        return;
      }
      final broadcast = GroupBroadcast(
        id: broadcastId,
        createdAt: DateTime.now(),
        name: listing.title,
        search: listing.searchTerms,
        maxAvgElo: listing.maxAvgElo,
        dateStart: listing.startDate,
        dateEnd: listing.endDate,
        timeControl:
            listing.timeControls.isEmpty
                ? null
                : listing.timeControls.join(' / '),
      );
      setActiveTournament(
        ref,
        GroupEventCardModel.fromGroupBroadcast(
          broadcast,
          listing.isLiveNow ? [broadcastId] : const <String>[],
        ),
      );
    } catch (_) {
      if (!mounted) return;
      showDesktopToast(context, 'Unable to open event', error: true);
    }
  }

  Future<CalendarEvent?> _findCalendarEventByStableIdentity(
    DesktopCalendarListing listing,
  ) async {
    final results = await ref
        .read(calendarEventRepositoryProvider)
        .searchCalendarEvents(listing.title);
    for (final event in results) {
      final stableId = desktopCalendarStableFideId(
        fideEventId: event.fideEventId,
        title: cleanDesktopCalendarEventTitle(event.name),
        startDate: event.startDate,
      );
      if (stableId == listing.id) return event;
    }
    return null;
  }
}

class _SearchAndFilterBar extends ConsumerWidget {
  const _SearchAndFilterBar({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedTimeControl = ref.watch(desktopCalendarTimeControlProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: DesktopSearchField(
              controller: controller,
              hintText: 'Search event, city, country, or player',
              onChanged: (query) {
                ref.read(desktopCalendarSearchQueryProvider.notifier).state =
                    query;
              },
              onClear: () {
                ref.read(desktopCalendarSearchQueryProvider.notifier).state =
                    '';
              },
            ),
          ),
          const SizedBox(width: 8),
          _TimeControlFilter(
            selected: selectedTimeControl,
            onSelect: (value) {
              ref.read(desktopCalendarTimeControlProvider.notifier).state =
                  value;
            },
          ),
        ],
      ),
    );
  }
}

class _TimeControlFilter extends StatelessWidget {
  const _TimeControlFilter({required this.selected, required this.onSelect});

  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final value = selected ?? 'All';
    return SizedBox(
      width: 150,
      child: FSelect<String>(
        key: ValueKey(value),
        initialValue: value,
        onChange: (next) {
          if (next == null) return;
          onSelect(next == 'All' ? null : next);
        },
        items: const {
          'All formats': 'All',
          'Classical': 'Classical',
          'Rapid': 'Rapid',
          'Blitz': 'Blitz',
        },
      ),
    );
  }
}

class _CalendarLoading extends StatelessWidget {
  const _CalendarLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
        ),
      ),
    );
  }
}

class _CalendarError extends StatelessWidget {
  const _CalendarError();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Could not load calendar',
          textAlign: TextAlign.center,
          style: const TextStyle(color: kRedColor, fontSize: 13),
        ),
      ),
    );
  }
}
