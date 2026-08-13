import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/repository/supabase/calendar_event/calendar_event.dart';
import 'package:chessever/screens/calendar/calendar_event_detail_screen.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DesktopCalendarEventDetailScreen extends StatefulWidget {
  const DesktopCalendarEventDetailScreen({
    super.key,
    required this.event,
    required this.eventSequence,
    required this.initialEventIndex,
  });

  final CalendarEvent event;
  final List<CalendarEvent> eventSequence;
  final int initialEventIndex;

  @override
  State<DesktopCalendarEventDetailScreen> createState() =>
      _DesktopCalendarEventDetailScreenState();
}

class _DesktopCalendarEventDetailScreenState
    extends State<DesktopCalendarEventDetailScreen> {
  late final List<CalendarEvent> _eventSequence =
      widget.eventSequence.isEmpty ? [widget.event] : widget.eventSequence;
  late int _eventIndex = widget.initialEventIndex.clamp(
    0,
    _eventSequence.length - 1,
  );

  void _showEvent(int offset) {
    final nextIndex = _eventIndex + offset;
    if (nextIndex < 0 || nextIndex >= _eventSequence.length) return;
    setState(() => _eventIndex = nextIndex);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final focusContext = FocusManager.instance.primaryFocus?.context;
    final isEditingText =
        focusContext != null &&
        (focusContext.widget is EditableText ||
            focusContext.findAncestorWidgetOfExactType<EditableText>() != null);
    if (isEditingText) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _showEvent(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _showEvent(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final previousEventName =
        _eventIndex > 0 ? _eventSequence[_eventIndex - 1].name : null;
    final nextEventName =
        _eventIndex < _eventSequence.length - 1
            ? _eventSequence[_eventIndex + 1].name
            : null;

    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CalendarEventDetailScreen(event: _eventSequence[_eventIndex]),
          Positioned(
            left: 18,
            top: 0,
            bottom: 0,
            child: Center(
              child: _EventNavigationButton(
                key: const ValueKey('calendar-event-previous-button'),
                icon: Icons.chevron_left_rounded,
                tooltip:
                    previousEventName == null
                        ? 'No previous event'
                        : 'Previous event: $previousEventName',
                onPress:
                    previousEventName == null ? null : () => _showEvent(-1),
              ),
            ),
          ),
          Positioned(
            right: 18,
            top: 0,
            bottom: 0,
            child: Center(
              child: _EventNavigationButton(
                key: const ValueKey('calendar-event-next-button'),
                icon: Icons.chevron_right_rounded,
                tooltip:
                    nextEventName == null
                        ? 'No next event'
                        : 'Next event: $nextEventName',
                onPress: nextEventName == null ? null : () => _showEvent(1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EventNavigationButton extends StatelessWidget {
  const _EventNavigationButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPress,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlackColor.withValues(alpha: 0.76),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kWhiteColor.withValues(alpha: 0.12)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: DesktopDialogIconButton(
        icon: icon,
        onPress: onPress,
        tooltip: tooltip,
      ),
    );
  }
}
