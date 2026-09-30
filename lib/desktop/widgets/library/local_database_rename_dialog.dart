import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:path/path.dart' as p;

/// Renames the physical PGN through the owning Library coordinator, never by
/// calling File.rename from the dialog. Cancel/escape has no side effects.
class LocalDatabaseRenameDialog extends StatefulWidget {
  const LocalDatabaseRenameDialog({
    super.key,
    required this.path,
    required this.onRename,
  });
  final String path;
  final Future<String> Function(String name) onRename;
  @override
  State<LocalDatabaseRenameDialog> createState() =>
      _LocalDatabaseRenameDialogState();
}

class _LocalDatabaseRenameDialogState extends State<LocalDatabaseRenameDialog> {
  late final _name = TextEditingController(
    text: p.basenameWithoutExtension(widget.path),
  );
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final path = await widget.onRename(_name.text);
      if (mounted) Navigator.of(context).pop(path);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = switch (error) {
          FormatException() => error.message,
          FileSystemException() => error.message,
          StateError() => error.message,
          _ => 'Could not rename the database. Your PGN has been kept.',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Center(
      child: Container(
        width: 440,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFF18181B),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF3F3F46)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Rename database',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const Text(
              'Changes the PGN filename. Original ChessBase files stay unchanged.',
            ),
            const SizedBox(height: 16),
            FTextField(
              controller: _name,
              autofocus: true,
              enabled: !_busy,
              label: const Text('Database name'),
              onSubmit: (_) => _submit(),
            ),
            const SizedBox(height: 6),
            const Text(
              'The .pgn extension is kept.',
              style: TextStyle(fontSize: 12),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Color(0xFFF87171))),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FButton(
                  style: FButtonStyle.outline(),
                  onPress: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FButton(
                  onPress: _busy ? null : _submit,
                  child: Text(_busy ? 'Renaming…' : 'Rename'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
