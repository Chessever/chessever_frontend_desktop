import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/desktop/services/web_file_intake.dart';
import 'package:chessever/desktop/widgets/desktop_dialog.dart';

Future<bool?> showWebCbhMissingFilesDialog(
  BuildContext context,
  List<WebCbhMissingFiles> databases,
) => showDesktopDialog<bool>(
  context,
  builder: (context) {
    final single = databases.length == 1 ? databases.single : null;
    final stem =
        single == null
            ? null
            : p.posix.basenameWithoutExtension(single.indexName);
    final title =
        stem == null
            ? 'Select all ChessBase files'
            : 'Select all files for $stem';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
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
                  title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'A .cbh file is only one part of a ChessBase database. '
                  'Select ${single?.indexName ?? 'each .cbh file'} and its six matching files together from the same folder.',
                ),
                for (final database in databases) ...[
                  const SizedBox(height: 12),
                  Text(
                    '${single == null ? '${database.indexName} — still needed' : 'Still needed'}: '
                    '${database.missingNames.join(', ')}',
                  ),
                ],
                const SizedBox(height: 20),
                OverflowBar(
                  alignment: MainAxisAlignment.end,
                  overflowAlignment: OverflowBarAlignment.end,
                  spacing: 12,
                  overflowSpacing: 8,
                  children: [
                    FButton(
                      style: FButtonStyle.ghost(),
                      mainAxisSize: MainAxisSize.min,
                      onPress: () => Navigator.of(context).pop(false),
                      child: const Flexible(child: Text('Cancel')),
                    ),
                    FButton(
                      mainAxisSize: MainAxisSize.min,
                      onPress: () => Navigator.of(context).pop(true),
                      child: const Flexible(child: Text('Select files again')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  },
);
