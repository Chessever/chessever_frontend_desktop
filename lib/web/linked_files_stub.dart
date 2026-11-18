import 'package:chessever/web/picked_web_file.dart';

bool get linkedFilesSupported => false;

Future<List<PickedWebFile>?> pickLinkedChessFiles({
  required List<String> allowedExtensions,
  required bool allowMultiple,
}) => throw UnsupportedError('Linked files exist only in the web build.');
