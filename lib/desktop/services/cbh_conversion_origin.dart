import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Record rename intent before the PGN moves. Either filename remains valid
/// after a crash; the original content digest is never advanced over edits.
Future<void> prepareCbhCopyRename(String source, String target) async {
  if (p.dirname(source) != p.dirname(target)) return;
  final receipt = File(p.join(p.dirname(source), 'conversion.json'));
  if (await FileSystemEntity.type(receipt.path, followLinks: false) !=
      FileSystemEntityType.file) {
    return;
  }
  final value = jsonDecode(await receipt.readAsString());
  if (value is! Map<String, dynamic> || value['sourceSha256'] is! Map) return;
  final names = <String>{
    if (value['pgnFile'] is String)
      value['pgnFile'] as String
    else
      'database.pgn',
    ...((value['pgnAliases'] as List?) ?? const []).whereType<String>(),
  };
  if (!names.contains(p.basename(source))) return;
  names.add(p.basename(target));
  value['pgnAliases'] = names.toList();
  final temporary = File(
    '${receipt.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  try {
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(receipt.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
