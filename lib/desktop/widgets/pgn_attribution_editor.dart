import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:chessever/desktop/widgets/library/library_save_section.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

/// Draft-only optional PGN headers. The parent owns this controller so hiding
/// either disclosure never discards edits or clears imported attribution.
class PgnAttributionController {
  PgnAttributionController(Map<String, dynamic> metadata) {
    for (final tag in labels.keys) {
      final raw = metadata[tag]?.toString() ?? '';
      final text = {'?', '??', '????'}.contains(raw.trim()) ? '' : raw;
      final field = TextEditingController(text: text);
      _fields[tag] = field;
      var previous = text;
      field.addListener(() {
        // Moving the caret/focusing a field is not a metadata edit.
        if (field.text == previous) return;
        previous = field.text;
        _edited.add(tag);
      });
    }
  }

  static const labels = <String, String>{
    'Annotator': 'Annotator (author)',
    'WhiteTeam': 'White team',
    'BlackTeam': 'Black team',
    'Source': 'Source',
  };
  final _fields = <String, TextEditingController>{};
  final _edited = <String>{};

  TextEditingController field(String tag) => _fields[tag]!;

  Map<String, dynamic> applyTo(Map<String, dynamic> metadata) {
    final result = Map<String, dynamic>.of(metadata);
    for (final tag in _edited) {
      final value = field(tag).text.trim();
      if (value.isEmpty) {
        result.remove(tag);
      } else {
        result[tag] = value;
      }
    }
    return result;
  }

  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
  }
}

/// No disk write or picker is performed until this draft is confirmed.
Future<ChessGame?> showPgnAttributionDialog(
  BuildContext context,
  ChessGame game,
) => showFDialog<ChessGame>(
  context: context,
  useRootNavigator: true,
  useSafeArea: true,
  barrierDismissible: true,
  builder:
      (_, _, animation) =>
          _PgnAttributionDialog(game: game, animation: animation),
);

class _PgnAttributionDialog extends StatefulWidget {
  const _PgnAttributionDialog({required this.game, required this.animation});
  final ChessGame game;
  final Animation<double> animation;
  @override
  State<_PgnAttributionDialog> createState() => _PgnAttributionDialogState();
}

class _PgnAttributionDialogState extends State<_PgnAttributionDialog> {
  late final PgnAttributionController _controller;
  @override
  void initState() {
    super.initState();
    _controller = PgnAttributionController(widget.game.metadata);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FDialog.raw(
    animation: widget.animation,
    semanticsLabel: 'Save PGN to file',
    constraints: const BoxConstraints(maxWidth: 460),
    style:
        (style) => style.copyWith(
          decoration: style.decoration.copyWith(color: kBlack2Color),
        ),
    builder:
        (_, _) => SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Save PGN to file',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                PgnAttributionEditor(controller: _controller),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    DesktopDialogButton(
                      label: 'Cancel',
                      onPress: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    DesktopDialogButton(
                      label: 'Choose file…',
                      tone: DesktopDialogButtonTone.primary,
                      onPress:
                          () => Navigator.of(context).pop(
                            widget.game.copyWith(
                              metadata: _controller.applyTo(
                                widget.game.metadata,
                              ),
                            ),
                          ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
  );
}

class PgnAttributionEditor extends StatefulWidget {
  const PgnAttributionEditor({
    super.key,
    required this.controller,
    this.enabled = true,
  });
  final PgnAttributionController controller;
  final bool enabled;

  @override
  State<PgnAttributionEditor> createState() => _PgnAttributionEditorState();
}

class _PgnAttributionEditorState extends State<PgnAttributionEditor> {
  bool _expanded = false;

  Widget _field(String tag) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        PgnAttributionController.labels[tag]!,
        style: const TextStyle(
          color: kLightGreyColor,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 6),
      FTextField(
        key: ValueKey('pgn-$tag'),
        controller: widget.controller.field(tag),
        enabled: widget.enabled,
        inputFormatters: [FilteringTextInputFormatter.singleLineFormatter],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      LibrarySaveSectionHeader(
        label: 'Annotator and teams',
        icon: Icons.edit_note_rounded,
        expanded: _expanded,
        onToggle:
            widget.enabled
                ? () => setState(() => _expanded = !_expanded)
                : null,
      ),
      if (_expanded)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field('Annotator'),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _field('WhiteTeam')),
                  const SizedBox(width: 10),
                  Expanded(child: _field('BlackTeam')),
                ],
              ),
              const SizedBox(height: 12),
              _field('Source'),
            ],
          ),
        ),
    ],
  );
}
