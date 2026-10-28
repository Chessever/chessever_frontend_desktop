import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/models/player_download_preferences.dart';
import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/services/desktop_global_search_intent.dart';
import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/theme/app_theme.dart';

Future<PlayerDownloadPreferences?> showPlayerDownloadOptionsDialog(
  BuildContext context, {
  required PlayerWorkspaceAccount account,
}) {
  // Root-navigator dialogs sit outside the shell's Actions ancestor. Capture
  // its action before opening the route, including while a date field has focus.
  final search = Actions.maybeFind<DesktopGlobalSearchIntent>(context);
  return showDesktopDialog<PlayerDownloadPreferences>(
    context,
    builder:
        (dialogContext) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape):
                () => Navigator.of(dialogContext).pop(),
            if (search != null) ...{
              for (final shift in [false, true]) ...{
                SingleActivator(
                      LogicalKeyboardKey.keyF,
                      meta: true,
                      shift: shift,
                    ):
                    () => Actions.invoke(
                      context,
                      const DesktopGlobalSearchIntent(),
                    ),
                SingleActivator(
                      LogicalKeyboardKey.keyF,
                      control: true,
                      shift: shift,
                    ):
                    () => Actions.invoke(
                      context,
                      const DesktopGlobalSearchIntent(),
                    ),
              },
            },
          },
          child: PlayerDownloadOptionsDialog(account: account),
        ),
  );
}

class PlayerDownloadOptionsDialog extends StatefulWidget {
  const PlayerDownloadOptionsDialog({super.key, required this.account});

  final PlayerWorkspaceAccount account;

  @override
  State<PlayerDownloadOptionsDialog> createState() =>
      _PlayerDownloadOptionsDialogState();
}

