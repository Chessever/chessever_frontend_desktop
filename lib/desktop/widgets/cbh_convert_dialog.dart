import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/desktop/services/cbh_conversion_service.dart';
import 'package:chessever/desktop/widgets/desktop_dialog.dart';

bool _dialogOpen = false;

Future<String?> showCbhConvertDialog(
  BuildContext context,
  String source,
) async {
  if (_dialogOpen) {
    throw const CbhConversionException(
      'Finish or cancel the current CBH conversion first.',
    );
  }
  _dialogOpen = true;
  try {
    return await showDesktopDialog<String>(
      context,
      barrierDismissible: false,
      child: CbhConvertDialog(source: source),
    );
  } finally {
    _dialogOpen = false;
  }
}

class CbhConvertDialog extends StatefulWidget {
  const CbhConvertDialog({super.key, required this.source, this.service});
  final String source;
  final CbhConversionService? service;

  @override
  State<CbhConvertDialog> createState() => _CbhConvertDialogState();
}

class _CbhConvertDialogState extends State<CbhConvertDialog> {
  late final _service = widget.service ?? CbhConversionService();
  bool _detailsExpanded = false;
  bool _busy = false;
  bool _cancelling = false;
  String _message = 'Preparing conversion…';
  String? _error;
  String? _convertedPath;

  @override
  void dispose() {
    if (_busy) unawaited(_service.cancel());
    super.dispose();
  }

  Future<void> _convert() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _service.convert(
        widget.source,
        onProgress: (message) {
          if (mounted && !_cancelling) setState(() => _message = message);
        },
      );
      if (!mounted) return;
      if (!_cancelling && _service.existingCopyPath != null) {
        setState(() => _busy = false);
        return;
      }
      if (!_cancelling &&
          result != null &&
          _service.preservationSummary != null) {
        setState(() {
          _busy = false;
          _convertedPath = result;
        });
        return;
      }
      Navigator.of(context).pop(_cancelling ? null : result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _cancel() async {
    if (!_busy) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _cancelling = true;
      _message = 'Cancelling and removing temporary files…';
    });
    await _service.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Center(
        child: Container(
          width: 540,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF18181B),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF3F3F46)),
          ),
          child: DefaultTextStyle(
            style: const TextStyle(color: Color(0xFFE4E4E7), fontSize: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _convertedPath != null
                      ? 'Conversion complete'
                      : 'Open ChessBase database?',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(p.basename(widget.source)),
                const SizedBox(height: 12),
                Text(
                  _convertedPath != null
                      ? 'Your PGN copy is ready.'
                      : 'We’ll create a PGN copy and open it. Your original files stay unchanged.',
                ),
                const SizedBox(height: 8),
                FButton(
                  style: FButtonStyle.ghost(),
                  onPress:
                      () =>
                          setState(() => _detailsExpanded = !_detailsExpanded),
                  child: Text(_detailsExpanded ? 'Hide details' : 'Details'),
                ),
                if (_detailsExpanded) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Classic CBH with companion files. Names use Windows-1252; comments use UTF-8 when valid, otherwise Windows-1252.\n\n'
                    'Some ChessBase fields are retained as raw metadata, not displayed. Media is not included. Invalid or unverified records stop conversion; no records are skipped.\n\n'
                    'Copies go to Converted Databases. Edited copies are never overwritten.',
                    style: TextStyle(fontSize: 12, color: Color(0xFFA1A1AA)),
                  ),
                  if (_convertedPath != null &&
                      _service.preservationSummary != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _service.preservationSummary!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFA1A1AA),
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 12),
                if (_busy) Text(_message),
                if (!_busy && _service.existingCopyPath != null) ...[
                  Text(
                    _service.existingCopyEdited
                        ? 'An edited PGN copy exists. Open it with your edits, or create a separate fresh conversion?'
                        : 'A previous PGN copy exists. Open it, or create a separate fresh conversion?',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _service.existingCopyPath!,
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  FButton(
                    onPress: () {
                      _service.selectedCopyPath = _service.existingCopyPath;
                      _service.existingCopyChoice = 'reuse';
                      _convert();
                    },
                    child: const Text('Open existing copy'),
                  ),
                  const SizedBox(height: 8),
                  FButton(
                    onPress: () {
                      _service.selectedCopyPath = null;
                      _service.existingCopyChoice = 'fresh';
                      _convert();
                    },
                    child: const Text('Create fresh conversion'),
                  ),
                ],

                if (_error != null)
                  Text(
                    _error!,
                    style: const TextStyle(color: Color(0xFFFCA5A5)),
                  ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FButton(
                      onPress: _cancelling ? null : _cancel,
                      child: Text(
                        _busy
                            ? 'Cancel conversion'
                            : _convertedPath != null
                            ? 'Close'
                            : 'Cancel',
                      ),
                    ),
                    if (!_busy && _service.existingCopyPath == null) ...[
                      const SizedBox(width: 12),
                      FButton(
                        onPress:
                            _convertedPath == null
                                ? _convert
                                : () =>
                                    Navigator.of(context).pop(_convertedPath),
                        child: Text(
                          _convertedPath == null
                              ? 'Convert & Open'
                              : 'Open PGN',
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
    );
  }
}
