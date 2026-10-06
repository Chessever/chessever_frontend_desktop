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

  PlayerDownloadPreferences get _preferences => PlayerDownloadPreferences(
    timeControls: _allControls ? const {} : Set.unmodifiable(_selected),
    fromDate: _from.value,
    toDate: _to.value,
  );

  @override
  void initState() {
    super.initState();
    final initial = widget.account.downloadPreferences;
    _allControls = initial.timeControls.isEmpty;
    _selected = _allControls ? _controls.toSet() : initial.timeControls.toSet();
    _from = FDateFieldController(vsync: this, initialDate: initial.fromDate);
    _to = FDateFieldController(vsync: this, initialDate: initial.toDate);
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
    _to.value = null;
    setState(() {
      _allControls = true;
      _selected = _controls.toSet();
    });
  }

  @override
  Widget build(BuildContext context) {
    final emptySelection = !_allControls && _selected.isEmpty;
    final error =
        emptySelection
            ? 'Choose at least one time control.'
            : _preferences.validationError;
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
                            _selected = value ? _controls.toSet() : {};
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
                                  _allControls || _selected.contains(control),
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
                          _dateField(controller: _from, label: 'Starting date'),
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
                      'Dates are optional and include the whole selected day (UTC).',
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

  Widget _dateField({
    required FDateFieldController controller,
    required String label,
  }) => FDateField(
    controller: controller,
    label: Text(label),
    clearable: true,
    onChange: (_) => setState(() {}),
  );
}
