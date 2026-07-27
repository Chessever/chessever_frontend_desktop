import 'dart:io';

import 'package:path/path.dart' as p;

/// Replaces a local PGN through a sibling temporary file after confirming that
/// the source still matches the text the caller inspected.
Future<void> writeLocalPgnAtomically({
  required File file,
  required String expectedText,
  required String nextText,
}) async {
  final currentText = await file.exists() ? await file.readAsString() : '';
  if (currentText != expectedText) {
    throw StateError(
      'The source PGN changed while it was being saved. Refresh the database '
      'and try again.',
    );
  }

  final temp = File(
    p.join(
      file.parent.path,
      '.${p.basename(file.path)}.chessever-$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
    ),
  );
  try {
    await temp.writeAsString(nextText, flush: true);

    // Revalidate after the potentially slow temporary-file write, immediately
    // before replacing the destination.
    final beforeReplace = await file.exists() ? await file.readAsString() : '';
    if (beforeReplace != expectedText) {
      throw StateError(
        'The source PGN changed while it was being saved. Refresh the database '
        'and try again.',
      );
    }

    await temp.rename(file.path);
  } finally {
    if (await temp.exists()) {
      await temp.delete();
    }
  }
}