class _PlayerDownloadOptionsDialogState
    extends State<PlayerDownloadOptionsDialog>
    with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  late final FDateFieldController _from;
  late final FDateFieldController _to;
  late bool _allControls;
  late Set<PlayerDownloadTimeControl> _selected;

  List<PlayerDownloadTimeControl> get _controls =>
      widget.account.source == PlayerWorkspaceSource.chesscom
          ? const [
            PlayerDownloadTimeControl.bullet,
            PlayerDownloadTimeControl.blitz,
            PlayerDownloadTimeControl.rapid,
            PlayerDownloadTimeControl.correspondence,
          ]
          : PlayerDownloadTimeControl.values;

  // The end field shows today for an open-ended range. Saving today as a real
  // end date would cap every future sync at that day and make an unfiltered
  // profile look changed, so today is stored as no end date.
  PlayerDownloadPreferences get _preferences => PlayerDownloadPreferences(
    timeControls: _allControls ? const {} : Set.unmodifiable(_selected),
    fromDate: _from.value,
    toDate: _isToday(_to.value) ? null : _to.value,
  );

  bool _isToday(DateTime? date) {
    final today = _today;
    return date != null &&
        date.year == today.year &&
        date.month == today.month &&
        date.day == today.day;
  }

  @override
  void initState() {
    super.initState();
    final initial = widget.account.downloadPreferences;
    _allControls = initial.timeControls.isEmpty;
    _selected = initial.timeControls.toSet();
    _from = FDateFieldController(
      vsync: this,
      initialDate: initial.fromDate,
      validator: (date) => _dateError(date, starting: true),
    );
    _to = FDateFieldController(
      vsync: this,
      initialDate: initial.toDate ?? _today,
      validator: (date) => _dateError(date, starting: false),
    );
  }

  DateTime get _today {
    final now = DateTime.now().toUtc();
    return DateTime.utc(now.year, now.month, now.day);
  }

  String? _dateError(DateTime? date, {required bool starting}) {
    if (date == null) return starting ? null : 'Choose an end date.';
    if (date.isBefore(DateTime.utc(1900))) {
      return 'Choose a date on or after January 1, 1900.';
    }
    if (date.isAfter(_today)) return 'Choose today or an earlier date (UTC).';
    final other = starting ? _to.value : _from.value;
    if (other != null &&
        (starting ? date.isAfter(other) : date.isBefore(other))) {
      return starting
          ? 'The starting date must be on or before the end date.'
          : 'The end date must be on or after the starting date.';
    }
    return null;
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    if ((!_allControls && _selected.isEmpty) ||
        _preferences.validationError != null) {
      return;
    }
    Navigator.of(context).pop(_preferences);
  }

  void _reset() {
    _from.value = null;
    // Forui 0.16 toggles equal date assignments off.
    if (_to.value != _today) _to.value = _today;
    setState(() {
      _allControls = true;
      _selected = {};
    });
  }

  @override
  Widget build(BuildContext context) {
    final emptySelection = !_allControls && _selected.isEmpty;
    final error =
        emptySelection
            ? 'Choose at least one time control.'
            : _dateError(_from.value, starting: true) ??
                _dateError(_to.value, starting: false);
    final replacesGames =
        widget.account.pgnPath != null &&
        _preferences != widget.account.appliedDownloadPreferences;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Material(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(10),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Download games',
                            style: TextStyle(
                              color: kWhiteColor,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        DesktopDialogIconButton(
                          icon: Icons.close_rounded,
                          tooltip: 'Close download options',
                          onPress: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${widget.account.source.label} · ${widget.account.username}',
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 22),
                    const Text(
                      'Time controls',
                      style: TextStyle(
                        color: kWhiteColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FCheckbox(
                      label: const Text('All time controls'),
                      value: _allControls,
                      onChange:
                          (value) => setState(() {
                            _allControls = value;
                          }),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 20,
                      runSpacing: 14,
                      children: [
                        for (final control in _controls)
                          SizedBox(
                            width: 190,
                            child: FCheckbox(
                              label: Text(
                                control ==
                                            PlayerDownloadTimeControl
                                                .correspondence &&
                                        widget.account.source ==
                                            PlayerWorkspaceSource.chesscom
                                    ? 'Daily'
                                    : control.label,
                              ),
                              value:
                                  !_allControls && _selected.contains(control),
                              onChange:
                                  (value) => setState(() {
                                    _allControls = false;
                                    value
                                        ? _selected.add(control)
                                        : _selected.remove(control);
                                  }),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final fields = [
                          _dateField(
                            controller: _from,
                            label: 'Starting date (optional)',
                          ),
                          _dateField(controller: _to, label: 'End date'),
                        ];
                        return constraints.maxWidth < 400
                            ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                fields[0],
                                const SizedBox(height: 14),
                                fields[1],
                              ],
                            )
                            : Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: fields[0]),
                                const SizedBox(width: 16),
                                Expanded(child: fields[1]),
                              ],
                            );
                      },
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Leave the starting date blank for all history. An end date of today keeps future syncs open. Dates include the whole selected day (UTC).',
                      style: TextStyle(
                        color: kWhiteColor70,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      replacesGames
                          ? 'Applying new options replaces this profile’s local games and updates Combined. Only matching games will remain.'
                          : 'These options are saved for this profile and used for future syncs.',
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        error,
                        style: const TextStyle(color: kRedColor, fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 22),
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        DesktopToolbarPillButton(
                          label: 'Reset options',
                          icon: Icons.filter_alt_off_rounded,
                          onPress: _reset,
                        ),
                        DesktopToolbarPillButton(
                          label:
                              replacesGames
                                  ? 'Apply and download'
                                  : widget.account.pgnPath != null
                                  ? 'Sync new games'
                                  : 'Download games',
                          icon: Icons.download_outlined,
                          tone: DesktopToolbarPillTone.primary,
                          onPress: error == null ? _submit : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // The editable Forui 0.16 date input writes directly to a toggleable calendar
  // controller, so reparsing the same date can clear the selection. Use the
  // calendar-only field to retain dates and prevent impossible typed dates.
  Widget _dateField({
    required FDateFieldController controller,
    required String label,
  }) => FDateField.calendar(
    key: ObjectKey(controller),
    controller: controller,
    label: Text(label),
    hint: controller == _from ? 'All history' : 'Choose an end date',
    end: _today,
    today: _today,
    autovalidateMode: AutovalidateMode.always,
    // Forui 0.16's calendar-only clear button clears the display text alone.
    // Clear the selected date explicitly so the submitted filter matches it.
    suffixBuilder:
        (_, _, _) =>
            controller != _from || controller.value == null
                ? const SizedBox.shrink()
                : Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: DesktopDialogIconButton(
                    icon: Icons.close_rounded,
                    tooltip: 'Clear starting date',
                    onPress: () => controller.value = null,
                  ),
                ),
    onChange: (_) => setState(() {}),
  );
}
